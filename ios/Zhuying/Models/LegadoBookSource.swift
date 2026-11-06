import Foundation
import CryptoKit
import Fuzi

private struct LegadoMetadataBudget {
    private var bytes = 0
    mutating func add<Value: Encodable>(_ value: Value) throws {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= 2 * 1024 * 1024 - bytes else { throw LegadoRequestError.limit }
        bytes += encoded.count
    }
}

private final class LegadoCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class LegadoBlockingResult<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, Error>?
    func complete(_ result: Result<Value, Error>) { condition.lock(); self.result = result; condition.broadcast(); condition.unlock() }
    func wait(control: LegadoOperationControl) throws -> Value {
        while true {
            try control.check(); condition.lock()
            if let result { condition.unlock(); return try result.get() }
            _ = condition.wait(until: Date().addingTimeInterval(0.025)); condition.unlock()
        }
    }
}

private final class LegadoSourceSession: @unchecked Sendable {
    let cookies = LegadoCookieJar()
    let runtime: QuickJSScriptSession
    let queue = DispatchQueue(label: "com.zhuying.legado.worker", qos: .userInitiated)
    let state: LegadoPersistentState?
    private var references: [String: LegadoReference] = [:]
    private var runtimeRevision: UInt64 = 0
    var lastMessage = ""
    var inheritedHeaderOrigin: URL?
    init(state: LegadoPersistentState?, scriptBudget: QuickJSScriptMemoryBudget) { self.state = state; runtime = QuickJSScriptSession(budget: scriptBudget) }
    func prepareRuntime() {
        let revision = state?.sessionRevision ?? 0
        if revision != runtimeRevision { runtime.reset(); runtimeRevision = revision }
        lastMessage = ""
    }
    func referenceKey(_ reference: LegadoReference, role: String, sourceID: String) throws -> String {
        if reference.kind == .https, reference.options.isEmpty, reference.requestURL?.query == nil { return reference.requestURL!.absoluteString }
        return "legado-ref:" + (state == nil ? "" : "legado-ref-v2-") + (try reference.stableID(sourceIdentity: state?.scope.sourceID ?? sourceID, role: role))
    }
    func registerBatch(_ refs: [LegadoReference], role: String, sourceID: String) throws {
        let opaque = refs.filter { $0.kind != .https || !$0.options.isEmpty || $0.requestURL?.query != nil }
        guard !opaque.isEmpty else { return }
        if let state { _ = try state.registerReferences(opaque, role: role) }
        else {
            var next = references
            for ref in opaque { next[try ref.stableID(sourceIdentity: sourceID, role: role)] = ref }
            guard next.count <= 4096, next.values.reduce(0, { $0 + $1.descriptor.utf8.count }) <= 8 * 1024 * 1024 else { throw LegadoRequestError.limit }
            references = next
        }
    }
    func register(_ reference: LegadoReference, role: String, sourceID: String) throws -> String {
        let key = try referenceKey(reference, role: role, sourceID: sourceID)
        try registerBatch([reference], role: role, sourceID: sourceID)
        return key
    }
    func resolve(_ value: String, baseURL: URL?) throws -> LegadoReference {
        guard value.hasPrefix("legado-ref:") else { return try .parse(value, baseURL: baseURL) }
        let key = String(value.dropFirst(11))
        if let state { return try state.resolveReference(key) }
        guard let reference = references[key] else { throw ContentFailure.missingChapter }; return reference
    }
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var controls: [ObjectIdentifier: LegadoOperationControl] = [:]
    var pendingOperationCount: Int { lock.lock(); defer { lock.unlock() }; return controls.count }
    func track(_ control: LegadoOperationControl) { lock.lock(); controls[ObjectIdentifier(control)] = control; lock.unlock() }
    func untrack(_ control: LegadoOperationControl) { lock.lock(); controls[ObjectIdentifier(control)] = nil; lock.unlock() }
    func reset() {
        lock.lock(); let active = Array(controls.values); lock.unlock()
        active.forEach { $0.cancel() }; runtime.reset()
    }
    private var valueBytes = 0
    private var catalogs: [String: Set<String>] = [:]
    private var catalogOrder: [String] = []
    private var catalogBytes: [String: Int] = [:]
    private var searchPages: [String: [Int: String]] = [:]
    private var searchOrder: [String] = []
    private var searchPageBytes = 0
    func get(_ key: String) throws -> String { if let state { return try state.getVariable(key) }; lock.lock(); defer { lock.unlock() }; return values[key] ?? "" }
    func set(_ key: String, _ value: String) throws {
        if let state { try state.setVariable(value, key: key); return }
        guard key.utf8.count <= 512, value.utf8.count <= 128 * 1024 else { throw LegadoRequestError.limit }
        lock.lock(); defer { lock.unlock() }
        guard values.count < 512 || values[key] != nil else { throw LegadoRequestError.limit }
        let oldSize = values[key].map { key.utf8.count + $0.utf8.count } ?? 0
        let nextSize = valueBytes - oldSize + key.utf8.count + value.utf8.count
        guard nextSize <= 512 * 1024 else { throw LegadoRequestError.limit }
        values[key] = value; valueBytes = nextSize
    }
    func catalog(_ urls: Set<String>, bookID: String) throws {
        let size = bookID.utf8.count + urls.reduce(0, { $0 + $1.utf8.count })
        guard size <= 4 * 1024 * 1024 else { throw LegadoRequestError.limit }
        lock.lock(); defer { lock.unlock() }
        catalogs[bookID] = urls; catalogOrder.removeAll { $0 == bookID }; catalogOrder.append(bookID)
        catalogBytes[bookID] = size
        while catalogOrder.count > 32 || catalogBytes.values.reduce(0, +) > 4 * 1024 * 1024 {
            let oldest = catalogOrder.removeFirst(); catalogs[oldest] = nil; catalogBytes[oldest] = nil
        }
    }
    func catalog(bookID: String) -> Set<String> { lock.lock(); defer { lock.unlock() }; return catalogs[bookID] ?? [] }
    func resetSearch(_ query: String) {
        lock.lock(); defer { lock.unlock() }
        searchPageBytes -= searchPages[query]?.values.reduce(0, { $0 + $1.utf8.count }) ?? 0
        searchPages[query] = [:]; searchOrder.removeAll { $0 == query }; searchOrder.append(query)
        while searchOrder.count > 8 {
            let oldest = searchOrder.removeFirst()
            searchPageBytes -= searchPages.removeValue(forKey: oldest)?.values.reduce(0, { $0 + $1.utf8.count }) ?? 0
        }
    }
    func searchURL(_ query: String, page: Int) -> String? { lock.lock(); defer { lock.unlock() }; return searchPages[query]?[page] }
    func rememberSearchURL(_ url: String, query: String, page: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard searchPages[query] != nil else { throw ContentFailure.invalidResponse }
        let nextBytes = searchPageBytes - (searchPages[query]?[page]?.utf8.count ?? 0) + url.utf8.count
        guard nextBytes <= 512 * 1024 else { throw LegadoRequestError.limit }
        while searchPages.values.reduce(0, { $0 + $1.count }) >= 100, let first = searchOrder.first, first != query {
            searchPageBytes -= searchPages.removeValue(forKey: searchOrder.removeFirst())?.values.reduce(0, { $0 + $1.utf8.count }) ?? 0
        }
        guard searchPages.values.reduce(0, { $0 + $1.count }) < 100 || searchPages[query]?[page] != nil else { throw LegadoRequestError.limit }
        searchPageBytes -= searchPages[query]?[page]?.utf8.count ?? 0
        searchPages[query]?[page] = url
        searchPageBytes += url.utf8.count
    }
}

