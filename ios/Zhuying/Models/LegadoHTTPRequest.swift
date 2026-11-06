import Foundation
import CoreFoundation

enum LegadoRequestError: LocalizedError, Equatable {
    case invalid(String), unsupported(String), limit, searchResultLimit, scriptEvaluationLimit
    var errorDescription: String? {
        switch self {
        case .invalid(let value): "阅读书源请求无效：\(value)"
        case .unsupported(let value): "当前阅读书源暂不支持：\(value)"
        case .limit: "阅读书源的请求数量、正文大小或分页超过限制。"
        case .searchResultLimit: "搜索结果超过单次书源处理额度，请缩小关键词范围。"
        case .scriptEvaluationLimit: "单次书源操作的规则求值次数超过额度。"
        }
    }
}

/// Every operation has its own deadline and cancellation signal. Synchronous
/// Java bridges wait only on a dedicated queue, never on an actor executor.
final class LegadoOperationControl: @unchecked Sendable {
    private var end: TimeInterval
    private var interactionStart: TimeInterval?
    var deadline: TimeInterval { lock.lock(); defer { lock.unlock() }; return interactionStart.map { end + ProcessInfo.processInfo.systemUptime - $0 } ?? end }
    private let lock = NSLock()
    private var failure: Error?
    private var sessionState: LegadoPersistentState?
    private var expectedRevision: UInt64?
    private var changingSession = false
    private var sessionBound = false
    var sessionRevision: UInt64? { lock.lock(); defer { lock.unlock() }; return expectedRevision }
    func bindSession(_ state: LegadoPersistentState?) {
        let revision = state?.sessionRevision
        lock.lock(); defer { lock.unlock() }; guard !sessionBound else { return }; sessionBound = true; sessionState = state; expectedRevision = revision
    }
    func mutateSession<Value>(_ body: () throws -> Value) throws -> Value {
        try check()
        lock.lock(); let state = sessionState, expected = expectedRevision; changingSession = true; lock.unlock()
        defer { lock.lock(); changingSession = false; lock.unlock() }
        guard let state else { return try body() }
        let (value, revision) = try state.withSessionMutation(expectedSessionRevision: expected, body)
        lock.lock(); expectedRevision = revision; lock.unlock()
        return value
    }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancellation: ((Error) -> Void)?
    init(timeout: TimeInterval) { end = ProcessInfo.processInfo.systemUptime + timeout }
    func check() throws {
        lock.lock(); let error = failure, state = sessionState, expected = expectedRevision, changing = changingSession; lock.unlock()
        if let error { throw error }
        if !changing, let state, state.sessionRevision != expected { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw ContentFailure.timedOut }
    }
    func beginInteraction() throws {
        try check(); lock.lock(); defer { lock.unlock() }
        guard interactionStart == nil else { throw LegadoRequestError.unsupported("嵌套网页交互") }
        interactionStart = ProcessInfo.processInfo.systemUptime
    }
    func endInteraction() {
        lock.lock(); defer { lock.unlock() }
        if let start = interactionStart { end += ProcessInfo.processInfo.systemUptime - start; interactionStart = nil }
    }
    func startWatchdog() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            do { try self.check(); self.startWatchdog() } catch { self.cancel(error) }
        }
    }
    func installCancellation(_ action: @escaping (Error) -> Void) {
        lock.lock(); let error = failure; if error == nil { cancellation = action }; lock.unlock()
        if let error { action(error) }
    }
    func cancel(_ error: Error = CancellationError()) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error; let action = cancellation; cancellation = nil
        let values = Array(tasks.values); tasks = [:]; lock.unlock()
        values.forEach { $0.cancel() }; action?(error)
    }
    func add(_ task: Task<Void, Never>, id: UUID) {
        lock.lock(); let stopped = failure != nil; if !stopped { tasks[id] = task }; lock.unlock()
        if stopped { task.cancel() }
    }
    func remove(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
}