/// Executes the original rule dialect in a source worker, preserving the public
/// BookSource contract used by search, reader, cache and downloads.
struct LegadoBookSource: DiscoveryBookSource, @unchecked Sendable {
    let sourceID: String
    let definition: LegadoSourceDefinition
    private let origin: URL?
    private let transport: any HTTPTransport
    private let session: LegadoSourceSession
    private let maximumPages: Int
    private let timeout: TimeInterval

    init(source: DemoSource, transport: any HTTPTransport = SourceHTTPTransport(maximumResponseBytes: 2 * 1024 * 1024), maximumPages: Int = 8, deadline: TimeInterval = 25, state: LegadoPersistentState? = nil, scriptBudget: QuickJSScriptMemoryBudget = .shared) throws {
        sourceID = source.id; definition = try LegadoSourceDefinition.decode(source)
        origin = definition.baseURL; self.transport = transport; session = LegadoSourceSession(state: state, scriptBudget: scriptBudget)
        self.maximumPages = min(32, max(1, maximumPages)); timeout = min(90, max(0.1, deadline))
    }

    private func operation<Value>(prepare: ((LegadoOperationControl) throws -> Void)? = nil, _ body: @escaping (LegadoSourceWorker) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let control = LegadoOperationControl(timeout: timeout)
        // Bind before enqueueing: a queued request must never adopt a newer account.
        control.bindSession(session.state)
        session.track(control); defer { session.untrack(control) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let completion = LegadoCompletion(continuation)
                control.installCancellation { completion.finish(.failure($0)) }
                control.startWatchdog()
                session.queue.async {
                    do {
                        try control.check()
                        try prepare?(control)
                        session.prepareRuntime()
                        let result = try session.runtime.withLease(
                            timeoutSeconds: max(0.01, control.deadline - ProcessInfo.processInfo.systemUptime),
                            cancelled: { do { try control.check(); return false } catch { return true } }
                        ) {
                            try control.check()
                            var policy = definition.policy
                            for origin in try session.state?.allowedOrigins() ?? [] { policy = try policy.addingOrigin(origin.absoluteString) }
                            let http = LegadoHTTPExecutor(origin: origin, policy: policy, state: session.state, inheritedHeaderOrigin: session.inheritedHeaderOrigin, rememberHeaderOrigin: { session.inheritedHeaderOrigin = $0 }, transport: transport, control: control, cookies: session.cookies)
                            let worker = LegadoSourceWorker(sourceID: sourceID, definition: definition, http: http, shared: session, maximumPages: maximumPages)
                            return try body(worker)
                        }
                        try control.check(); completion.finish(.success(result))
                    } catch {
                        do { try control.check(); completion.finish(.failure(error)) }
                        catch { completion.finish(.failure(error)) }
                    }
                }
            }
        }, onCancel: { control.cancel() })
    }

    func login(action: String, values: [String: String]) async throws -> LegadoLoginActionResult {
        try await operation(prepare: { control in
            try control.mutateSession { try session.state?.beginLoginAttempt(values) }
        }) { try $0.login(action: action, values: values) }
    }
    var pendingOperationCount: Int { session.pendingOperationCount }
    func resetRuntime() { session.reset() }
    var supportsDiscovery: Bool { !definition.exploreURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func discoveryCategories() async throws -> [SourceDiscoveryCategory] {
        try await operation { try $0.discoveryCategories() }
    }
    func discover(category: String, page: Int) async throws -> BookSearchPage {
        guard supportsDiscovery, (1...100).contains(page), category.utf8.count <= 64 * 1024 else { throw ContentFailure.invalidResponse }
        return try await operation { try $0.discover(category: category, page: page) }
    }
    func search(query: String, page: Int) async throws -> BookSearchPage {
        guard (1...100).contains(page), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 1024 else { throw ContentFailure.invalidResponse }
        return try await operation { try $0.search(query: query, page: page) }
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { try await operation { try $0.details(book) } }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] { try await operation { try $0.chapters(book) } }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        try await operation { try $0.document(chapter, book: book) }
    }
}

private final class LegadoSourceWorker {
    let sourceID: String
    let definition: LegadoSourceDefinition
    let http: LegadoHTTPExecutor
    let shared: LegadoSourceSession
    let maximumPages: Int
    let context = LegadoRuleContext()
    private var headers: [String: String] = [:]
    private var currentURL: URL
    private var currentContent = ""
    private var scriptContent: String?
    private var bindings: [String: Any] = [:]
    private var scriptDepth = 0
    private var scriptCalls = 0
    private var ruleField = LegadoRuleExecutionError.Field.unknown
    private var ruleInput: String?
    private var bookIdentity = ""
    private var chapterIdentity = ""
    private var useReplaceRule: Bool?
    private var engine: LegadoRuleEngine { LegadoRuleEngine(context: context) }

    init(sourceID: String, definition: LegadoSourceDefinition, http: LegadoHTTPExecutor, shared: LegadoSourceSession, maximumPages: Int) {
        self.sourceID = sourceID; self.definition = definition; self.http = http; self.shared = shared; self.maximumPages = maximumPages
        if let sourceURL = URL(string: definition.sourceURL), sourceURL.user == nil, sourceURL.password == nil,
           http.policy.allows(sourceURL) { currentURL = sourceURL }
        else { currentURL = http.origin ?? URL(string: "zhuying-source://" + StableContentID.make(sourceID) + "/")! }
        bindings = ["source": definition.raw, "key": "", "page": 1, "book": [:], "chapter": [:]]
        context.bindings = bindings
        context.evaluateJS = { [weak self] script, values in
            guard let self else { throw CancellationError() }
            try self.http.control.check()
            guard self.scriptDepth < 4 else { throw LegadoRequestError.limit }
            guard self.scriptCalls < 2048 else { throw LegadoRequestError.scriptEvaluationLimit }
            self.scriptDepth += 1; self.scriptCalls += 1
            defer { self.scriptDepth -= 1 }
            var policy = LegadoScriptPolicy()
            policy.restoreHostErrors = true
            policy.timeoutSeconds = min(5, max(0.1, self.http.control.deadline - ProcessInfo.processInfo.systemUptime))
            policy.cancelled = { do { try self.http.control.check(); return false } catch { return true } }
            let previousContent = self.scriptContent
            self.scriptContent = values["src"] as? String ?? values["result"] as? String ?? self.currentContent
            defer { self.scriptContent = previousContent }
            do {
                return try self.shared.runtime.evaluate(script, bindings: self.bindings.merging(values) { _, value in value }, library: self.libraryScript, policy: policy) { [weak self] method, args in
                    guard let self else { throw CancellationError() }
                    return try self.bridge(method, args: args)
                }
            } catch {
                // The runtime restores a native cause only when the uncaught
                // JS Error is the same object thrown by that native call.
                if let scriptError = error as? QuickJSScriptError, case .javascript = scriptError {
                    throw LegadoRuleExecutionError(field: self.ruleField, cause: error, inputSummary: self.ruleInput.map(LegadoRuleInputSummary.from))
                }
                throw error
            }
        }
    }