private final class LegadoHTTPResult: @unchecked Sendable {
    let condition = NSCondition()
    var value: Result<(Data, HTTPURLResponse), Error>?
    func complete(_ result: Result<(Data, HTTPURLResponse), Error>) {
        condition.lock(); value = result; condition.broadcast(); condition.unlock()
    }
}

/// An instance belongs to one source adapter. It never reads the shared system
/// cookie store, and the request executor rejects other origins before sending.
final class LegadoCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [(origin: String, cookie: HTTPCookie)] = []
    private func scope(_ url: URL) -> String { (url.scheme ?? "") + "://" + (url.host?.lowercased() ?? "") + ":" + String(url.port ?? (url.scheme == "https" ? 443 : 80)) }
    func header(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        cookies.removeAll { $0.cookie.expiresDate.map { $0 <= Date() } ?? false }
        let host = url.host?.lowercased() ?? "", path = url.path.isEmpty ? "/" : url.path
        let applicable = cookies.filter { $0.origin == scope(url) }.map(\.cookie).filter {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let cookiePath = $0.path
            let matchesPath = path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            return (host == domain || host.hasSuffix("." + domain)) && matchesPath && (!$0.isSecure || url.scheme == "https")
        }
        return applicable.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: applicable)["Cookie"]
    }
    func store(_ headers: [String: String], url: URL) {
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        lock.lock(); defer { lock.unlock() }
        for cookie in incoming {
            guard cookie.name.utf8.count <= 512, cookie.value.utf8.count <= 8192 else { continue }
            cookies.removeAll { $0.origin == scope(url) && $0.cookie.name == cookie.name && $0.cookie.domain == cookie.domain && $0.cookie.path == cookie.path }
            if cookie.expiresDate.map({ $0 > Date() }) ?? true { cookies.append((scope(url), cookie)) }
        }
        if cookies.count > 256 { cookies.removeFirst(cookies.count - 256) }
        while cookies.reduce(0, { $0 + $1.cookie.name.utf8.count + $1.cookie.value.utf8.count + $1.cookie.domain.utf8.count + $1.cookie.path.utf8.count }) > 128 * 1024 { cookies.removeFirst() }
    }
    func set(_ value: String, url: URL) { store(["Set-Cookie": value], url: url) }
    func remove(url: URL? = nil) { lock.lock(); defer { lock.unlock() }; if let url { cookies.removeAll { $0.origin == scope(url) } } else { cookies = [] } }
}

struct LegadoHTTPPage {
    let text: String
    let url: URL
    let status: Int
    let headers: [String: String]
    var bridgeValue: [String: Any] { ["body": text, "url": url.absoluteString, "statusCode": status, "headers": headers] }
}