    private var libraryScript: String {
        let login = definition.raw["loginUrl"] as? String ?? ""
        let program = login.hasPrefix("@js:") ? String(login.dropFirst(4)) : login
        if ["http", "https"].contains(URL(string: program.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() ?? "") || program.isEmpty { return definition.jsLib }
        return definition.jsLib + "\n;\n" + program
    }
    func login(action: String, values: [String: String]) throws -> LegadoLoginActionResult {
        bindings["result"] = values
        try configure()
        guard action.utf8.count <= 64 * 1024 else { throw LegadoRequestError.limit }
        var script = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if script.hasPrefix("@js:") { script = String(script.dropFirst(4)) }
        if script.hasPrefix("<js>"), script.hasSuffix("</js>") { script = String(script.dropFirst(4).dropLast(5)) }
        _ = try context.evaluateJS?(script, bindings)
        return .init(message: shared.lastMessage.isEmpty ? "操作已完成，登录状态尚未验证。" : shared.lastMessage)
    }

    private func configure(book: LibraryBookRecord? = nil, chapter: ChapterRecord? = nil) throws {
        if let book {
            bookIdentity = book.id
            let storedReplacement = try shared.get("book:" + StableContentID.make(book.id, "") + ":useReplaceRule")
            useReplaceRule = storedReplacement == "false" ? false : storedReplacement == "true" ? true : book.source?.useReplaceRule
            let reference = try reference(book)
            bindings["book"] = ["bookUrl": try shared.resolve(reference.bookURL, baseURL: currentURL).resolvedDescriptor, "name": book.title, "author": book.author, "intro": book.summary, "tocUrl": reference.remoteBookID.isEmpty ? "" : try shared.resolve(reference.remoteBookID, baseURL: currentURL).resolvedDescriptor, "origin": reference.origin ?? "", "variable": try shared.get("book:" + StableContentID.make(book.id, "") + ":variable")]
            var boundBook = bindings["book"] as? [String: Any] ?? [:]
            boundBook["readConfig"] = useReplaceRule.map { ["useReplaceRule": $0] as [String: Any] } ?? NSNull()
            boundBook["type"] = 0
            bindings["book"] = boundBook
            currentURL = try referenceURL(shared.resolve(reference.bookURL, baseURL: currentURL))
        }
        if let chapter { chapterIdentity = chapter.id; bindings["chapter"] = ["url": try shared.resolve(chapter.nativeChapterID, baseURL: currentURL).resolvedDescriptor, "title": chapter.title, "index": chapter.order] }
        context.bindings = bindings
        if definition.header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@js:") {
            let value = try context.evaluateJS?(String(definition.header.dropFirst(4)), context.bindings) ?? NSNull()
            headers = try LegadoHTTPExecutor.headers(value)
        } else {
            headers = try LegadoHTTPExecutor.headers(try engine.template(definition.header, baseURL: currentURL))
        }
    }
    private func reference(_ book: LibraryBookRecord) throws -> SourceBookReference {
        guard let reference = book.source, reference.sourceID == sourceID, reference.origin == identityOrigin else { throw ContentFailure.sourceDisabled }
        return reference
    }
    private var identityOrigin: String { definition.baseURL?.absoluteString ?? "zhuying-source://" + StableContentID.make(sourceID) + "/" }
    private func referenceURL(_ ref: LegadoReference) throws -> URL {
        guard let url = ref.requestURL ?? URL(string: ref.address) else { throw ContentFailure.invalidResponse }; return url
    }
    private func fetch(_ value: String, baseURL: URL? = nil) throws -> LegadoHTTPPage {
        try http.control.check()
        let resolved = value.hasPrefix("legado-ref:") ? try shared.resolve(value, baseURL: baseURL ?? currentURL).resolvedDescriptor : value
        let template = try renderRequest(resolved, baseURL: baseURL ?? currentURL)
        let ref = try LegadoReference.parse(template, baseURL: baseURL ?? currentURL)
        let response: LegadoHTTPPage
        if ref.kind == .inline {
            response = .init(text: ref.inlineHex ?? "", url: try referenceURL(ref), status: 200, headers: [:])
        } else { response = try http.request(ref.resolvedDescriptor, baseURL: baseURL ?? currentURL, headers: headers) }
        currentURL = response.url; currentContent = response.text
        bindings["baseUrl"] = response.url.absoluteString
        context.bindings = bindings
        return response
    }
    private func renderRequest(_ value: String, baseURL: URL) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") || trimmed.hasPrefix("<js>") { return try engine.template(value, content: currentContent, baseURL: baseURL) }
        let (address, rawOptions) = try LegadoHTTPExecutor.split(value)
        func expand(_ value: Any) throws -> Any {
            if let value = value as? String { return try engine.template(value, content: currentContent, baseURL: baseURL) }
            if let value = value as? [String: Any] { return try value.mapValues(expand) }
            if let value = value as? [Any] { return try value.map(expand) }
            return value
        }
        let options = try rawOptions.mapValues(expand)
        var addressTemplate = address
        for key in ["key", "searchKey"] {
            guard let value = bindings[key] as? String else { continue }
            let encoding = try LegadoHTTPExecutor.encoding(options["charset"] as? String)
            guard let bytes = value.data(using: encoding) else { throw LegadoRequestError.invalid("关键词字符集") }
            let encoded = bytes.map { byte -> String in
                let allowed = (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
                return allowed ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
            }.joined()
            addressTemplate = addressTemplate.replacingOccurrences(of: "{{" + key + "}}", with: encoded)
        }
        let rendered = try engine.template(addressTemplate, content: currentContent, baseURL: baseURL)
        guard !options.isEmpty else { return rendered }
        let data = try JSONSerialization.data(withJSONObject: options, options: .sortedKeys)
        return rendered + "," + String(decoding: data, as: UTF8.self)
    }
    private func withRuleField<Value>(_ location: LegadoRuleExecutionError.Field, input: String? = nil, _ body: () throws -> Value) rethrows -> Value {
        let previous = ruleField, previousInput = ruleInput; ruleField = location; ruleInput = input
        defer { ruleField = previous; ruleInput = previousInput }
        return try body()
    }
    private func field(_ rule: String?, in content: String, baseURL: URL, fallback: String = "", structured: Bool = false, location: LegadoRuleExecutionError.Field = .unknown) throws -> String {
        guard let rule, !rule.isEmpty else { return fallback }
        try http.control.check()
        let previous = context.structuredInput; context.structuredInput = structured
        defer { context.structuredInput = previous }
        let result = try withRuleField(location, input: content) { try engine.text(rule, in: content, baseURL: baseURL) }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.utf8.count <= 256 * 1024 else { throw LegadoRequestError.limit }
        return result
    }
    private func url(_ value: String, baseURL: URL) throws -> String {
        let ref = try LegadoReference.parse(value, baseURL: baseURL)
        if let url = ref.requestURL { _ = try http.policy.requireOrigin(for: url); if url.fragment != nil { throw LegadoRequestError.unsupported("依赖 URL fragment 的书籍或章节地址") } }
        return ref.resolvedDescriptor
    }
    private func coverURL(_ value: String, baseURL: URL) -> String? {
        guard !value.isEmpty, let ref = try? LegadoReference.parse(value, baseURL: baseURL), ref.options.isEmpty,
              let url = ref.requestURL, http.policy.allows(url) else { return nil }
        return url.absoluteString
    }
    private func registered(_ value: String, role: String, baseURL: URL) throws -> String {
        try shared.register(.parse(value, baseURL: baseURL), role: role, sourceID: definition.sourceURL)
    }
    private func yes(_ value: String) -> Bool { ["true", "1", "yes"].contains(value.lowercased()) }
    private func rejectUnsupported(_ rules: [String: String], section: String, fields: [String]) throws {
        for field in fields where !(rules[field]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw LegadoCompatibilityError.unsupported(section + "." + field)
        }
    }

    func discoveryCategories() throws -> [SourceDiscoveryCategory] {
        try configure()
        let value = try withRuleField(.exploreURL) { try engine.template(definition.exploreURL, baseURL: currentURL) }
        return try SourceDiscoveryCategory.parse(value)
    }
    func discover(category: String, page: Int) throws -> BookSearchPage {
        let request: String
        if category.isEmpty || category == "全部" {
            guard let first = try discoveryCategories().first(where: \.readable) else { return .init(books: [], nextPage: nil) }
            request = first.request
        } else { request = category }
        return try listing(query: "explore:" + request, page: page, request: request,
                           rules: definition.search.merging(definition.explore) { _, explore in explore }, exploring: true)
    }
    func search(query: String, page: Int) throws -> BookSearchPage {
        try listing(query: query, page: page, request: definition.searchURL, rules: definition.search, exploring: false)
    }
    private func listing(query: String, page: Int, request: String, rules: [String: String], exploring: Bool) throws -> BookSearchPage {
        bindings["key"] = exploring ? "" : query; bindings["searchKey"] = exploring ? "" : query; bindings["page"] = page
        try configure()
        let templateHasPage = request.range(of: #"\{\{\s*page\b"#, options: .regularExpression) != nil ||
            ((request.hasPrefix("@js:") || request.hasPrefix("<js>")) && request.range(of: #"\bpage\b"#, options: .regularExpression) != nil)
        if page == 1 { shared.resetSearch(query) }
        let address: String
        if let next = shared.searchURL(query, page: page) { address = next }
        else {
            guard page == 1 || templateHasPage else { throw LegadoRequestError.unsupported("没有该关键词的下一页地址，请重新搜索") }
            address = request
        }
        let response: LegadoHTTPPage
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if exploring && (trimmed.hasPrefix("@js:") || trimmed.hasPrefix("<js>")) {
            // A category may be a login/browser action with no URL result.
            // Execute once; only a returned route proceeds through HTTP.
            let rendered = try withRuleField(.exploreURL) { try renderRequest(address, baseURL: currentURL) }
            let result = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            let object = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
            if result.isEmpty || ["null", "undefined"].contains(result) || (object?["body"] != nil && object?["url"] != nil && object?["statusCode"] != nil) {
                return .init(books: [], nextPage: nil, feedback: shared.lastMessage.isEmpty ? "操作已完成。" : shared.lastMessage)
            }
            response = try withRuleField(.exploreURL) { try fetch(rendered) }
        } else { response = try withRuleField(exploring ? .exploreURL : .searchURL) { try fetch(address) } }
        let rowRule = rules["bookList"] ?? ""
        let rows = rowRule.isEmpty ? [response.text] : try withRuleField(exploring ? .exploreBookList : .searchBookList) { try engine.elements(rowRule, in: response.text, baseURL: response.url) }
        guard rows.count <= 500 else { throw LegadoRequestError.searchResultLimit }
        var books: [LibraryBookRecord] = [], seen = Set<String>(), budget = LegadoMetadataBudget(), bookReferences: [LegadoReference] = []
        for row in rows {
            let title = try field(rules["name"], in: row, baseURL: response.url, structured: true, location: exploring ? .exploreName : .searchName)
            let address = try field(rules["bookUrl"], in: row, baseURL: response.url, structured: true, location: exploring ? .exploreBookURL : .searchBookURL)
            guard !title.isEmpty, !address.isEmpty else { continue }
            let bookReference = try LegadoReference.parse(url(address, baseURL: response.url), baseURL: response.url)
            let bookURL = try shared.referenceKey(bookReference, role: "book", sourceID: definition.sourceURL)
            let reference = SourceBookReference(sourceID: sourceID, nativeBookID: bookURL, provider: definition.name, bookURL: bookURL, origin: identityOrigin)
            guard seen.insert(reference.id).inserted else { continue }
            let cover = try field(rules["coverUrl"], in: row, baseURL: response.url, structured: true, location: .searchCoverURL)
            let book = LibraryBookRecord(id: "remote-" + reference.id, title: title, author: try field(rules["author"], in: row, baseURL: response.url, structured: true, location: .searchAuthor),
                                         summary: try field(rules["intro"], in: row, baseURL: response.url, structured: true, location: .searchIntro), coverURL: coverURL(cover, baseURL: response.url), source: reference, addedAt: Date())
            try budget.add(book); books.append(book); bookReferences.append(bookReference)
        }
        let next = try field(rules["nextPageUrl"], in: response.text, baseURL: response.url, location: .searchNextPageURL)
        var nextPage: Int?
        if !books.isEmpty, page < 100 {
            if !next.isEmpty {
                try shared.rememberSearchURL(url(next, baseURL: response.url), query: query, page: page + 1)
                nextPage = page + 1
            } else if rules["nextPageUrl"] == nil && templateHasPage { nextPage = page + 1 }
        }
        try shared.registerBatch(bookReferences, role: "book", sourceID: definition.sourceURL)
        return .init(books: books, nextPage: nextPage, feedback: shared.lastMessage.isEmpty ? nil : shared.lastMessage)
    }

    func details(_ book: LibraryBookRecord) throws -> LibraryBookRecord {
        try rejectUnsupported(definition.bookInfo, section: "ruleBookInfo", fields: ["downloadUrls"])
        let reference = try reference(book)
        try configure(book: book)
        let response = try fetch(reference.bookURL)
        let rules = definition.bookInfo
        let input: String, structuredInput: Bool
        if let initialize = rules["init"], !initialize.isEmpty {
            let selected = try withRuleField(.bookInfoInit, input: response.text) { try engine.initializedContent(initialize, in: response.text, baseURL: response.url) }
            input = selected.text; structuredInput = selected.structured
        } else { input = response.text; structuredInput = false }
        var result = book
        let title = try field(rules["name"], in: input, baseURL: response.url, structured: structuredInput, location: .bookInfoName)
        if !title.isEmpty { result.title = title }
        let author = try field(rules["author"], in: input, baseURL: response.url, structured: structuredInput, location: .bookInfoAuthor)
        if !author.isEmpty { result.author = author }
        result.summary = try field(rules["intro"], in: input, baseURL: response.url, fallback: result.summary, structured: structuredInput, location: .bookInfoIntro)
        let cover = try field(rules["coverUrl"], in: input, baseURL: response.url, structured: structuredInput, location: .bookInfoCoverURL)
        if !cover.isEmpty { result.coverURL = coverURL(cover, baseURL: response.url) }
        let toc = try field(rules["tocUrl"], in: input, baseURL: response.url, structured: structuredInput, location: .bookInfoTOCURL)
        if !toc.isEmpty { result.source?.remoteBookID = try registered(url(toc, baseURL: response.url), role: "toc", baseURL: response.url) }
        result.source?.useReplaceRule = useReplaceRule
        return result
    }

    func chapters(_ book: LibraryBookRecord) throws -> [ChapterRecord] {
        try rejectUnsupported(definition.toc, section: "ruleToc", fields: ["preUpdateJs", "formatJs"])
        var book = book
        if try reference(book).remoteBookID.isEmpty, definition.bookInfo["tocUrl"] != nil { book = try details(book) }
        let reference = try reference(book)
        try configure(book: book)
        var pending = [reference.remoteBookID.isEmpty ? reference.bookURL : reference.remoteBookID], visited = Set<String>()
        var chapters: [ChapterRecord] = [], seen = Set<String>(), initialBudget = LegadoMetadataBudget(), chapterReferences: [LegadoReference] = []
        var rowsRule = definition.toc["chapterList"] ?? ""
        let reversed = rowsRule.hasPrefix("-")
        if reversed { rowsRule.removeFirst() }
        while !pending.isEmpty {
            try http.control.check()
            let address = pending.removeFirst()
            guard visited.insert(address).inserted else { continue }
            guard visited.count <= maximumPages else { throw LegadoRequestError.limit }
            let response = try fetch(address)
            let rows = rowsRule.isEmpty ? [response.text] : try withRuleField(.tocChapterList) { try engine.elements(rowsRule, in: response.text, baseURL: response.url) }
            for row in rows {
                let title = try field(definition.toc["chapterName"], in: row, baseURL: response.url, structured: true, location: .tocChapterName)
                guard !title.isEmpty else { continue }
                let isVolume = yes(try field(definition.toc["isVolume"], in: row, baseURL: response.url, structured: true, location: .tocIsVolume))
                let address = try field(definition.toc["chapterUrl"], in: row, baseURL: response.url, structured: true, location: .tocChapterURL)
                guard isVolume || !address.isEmpty else { continue }
                let ref = isVolume && address.isEmpty ? nil : try LegadoReference.parse(url(address, baseURL: response.url), baseURL: response.url)
                let chapterURL = try ref.map { try shared.referenceKey($0, role: "chapter", sourceID: definition.sourceURL) } ?? "legado-volume:" + StableContentID.make(book.id, title)
                guard seen.insert(chapterURL).inserted else { continue }
                let restricted = yes(try field(definition.toc["isVip"] ?? definition.toc["isPay"], in: row, baseURL: response.url, structured: true, location: definition.toc["isVip"] != nil ? .tocIsVIP : .tocIsPay))
                let chapter = ChapterRecord(id: StableContentID.make(book.id, chapterURL), bookID: book.id, nativeChapterID: chapterURL, title: title, order: chapters.count,
                                            access: isVolume ? .volume : restricted ? .restricted : .readable)
                try initialBudget.add(chapter); chapters.append(chapter); if let ref { chapterReferences.append(ref) }
                guard chapters.count <= 50_000 else { throw LegadoRequestError.limit }
            }
            if let nextRule = definition.toc["nextTocUrl"], !nextRule.isEmpty {
                for value in try withRuleField(.tocNextURL) { try engine.list(nextRule, in: response.text, baseURL: response.url) } where !value.isEmpty {
                    let next = try url(value, baseURL: response.url)
                    if !visited.contains(next), !pending.contains(next) { pending.append(next) }
                }
            }
        }
        try shared.registerBatch(chapterReferences, role: "chapter", sourceID: definition.sourceURL)
        if reversed { chapters.reverse() }
        var previousURL: String?
        for index in chapters.indices {
            chapters[index].order = index
            chapters[index].requestParameters["legado.previousChapterURL"] = previousURL
            if chapters[index].access != .volume { previousURL = chapters[index].nativeChapterID }
        }
        var nextURL: String?
        for index in chapters.indices.reversed() {
            chapters[index].requestParameters["legado.nextChapterURL"] = nextURL
            if chapters[index].access != .volume { nextURL = chapters[index].nativeChapterID }
        }
        var finalBudget = LegadoMetadataBudget()
        for chapter in chapters { try finalBudget.add(chapter) }
        try shared.catalog(Set(chapters.filter { $0.access != .volume }.map(\.nativeChapterID)), bookID: book.id)
        guard !chapters.isEmpty else { throw ContentFailure.missingChapter }
        return chapters
    }

    func document(_ chapter: ChapterRecord, book: LibraryBookRecord) throws -> ChapterDocument {
        try rejectUnsupported(definition.content, section: "ruleContent", fields: ["webJs", "sourceRegex", "replaceRegex", "payAction"])
        _ = try reference(book)
        guard chapter.bookID == book.id, chapter.access == .readable else { throw ContentFailure.restricted }
        try configure(book: book, chapter: chapter)
        let knownChapters = shared.catalog(bookID: book.id).union([chapter.requestParameters["legado.nextChapterURL"], chapter.requestParameters["legado.previousChapterURL"]].compactMap { $0 })
        let own = try shared.resolve(chapter.nativeChapterID, baseURL: currentURL)
        var otherURLs = Set<String>()
        for key in knownChapters where key != chapter.nativeChapterID {
            let ref = try shared.resolve(key, baseURL: currentURL)
            if let url = ref.requestURL, url != own.requestURL { otherURLs.insert(url.absoluteString) }
        }
        func isAnotherChapter(_ descriptor: String, baseURL: URL) throws -> Bool {
            let ref = try shared.resolve(descriptor, baseURL: baseURL)
            let key = try shared.referenceKey(ref, role: "chapter", sourceID: definition.sourceURL)
            if key != chapter.nativeChapterID, knownChapters.contains(key) { return true }
            return ref.requestURL.map { otherURLs.contains($0.absoluteString) } ?? false
        }
        var pending = [chapter.nativeChapterID], visited = Set<String>(), paragraphs: [String] = []
        while !pending.isEmpty {
            let address = pending.removeFirst()
            guard visited.insert(address).inserted else { continue }
            guard visited.count <= maximumPages else { throw LegadoRequestError.limit }
            let response = try fetch(address)
            if otherURLs.contains(response.url.absoluteString) { break }
            let raw = try field(definition.content["content"], in: response.text, baseURL: response.url, location: .content)
            let extracted = try Self.paragraphs(raw)
            // Split pages commonly repeat a paragraph at their boundary. Keep
            // repetitions elsewhere, where they may be intentional prose.
            var additions = extracted
            if let first = additions.first, paragraphs.last == first { additions.removeFirst() }
            paragraphs += additions
            guard paragraphs.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw LegadoRequestError.limit }
            if let next = definition.content["nextContentUrl"], !next.isEmpty {
                for value in try withRuleField(.contentNextURL) { try engine.list(next, in: response.text, baseURL: response.url) } where !value.isEmpty {
                    let next = try url(value, baseURL: response.url)
                    if try isAnotherChapter(next, baseURL: response.url) { continue }
                    if !visited.contains(next), !pending.contains(next) { pending.append(next) }
                }
            }
        }
        guard !paragraphs.isEmpty else { throw ContentFailure.missingChapter }
        return .init(chapterID: chapter.id, paragraphs: paragraphs)
    }

    private static func paragraphs(_ value: String) throws -> [String] {
        let broken = value.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
        let plain: String
        if broken.contains("<"), broken.contains(">") {
            // Fuzi nodes keep an unowned document reference. A temporary
            // document can free the libxml tree before stringValue is read.
            let parsed = try HTMLDocument(string: "<div>" + broken + "</div>")
            plain = withExtendedLifetime(parsed) { parsed.root?.stringValue ?? broken }
        }
        else { plain = broken }
        return plain.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func bridge(_ method: String, args: [Any]) throws -> Any {
        try http.control.check()
        func string(_ index: Int, fallback: String = "") -> String { args.indices.contains(index) ? (args[index] as? String ?? String(describing: args[index])) : fallback }
        switch method {
        case "java.ajax", "java.get", "java.post", "java.head", "java.connect":
            if method == "java.get", args.count == 1, !string(0).contains("://"), !string(0).hasPrefix("/") { return try context.variables[string(0)] ?? shared.get(javaVariableKey(string(0))) }
            var options: [String: Any] = [:]
            if method == "java.post" { options = ["method": "POST", "body": args.indices.contains(1) ? args[1] : ""] }
            if method == "java.head" { options["method"] = "HEAD" }
            let headerIndex = method == "java.post" ? 2 : 1
            if args.indices.contains(headerIndex), !(args[headerIndex] is NSNull) { options["headers"] = args[headerIndex] }
            let response = try http.request(try renderRequest(string(0), baseURL: currentURL), baseURL: currentURL, headers: headers, override: options)
            return method == "java.ajax" ? response.text : response.bridgeValue
        case "java.put":
            let key = string(0), value = string(1); try shared.set(javaVariableKey(key), value); context.variables[key] = value; return value
        case "java.getString": return try engine.text(string(0), in: scriptContent ?? currentContent, baseURL: currentURL)
        case "java.getStringList": return try engine.list(string(0), in: scriptContent ?? currentContent, baseURL: currentURL)
        case "java.getElements": return try engine.elements(string(0), in: scriptContent ?? currentContent, baseURL: currentURL)
        case "source.getVariable", "book.getVariable", "chapter.getVariable":
            return try shared.get(variableScope(method) + (args.isEmpty ? "variable" : string(0)))
        case "source.setVariable", "book.setVariable", "chapter.setVariable":
            let key = args.count == 1 ? "variable" : string(0), value = args.count == 1 ? string(0) : string(1)
            try shared.set(variableScope(method) + key, value); return value
        case "book.getUseReplaceRule": return useReplaceRule ?? true
        case "book.setUseReplaceRule":
            guard !bookIdentity.isEmpty, let flag = args.first as? Bool else { throw LegadoRequestError.invalid("书籍替换规则开关") }
            try shared.set(variableScope("book.put") + "useReplaceRule", flag ? "true" : "false")
            useReplaceRule = flag
            var boundBook = bindings["book"] as? [String: Any] ?? [:]
            boundBook["readConfig"] = ["useReplaceRule": flag]; bindings["book"] = boundBook; context.bindings = bindings
            return NSNull()
        case "source.getKey", "source.getBookSourceUrl", "source.getUrl": return definition.sourceURL
        case "source.getBookSourceName", "source.getName": return definition.name
        case "book.getName", "book.getTitle", "book.getAuthor", "book.getTocUrl", "book.getBookUrl", "book.getUrl",
             "chapter.getName", "chapter.getTitle", "chapter.getUrl", "chapter.getChapterUrl", "chapter.getChapterIndex", "chapter.getIndex":
            let parts = method.components(separatedBy: "."), kind = parts[0]
            let aliases = ["getName": kind == "chapter" ? "title" : "name", "getTitle": kind == "chapter" ? "title" : "name", "getAuthor": "author", "getTocUrl": "tocUrl", "getBookUrl": "bookUrl", "getUrl": kind == "chapter" ? "url" : "bookUrl", "getChapterUrl": "url", "getChapterIndex": "index", "getIndex": "index"]
            return (bindings[kind] as? [String: Any])?[aliases[parts[1]] ?? ""] ?? NSNull()
        case "source.get", "book.get", "chapter.get": return try shared.get(variableScope(method) + string(0))
        case "source.put", "book.put", "chapter.put":
            try shared.set(variableScope(method) + string(0), string(1)); return string(1)
        case "source.getLoginInfo": return try shared.state?.getLoginInfo() ?? ""
        case "source.getLoginInfoMap": return try shared.state?.getLoginInfoMap() ?? [:]
        case "source.putLoginInfo": try http.control.mutateSession { try requiredState().putLoginInfo(string(0)) }; return true
        case "source.deleteLoginInfo": try http.control.mutateSession { try requiredState().logout() }; return true
        case "source.getLoginHeader", "source.getHeaderMap":
            let value = try shared.get(loginHeaderKey)
            return value.isEmpty ? [:] : try LegadoHTTPExecutor.headers(value)
        case "source.setLoginHeader", "source.putLoginHeader":
            let value = args.first is [String: Any] ? String(decoding: try JSONSerialization.data(withJSONObject: args[0], options: [.sortedKeys]), as: UTF8.self) : string(0)
            _ = try LegadoHTTPExecutor.headers(value); try shared.set(loginHeaderKey, value); return true
        case "cache.get", "cache.getFromMemory": return try requiredState().cacheGet(string(0), memory: method == "cache.getFromMemory") ?? NSNull()
        case "cache.put", "cache.putMemory":
            try requiredState().cachePut(string(1), key: string(0), ttl: args.count > 2 ? (args[2] as? NSNumber)?.doubleValue : nil, memory: method == "cache.putMemory"); return true
        case "cache.delete", "cache.remove": try requiredState().cachePut("", key: string(0), ttl: 0); return true
        case "cookie.getCookie", "cookie.getKey", "java.getCookie":
            let url = try cookieURL(string(0, fallback: currentURL.absoluteString))
            let values = try shared.state?.cookies(for: url)
            let value = values.map { HTTPCookie.requestHeaderFields(with: $0)["Cookie"] ?? "" } ?? shared.cookies.header(for: url) ?? ""
            if args.count > 1 {
                return value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(string(1) + "=") }.map { String($0.dropFirst(string(1).count + 1)) } ?? ""
            }
            return value
        case "cookie.setCookie":
            let url = try cookieURL(string(0))
            shared.cookies.set(string(1), url: url)
            try shared.state?.setCookies(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": string(1)], for: url), for: url, expectedSessionRevision: http.control.sessionRevision); return true
        case "cookie.removeCookie":
            let url = args.isEmpty ? nil : try cookieURL(string(0))
            try shared.state?.clearCookies(origin: url); shared.cookies.remove(url: url); return true
        case "java.deviceID", "java.androidId": return try requiredState().deviceIdentifier()
        case "java.getWebViewUA":
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os.majorVersion)_\(os.minorVersion) like Mac OS X) AppleWebKit/605.1.15 Mobile Safari/604.1 Zhuying"
        case "java.timeFormat", "java.timeFormatUTC":
            guard let milliseconds = args.first as? NSNumber, milliseconds.doubleValue.isFinite, abs(milliseconds.doubleValue) <= 8.64e15 else { throw LegadoRequestError.invalid("时间戳") }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = method == "java.timeFormatUTC" ? string(1) : "yyyy-MM-dd HH:mm:ss"
            if method == "java.timeFormatUTC" {
                guard args.count > 2, let offset = args[2] as? NSNumber, let zone = TimeZone(secondsFromGMT: offset.intValue / 1000) else { throw LegadoRequestError.invalid("UTC 时区偏移") }; formatter.timeZone = zone
            }
            return formatter.string(from: Date(timeIntervalSince1970: milliseconds.doubleValue / 1000))
        case "java.toast", "java.longToast", "java.log":
            if method != "java.log" { shared.lastMessage = String(string(0).prefix(4096)) }; return NSNull()
        case "java.startBrowserAwait", "java.startBrowser", "java.showBrowser", "java.showReadingBrowser", "java.startBrowserDp": return try browser(method, args: args)
        case "crypto.encrypt", "crypto.decrypt", "crypto.decodeText", "android.base64Encode", "android.base64Decode": return try LegadoCryptoHost.evaluate(method, args: args)
        case "java.base64Encode": return try LegadoCryptoHost.base64Encode(Data(string(0).utf8), flags: args.count > 1 ? (args[1] as? NSNumber)?.intValue ?? 2 : 2)
        case "java.base64Decode":
            let flags = args.count > 1 ? (args[1] as? NSNumber)?.intValue ?? 0 : 0
            let data = try LegadoCryptoHost.base64Decode(string(0), flags: flags)
            return try LegadoHTTPExecutor.decode(data, charset: args.count > 1 && args[1] is String ? string(1) : "utf-8")
        case "java.encodeURI": return string(0).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        case "java.decodeURI": return string(0).removingPercentEncoding ?? string(0)
        case "java.md5Encode": return StableContentID.hex(Insecure.MD5.hash(data: Data(string(0).utf8)))
        case "java.hexDecodeToString":
            let value = string(0); guard value.count % 2 == 0 else { throw LegadoRequestError.invalid("Hex") }
            var data = Data(), index = value.startIndex
            while index < value.endIndex { let end = value.index(index, offsetBy: 2); guard let byte = UInt8(value[index..<end], radix: 16) else { throw LegadoRequestError.invalid("Hex") }; data.append(byte); index = end }
            return try LegadoHTTPExecutor.decode(data, charset: nil)
        default: throw LegadoRequestError.unsupported("脚本宿主方法 \(method)")
        }
    }
    private func requiredState() throws -> LegadoPersistentState {
        guard let state = shared.state else { throw LegadoRequestError.unsupported("此书源缺少持久会话") }; return state
    }
    private func cookieURL(_ value: String) throws -> URL {
        let address = value.contains("://") ? value : "https://" + value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let url = try http.absolute(address, baseURL: currentURL)
        _ = try http.policy.requireOrigin(for: url); return url
    }
    private func browser(_ method: String, args: [Any]) throws -> Any {
        guard let address = args.first as? String else { throw LegadoInteractionError.invalidRequest }
        var html: String?, script: String?, title = args.count > 1 ? args[1] as? String ?? "书源网页" : "书源网页"
        let target: URL
        if address.hasPrefix("data:text/html;base64,") {
            let data = try LegadoCryptoHost.base64Decode(String(address.dropFirst(22)), flags: 0)
            guard data.count <= 2 * 1024 * 1024, let value = String(data: data, encoding: .utf8) else { throw LegadoInteractionError.invalidRequest }
            html = value; target = URL(string: "about:blank")!
        } else { target = try http.absolute(address, baseURL: currentURL); _ = try http.policy.requireOrigin(for: target) }
        if method == "java.showBrowser" {
            html = args.count > 1 ? args[1] as? String : nil; script = args.count > 2 ? args[2] as? String : nil; title = "书源网页"
        }
        let request = LegadoBrowserRequest(sourceID: sourceID, accountID: shared.state?.accountID ?? "default", libraryProfile: shared.state?.scope.libraryProfile ?? "production", url: target, title: title, html: html, javaScript: script, allowedOrigins: http.policy.allowedOrigins)
        try request.validate(); try http.control.beginInteraction(); defer { http.control.endInteraction() }
        let waiter = LegadoBlockingResult<LegadoBrowserResult>(), identifier = UUID(), control = http.control
        let task = Task.detached { [request] in
            defer { control.remove(identifier) }
            do { waiter.complete(.success(try await LegadoInteractionCoordinator.shared.requestBrowser(request))) }
            catch { waiter.complete(.failure(error)) }
        }
        control.add(task, id: identifier)
        defer { task.cancel(); control.remove(identifier) }
        let result = try waiter.wait(control: control)
        for (origin, cookies) in result.cookiesByOrigin {
            guard let url = URL(string: origin) else { throw LegadoInteractionError.invalidRequest }
            _ = try http.policy.requireOrigin(for: url); try shared.state?.replaceCookies(cookies, for: url, expectedSessionRevision: http.control.sessionRevision)
        }
        return ["body": result.html, "url": result.finalURL.absoluteString, "statusCode": 200, "headers": [:]] as [String: Any]
    }
    private var loginHeaderKey: String {
        let origin = try? LegadoSourcePolicy.canonicalOrigin(currentURL)
        return "source:loginHeader:" + (origin?.absoluteString ?? "unbound")
    }
    private func javaVariableKey(_ key: String) -> String { "java:" + (bookIdentity.isEmpty ? "source" : bookIdentity) + ":" + key }
    private func variableScope(_ method: String) -> String {
        let kind = method.components(separatedBy: ".")[0]
        let book = bookIdentity
        let chapter = chapterIdentity
        return kind == "source" ? "source:" : kind + ":" + StableContentID.make(book, kind == "chapter" ? chapter : "") + ":"
    }
}