final class LegadoHTTPExecutor {
    let origin: URL?
    let policy: LegadoSourcePolicy
    let state: LegadoPersistentState?
    let control: LegadoOperationControl
    let cookies: LegadoCookieJar
    private let transport: any HTTPTransport
    private var requestCount = 0
    private var responseBytes = 0
    private var inheritedHeaderOrigin: URL?
    private let rememberHeaderOrigin: ((URL) -> Void)?
    init(origin: URL, transport: any HTTPTransport, control: LegadoOperationControl, cookies: LegadoCookieJar) {
        self.origin = origin; self.transport = transport; self.control = control; self.cookies = cookies
        policy = try! LegadoSourcePolicy(sourceID: "legacy", declaredOrigins: [origin]); state = nil
        inheritedHeaderOrigin = origin; rememberHeaderOrigin = nil
    }
    init(origin: URL?, policy: LegadoSourcePolicy, state: LegadoPersistentState?, inheritedHeaderOrigin: URL? = nil, rememberHeaderOrigin: ((URL) -> Void)? = nil, transport: any HTTPTransport, control: LegadoOperationControl, cookies: LegadoCookieJar) {
        self.origin = origin; self.policy = policy; self.state = state; self.transport = transport; self.control = control; self.cookies = cookies
        self.inheritedHeaderOrigin = inheritedHeaderOrigin ?? origin; self.rememberHeaderOrigin = rememberHeaderOrigin
        control.bindSession(state)
    }
    static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased() && left.host?.lowercased() == right.host?.lowercased() &&
        (left.port ?? (left.scheme == "https" ? 443 : 80)) == (right.port ?? (right.scheme == "https" ? 443 : 80))
    }
    static func split(_ template: String) throws -> (String, [String: Any]) {
        guard let range = template.range(of: #",\s*\{"#, options: .regularExpression) else { return (template, [:]) }
        let url = String(template[..<range.lowerBound])
        let json = template[template.index(after: range.lowerBound)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw LegadoRequestError.invalid("URL 后的请求配置不是对象") }
        return (url, object)
    }
    func absolute(_ address: String, baseURL: URL? = nil) throws -> URL {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 32_000,
              let url = URL(string: value, relativeTo: baseURL ?? origin)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw LegadoRequestError.invalid("需要完整或相对的 HTTP(S) 地址") }
        return url
    }
    static func headers(_ value: Any?) throws -> [String: String] {
        guard let value, !(value is NSNull) else { return [:] }
        if let text = value as? String {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
            return try headers(JSONSerialization.jsonObject(with: Data(text.utf8)))
        }
        guard let values = value as? [String: Any], values.count <= 64 else { throw LegadoRequestError.invalid("header 需要 JSON 对象") }
        var result: [String: String] = [:]
        for (key, value) in values {
            guard !key.isEmpty, !key.contains("\n"), !key.contains("\r"), let string = value as? String,
                  !string.contains("\n"), !string.contains("\r"), string.utf8.count <= 8192 else { throw LegadoRequestError.invalid("header 值无效") }
            guard !["host", "content-length", "connection", "proxy-authorization"].contains(key.lowercased()) else { throw LegadoRequestError.unsupported("手动设置 \(key) 请求头") }
            let normalized = key.lowercased()
            guard result[normalized] == nil else { throw LegadoRequestError.invalid("大小写重复的请求头：\(key)") }
            result[normalized] = string
        }
        return result
    }
    func request(_ template: String, baseURL: URL? = nil, headers: [String: String] = [:], override: [String: Any] = [:]) throws -> LegadoHTTPPage {
        try control.check()
        requestCount += 1; guard requestCount <= 64 else { throw LegadoRequestError.limit }
        let (address, parsed) = try Self.split(template)
        let options = parsed.merging(override) { _, value in value }
        let allowed: Set<String> = ["method", "body", "headers", "header", "charset", "type", "webView", "webJs", "js"]
        for key in options.keys where !allowed.contains(key) { throw LegadoRequestError.unsupported("URL 请求选项 \(key)") }
        for key in ["webView", "webJs", "js", "type"] {
            guard let option = options[key], !(option is NSNull) else { continue }
            if let flag = option as? Bool, !flag { continue }
            if let text = option as? String, text.isEmpty || (key == "type" && text == "text") { continue }
            throw LegadoRequestError.unsupported("URL 请求选项 \(key)")
        }
        let url = try absolute(address, baseURL: baseURL)
        _ = try policy.requireOrigin(for: url)
        let method = (options["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "HEAD"].contains(method) else { throw LegadoRequestError.unsupported("HTTP \(method)") }
        let charset = options["charset"] as? String
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        request.timeoutInterval = max(0.1, min(20, control.deadline - ProcessInfo.processInfo.systemUptime))
        var allHeaders = try Self.headers(headers)
        if inheritedHeaderOrigin == nil, !allHeaders.isEmpty {
            inheritedHeaderOrigin = try policy.requireOrigin(for: url); rememberHeaderOrigin?(inheritedHeaderOrigin!)
        }
        if let owner = inheritedHeaderOrigin, !Self.sameOrigin(url, owner) {
            // Only public HTTP negotiation fields inherit across hosts. A
            // source can explicitly attach credentials to this request's URL
            // options; source-wide private headers belong to their first host.
            allHeaders = allHeaders.filter { ["accept", "accept-language", "user-agent", "content-type"].contains($0.key) }
        }
        for (key, value) in try Self.headers(options["headers"] ?? options["header"]) { allHeaders[key] = value }
        if allHeaders["cookie"] == nil {
            if let state { let saved = try state.cookies(for: url); if !saved.isEmpty { allHeaders["cookie"] = HTTPCookie.requestHeaderFields(with: saved)["Cookie"] } }
            else if let value = cookies.header(for: url) { allHeaders["cookie"] = value }
        }
        for (key, value) in allHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let body = options["body"] {
            guard method == "POST" else { throw LegadoRequestError.invalid("只有 POST 可以设置 body") }
            if let string = body as? String {
                guard let data = string.data(using: try Self.encoding(charset)) else { throw LegadoRequestError.invalid("body 无法按指定字符集编码") }
                request.httpBody = data
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/x-www-form-urlencoded; charset=" + (charset ?? "utf-8"), forHTTPHeaderField: "Content-Type") }
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .fragmentsAllowed])
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
            }
            guard (request.httpBody?.count ?? 0) <= 512 * 1024 else { throw LegadoRequestError.limit }
        }
        let (data, response) = try send(request)
        try control.check()
        responseBytes += data.count
        guard data.count <= 2 * 1024 * 1024, responseBytes <= 8 * 1024 * 1024,
              let finalURL = response.url else { throw LegadoRequestError.limit }
        _ = try policy.requireOrigin(for: finalURL)
        guard Self.sameOrigin(url, finalURL) else { throw LegadoRequestError.unsupported("跨主机重定向，请使用书源明确返回的线路") }
        var responseHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields { responseHeaders[String(describing: key)] = String(describing: value) }
        cookies.store(responseHeaders, url: finalURL)
        try state?.setCookies(HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: finalURL), for: finalURL, expectedSessionRevision: control.sessionRevision)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: try control.mutateSession { try state?.expire() }; throw ContentFailure.authenticationRequired
        case 429: throw ContentFailure.rateLimited
        case 404: throw ContentFailure.missingChapter
        default: throw ContentFailure.unavailable
        }
        let text = try Self.decode(data, charset: charset ?? response.textEncodingName)
        return .init(text: text, url: finalURL, status: response.statusCode, headers: responseHeaders)
    }
    private func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        precondition(!Thread.isMainThread, "Synchronous source HTTP must run on the source worker queue")
        let waiter = LegadoHTTPResult(), identifier = UUID(), transport = self.transport, control = self.control
        let task = Task.detached(priority: .userInitiated) {
            defer { control.remove(identifier) }
            do { waiter.complete(.success(try await transport.send(request))) }
            catch { waiter.complete(.failure(error)) }
        }
        control.add(task, id: identifier)
        defer { task.cancel(); control.remove(identifier) }
        while true {
            try control.check()
            waiter.condition.lock()
            if let value = waiter.value { waiter.condition.unlock(); return try value.get() }
            _ = waiter.condition.wait(until: Date().addingTimeInterval(0.025))
            waiter.condition.unlock()
        }
    }
    static func encoding(_ charset: String?) throws -> String.Encoding {
        switch charset?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "utf-8" {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030": return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "utf-16", "utf16": return .utf16
        case "iso-8859-1", "latin1": return .isoLatin1
        default: throw LegadoRequestError.unsupported("字符集 \(charset ?? "")")
        }
    }
    static func decode(_ data: Data, charset: String?) throws -> String {
        if data.isEmpty { return "" }
        if let charset, let value = String(data: data, encoding: try encoding(charset)) { return value }
        if charset == nil {
            if let value = String(data: data, encoding: .utf8) { return value }
            if let value = String(data: data, encoding: try encoding("gb18030")) { return value }
        }
        throw LegadoRequestError.invalid("响应字符集与内容不一致")
    }
}
