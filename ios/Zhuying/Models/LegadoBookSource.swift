import Foundation
import CryptoKit
import Fuzi

private final class LegadoCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class LegadoSourceSession: @unchecked Sendable {
    let cookies = LegadoCookieJar()
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var valueBytes = 0
    private var catalogs: [String: Set<String>] = [:]
    private var catalogOrder: [String] = []
    private var searchPages: [String: [Int: String]] = [:]
    private var searchOrder: [String] = []
    func get(_ key: String) -> String { lock.lock(); defer { lock.unlock() }; return values[key] ?? "" }
    func set(_ key: String, _ value: String) throws {
        guard key.utf8.count <= 512, value.utf8.count <= 128 * 1024 else { throw LegadoRequestError.limit }
        lock.lock(); defer { lock.unlock() }
        guard values.count < 512 || values[key] != nil else { throw LegadoRequestError.limit }
        let oldSize = values[key].map { key.utf8.count + $0.utf8.count } ?? 0
        let nextSize = valueBytes - oldSize + key.utf8.count + value.utf8.count
        guard nextSize <= 512 * 1024 else { throw LegadoRequestError.limit }
        values[key] = value; valueBytes = nextSize
    }
    func catalog(_ urls: Set<String>, bookID: String) {
        lock.lock(); defer { lock.unlock() }
        catalogs[bookID] = urls; catalogOrder.removeAll { $0 == bookID }; catalogOrder.append(bookID)
        while catalogOrder.count > 32 { catalogs.removeValue(forKey: catalogOrder.removeFirst()) }
    }
    func catalog(bookID: String) -> Set<String> { lock.lock(); defer { lock.unlock() }; return catalogs[bookID] ?? [] }
    func resetSearch(_ query: String) {
        lock.lock(); defer { lock.unlock() }
        searchPages[query] = [:]; searchOrder.removeAll { $0 == query }; searchOrder.append(query)
        while searchOrder.count > 8 { searchPages.removeValue(forKey: searchOrder.removeFirst()) }
    }
    func searchURL(_ query: String, page: Int) -> String? { lock.lock(); defer { lock.unlock() }; return searchPages[query]?[page] }
    func rememberSearchURL(_ url: String, query: String, page: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard searchPages[query] != nil else { throw ContentFailure.invalidResponse }
        while searchPages.values.reduce(0, { $0 + $1.count }) >= 100, let first = searchOrder.first, first != query {
            searchPages.removeValue(forKey: searchOrder.removeFirst())
        }
        guard searchPages.values.reduce(0, { $0 + $1.count }) < 100 || searchPages[query]?[page] != nil else { throw LegadoRequestError.limit }
        searchPages[query]?[page] = url
    }
}

/// Executes the original rule dialect in a source worker, preserving the public
/// BookSource contract used by search, reader, cache and downloads.
struct LegadoBookSource: BookSource, @unchecked Sendable {
    let sourceID: String
    let definition: LegadoSourceDefinition
    private let origin: URL
    private let transport: any HTTPTransport
    private let session: LegadoSourceSession
    private let maximumPages: Int
    private let timeout: TimeInterval

    init(source: DemoSource, transport: any HTTPTransport = SourceHTTPTransport(maximumResponseBytes: 2 * 1024 * 1024), maximumPages: Int = 8, deadline: TimeInterval = 25) throws {
        sourceID = source.id; definition = try LegadoSourceDefinition.decode(source)
        origin = definition.baseURL; self.transport = transport; session = LegadoSourceSession()
        self.maximumPages = min(32, max(1, maximumPages)); timeout = min(90, max(0.1, deadline))
    }

    private func operation<Value>(_ body: @escaping (LegadoSourceWorker) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let control = LegadoOperationControl(timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let completion = LegadoCompletion(continuation)
                control.installCancellation { completion.finish(.failure($0)) }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { control.cancel(ContentFailure.timedOut) }
                DispatchQueue(label: "com.zhuying.legado." + sourceID, qos: .userInitiated).async {
                    do {
                        try control.check()
                        let http = LegadoHTTPExecutor(origin: origin, transport: transport, control: control, cookies: session.cookies)
                        let worker = LegadoSourceWorker(sourceID: sourceID, definition: definition, http: http, shared: session, maximumPages: maximumPages)
                        let result = try body(worker)
                        try control.check(); completion.finish(.success(result))
                    } catch {
                        do { try control.check(); completion.finish(.failure(error)) }
                        catch { completion.finish(.failure(error)) }
                    }
                }
            }
        }, onCancel: { control.cancel() })
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
    private var engine: LegadoRuleEngine { LegadoRuleEngine(context: context) }

    init(sourceID: String, definition: LegadoSourceDefinition, http: LegadoHTTPExecutor, shared: LegadoSourceSession, maximumPages: Int) {
        self.sourceID = sourceID; self.definition = definition; self.http = http; self.shared = shared; self.maximumPages = maximumPages
        currentURL = http.origin
        bindings = ["source": definition.raw, "key": "", "page": 1, "book": [:], "chapter": [:]]
        context.bindings = bindings
        context.evaluateJS = { [weak self] script, values in
            guard let self else { throw CancellationError() }
            try self.http.control.check()
            guard self.scriptDepth < 4, self.scriptCalls < 128 else { throw LegadoRequestError.limit }
            self.scriptDepth += 1; self.scriptCalls += 1
            defer { self.scriptDepth -= 1 }
            var policy = LegadoScriptPolicy()
            policy.timeoutSeconds = min(5, max(0.1, self.http.control.deadline - ProcessInfo.processInfo.systemUptime))
            policy.cancelled = { do { try self.http.control.check(); return false } catch { return true } }
            let previousContent = self.scriptContent
            self.scriptContent = values["src"] as? String ?? values["result"] as? String ?? self.currentContent
            defer { self.scriptContent = previousContent }
            return try QuickJSScriptRuntime.evaluate(script, bindings: self.bindings.merging(values) { _, value in value }, library: self.definition.jsLib, policy: policy) { [weak self] method, args in
                guard let self else { throw CancellationError() }
                return try self.bridge(method, args: args)
            }
        }
    }

    private func configure(book: LibraryBookRecord? = nil, chapter: ChapterRecord? = nil) throws {
        if let book {
            let reference = try reference(book)
            bindings["book"] = ["bookUrl": reference.bookURL, "name": book.title, "author": book.author, "intro": book.summary, "tocUrl": reference.remoteBookID, "origin": reference.origin ?? ""]
            currentURL = try http.absolute(reference.bookURL)
        }
        if let chapter { bindings["chapter"] = ["url": chapter.nativeChapterID, "title": chapter.title, "index": chapter.order] }
        context.bindings = bindings
        if definition.header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@js:") {
            let value = try context.evaluateJS?(String(definition.header.dropFirst(4)), context.bindings) ?? NSNull()
            headers = try LegadoHTTPExecutor.headers(value)
        } else {
            headers = try LegadoHTTPExecutor.headers(try engine.template(definition.header, baseURL: currentURL))
        }
    }
    private func reference(_ book: LibraryBookRecord) throws -> SourceBookReference {
        guard let reference = book.source, reference.sourceID == sourceID, reference.origin == http.origin.absoluteString else { throw ContentFailure.sourceDisabled }
        return reference
    }
    private func fetch(_ value: String, baseURL: URL? = nil) throws -> LegadoHTTPPage {
        try http.control.check()
        let template = try renderRequest(value, baseURL: baseURL ?? currentURL)
        let response = try http.request(template, baseURL: baseURL ?? currentURL, headers: headers)
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
    private func field(_ rule: String?, in content: String, baseURL: URL, fallback: String = "", structured: Bool = false) throws -> String {
        guard let rule, !rule.isEmpty else { return fallback }
        try http.control.check()
        let previous = context.structuredInput; context.structuredInput = structured
        defer { context.structuredInput = previous }
        let result = try engine.text(rule, in: content, baseURL: baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.utf8.count <= 256 * 1024 else { throw LegadoRequestError.limit }
        return result
    }
    private func url(_ value: String, baseURL: URL) throws -> String {
        let (address, options) = try LegadoHTTPExecutor.split(value)
        guard options.isEmpty else { throw LegadoRequestError.unsupported("书籍、目录或章节地址附带请求选项") }
        let components = URLComponents(url: try http.absolute(address, baseURL: baseURL), resolvingAgainstBaseURL: false)
        guard components?.fragment?.isEmpty ?? true else { throw LegadoRequestError.unsupported("依赖 URL fragment 的书籍或章节地址") }
        guard let result = components?.url else { throw ContentFailure.invalidResponse }
        return result.absoluteString
    }
    private func yes(_ value: String) -> Bool { ["true", "1", "yes"].contains(value.lowercased()) }
    private func rejectUnsupported(_ rules: [String: String], section: String, fields: [String]) throws {
        for field in fields where !(rules[field]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw LegadoCompatibilityError.unsupported(section + "." + field)
        }
    }

    func search(query: String, page: Int) throws -> BookSearchPage {
        bindings["key"] = query; bindings["searchKey"] = query; bindings["page"] = page
        try configure()
        let templateHasPage = definition.searchURL.range(of: #"\{\{\s*page\b"#, options: .regularExpression) != nil ||
            ((definition.searchURL.hasPrefix("@js:") || definition.searchURL.hasPrefix("<js>")) && definition.searchURL.range(of: #"\bpage\b"#, options: .regularExpression) != nil)
        if page == 1 { shared.resetSearch(query) }
        let address: String
        if let next = shared.searchURL(query, page: page) { address = next }
        else {
            guard page == 1 || templateHasPage else { throw LegadoRequestError.unsupported("没有该关键词的下一页地址，请重新搜索") }
            address = definition.searchURL
        }
        let response = try fetch(address)
        let rules = definition.search
        let rowRule = rules["bookList"] ?? ""
        let rows = rowRule.isEmpty ? [response.text] : try engine.elements(rowRule, in: response.text, baseURL: response.url)
        guard rows.count <= 500 else { throw LegadoRequestError.limit }
        var books: [LibraryBookRecord] = [], seen = Set<String>()
        for row in rows {
            let title = try field(rules["name"], in: row, baseURL: response.url, structured: true)
            let address = try field(rules["bookUrl"], in: row, baseURL: response.url, structured: true)
            guard !title.isEmpty, !address.isEmpty else { continue }
            let bookURL = try url(address, baseURL: response.url)
            let reference = SourceBookReference(sourceID: sourceID, nativeBookID: bookURL, provider: definition.name, bookURL: bookURL, origin: http.origin.absoluteString)
            guard seen.insert(reference.id).inserted else { continue }
            let cover = try field(rules["coverUrl"], in: row, baseURL: response.url, structured: true)
            books.append(.init(id: "remote-" + reference.id, title: title, author: try field(rules["author"], in: row, baseURL: response.url, structured: true),
                               summary: try field(rules["intro"], in: row, baseURL: response.url, structured: true), coverURL: cover.isEmpty ? nil : try url(cover, baseURL: response.url), source: reference, addedAt: Date()))
        }
        let next = try field(rules["nextPageUrl"], in: response.text, baseURL: response.url)
        var nextPage: Int?
        if !books.isEmpty, page < 100 {
            if !next.isEmpty {
                try shared.rememberSearchURL(url(next, baseURL: response.url), query: query, page: page + 1)
                nextPage = page + 1
            } else if rules["nextPageUrl"] == nil && templateHasPage { nextPage = page + 1 }
        }
        return .init(books: books, nextPage: nextPage)
    }

    func details(_ book: LibraryBookRecord) throws -> LibraryBookRecord {
        try rejectUnsupported(definition.bookInfo, section: "ruleBookInfo", fields: ["downloadUrls"])
        let reference = try reference(book)
        try configure(book: book)
        let response = try fetch(reference.bookURL)
        let rules = definition.bookInfo
        let input: String
        if let initialize = rules["init"], !initialize.isEmpty { input = try engine.elements(initialize, in: response.text, baseURL: response.url).joined(separator: "\n") }
        else { input = response.text }
        var result = book
        let title = try field(rules["name"], in: input, baseURL: response.url)
        if !title.isEmpty { result.title = title }
        let author = try field(rules["author"], in: input, baseURL: response.url)
        if !author.isEmpty { result.author = author }
        result.summary = try field(rules["intro"], in: input, baseURL: response.url, fallback: result.summary)
        let cover = try field(rules["coverUrl"], in: input, baseURL: response.url)
        if !cover.isEmpty { result.coverURL = try url(cover, baseURL: response.url) }
        let toc = try field(rules["tocUrl"], in: input, baseURL: response.url)
        if !toc.isEmpty { result.source?.remoteBookID = try url(toc, baseURL: response.url) }
        return result
    }

    func chapters(_ book: LibraryBookRecord) throws -> [ChapterRecord] {
        try rejectUnsupported(definition.toc, section: "ruleToc", fields: ["preUpdateJs", "formatJs"])
        var book = book
        if try reference(book).remoteBookID.isEmpty, definition.bookInfo["tocUrl"] != nil { book = try details(book) }
        let reference = try reference(book)
        try configure(book: book)
        var pending = [reference.remoteBookID.isEmpty ? reference.bookURL : reference.remoteBookID], visited = Set<String>()
        var chapters: [ChapterRecord] = [], seen = Set<String>()
        var rowsRule = definition.toc["chapterList"] ?? ""
        let reversed = rowsRule.hasPrefix("-")
        if reversed { rowsRule.removeFirst() }
        while !pending.isEmpty {
            try http.control.check()
            let address = pending.removeFirst()
            guard visited.insert(address).inserted else { continue }
            guard visited.count <= maximumPages else { throw LegadoRequestError.limit }
            let response = try fetch(address)
            let rows = rowsRule.isEmpty ? [response.text] : try engine.elements(rowsRule, in: response.text, baseURL: response.url)
            for row in rows {
                let title = try field(definition.toc["chapterName"], in: row, baseURL: response.url, structured: true)
                guard !title.isEmpty else { continue }
                let isVolume = yes(try field(definition.toc["isVolume"], in: row, baseURL: response.url, structured: true))
                let address = try field(definition.toc["chapterUrl"], in: row, baseURL: response.url, structured: true)
                guard isVolume || !address.isEmpty else { continue }
                let chapterURL = isVolume && address.isEmpty ? response.url.absoluteString + "#volume-" + StableContentID.make(title) : try url(address, baseURL: response.url)
                guard seen.insert(chapterURL).inserted else { continue }
                let restricted = yes(try field(definition.toc["isVip"] ?? definition.toc["isPay"], in: row, baseURL: response.url, structured: true))
                chapters.append(.init(id: StableContentID.make(book.id, chapterURL), bookID: book.id, nativeChapterID: chapterURL, title: title, order: chapters.count,
                                      access: isVolume ? .volume : restricted ? .restricted : .readable))
                guard chapters.count <= 50_000 else { throw LegadoRequestError.limit }
            }
            if let nextRule = definition.toc["nextTocUrl"], !nextRule.isEmpty {
                for value in try engine.list(nextRule, in: response.text, baseURL: response.url) where !value.isEmpty {
                    let next = try url(value, baseURL: response.url)
                    if !visited.contains(next), !pending.contains(next) { pending.append(next) }
                }
            }
        }
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
        shared.catalog(Set(chapters.filter { $0.access != .volume }.map(\.nativeChapterID)), bookID: book.id)
        guard !chapters.isEmpty else { throw ContentFailure.missingChapter }
        return chapters
    }

    func document(_ chapter: ChapterRecord, book: LibraryBookRecord) throws -> ChapterDocument {
        try rejectUnsupported(definition.content, section: "ruleContent", fields: ["webJs", "sourceRegex", "replaceRegex", "payAction"])
        _ = try reference(book)
        guard chapter.bookID == book.id, chapter.access == .readable else { throw ContentFailure.restricted }
        try configure(book: book, chapter: chapter)
        let knownChapters = shared.catalog(bookID: book.id).union([chapter.requestParameters["legado.nextChapterURL"], chapter.requestParameters["legado.previousChapterURL"]].compactMap { $0 })
        var pending = [chapter.nativeChapterID], visited = Set<String>(), paragraphs: [String] = []
        while !pending.isEmpty {
            let address = pending.removeFirst()
            guard visited.insert(address).inserted else { continue }
            guard visited.count <= maximumPages else { throw LegadoRequestError.limit }
            let response = try fetch(address)
            if response.url.absoluteString != chapter.nativeChapterID, knownChapters.contains(response.url.absoluteString) { break }
            let raw = try field(definition.content["content"], in: response.text, baseURL: response.url)
            let extracted = try Self.paragraphs(raw)
            // Split pages commonly repeat a paragraph at their boundary. Keep
            // repetitions elsewhere, where they may be intentional prose.
            var additions = extracted
            if let first = additions.first, paragraphs.last == first { additions.removeFirst() }
            paragraphs += additions
            guard paragraphs.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw LegadoRequestError.limit }
            if let next = definition.content["nextContentUrl"], !next.isEmpty {
                for value in try engine.list(next, in: response.text, baseURL: response.url) where !value.isEmpty {
                    let next = try url(value, baseURL: response.url)
                    if next != chapter.nativeChapterID, knownChapters.contains(next) { continue }
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
            if method == "java.get", args.count == 1, !string(0).contains("://"), !string(0).hasPrefix("/") { return context.variables[string(0)] ?? shared.get(string(0)) }
            var options: [String: Any] = [:]
            if method == "java.post" { options = ["method": "POST", "body": args.indices.contains(1) ? args[1] : ""] }
            if method == "java.head" { options["method"] = "HEAD" }
            let headerIndex = method == "java.post" ? 2 : 1
            if args.indices.contains(headerIndex), !(args[headerIndex] is NSNull) { options["headers"] = args[headerIndex] }
            let response = try http.request(try renderRequest(string(0), baseURL: currentURL), baseURL: currentURL, headers: headers, override: options)
            return method == "java.ajax" ? response.text : response.bridgeValue
        case "java.put":
            let key = string(0), value = string(1); try shared.set(key, value); context.variables[key] = value; return value
        case "java.getString": return try engine.text(string(0), in: scriptContent ?? currentContent, baseURL: currentURL)
        case "java.getStringList": return try engine.list(string(0), in: scriptContent ?? currentContent, baseURL: currentURL)
        case "java.getElements": return try engine.elements(string(0), in: scriptContent ?? currentContent, baseURL: currentURL)
        case "source.getVariable", "book.getVariable", "chapter.getVariable":
            return shared.get(variableScope(method) + (args.isEmpty ? "variable" : string(0)))
        case "source.setVariable", "book.setVariable", "chapter.setVariable":
            let key = args.count == 1 ? "variable" : string(0), value = args.count == 1 ? string(0) : string(1)
            try shared.set(variableScope(method) + key, value); return value
        case "source.getKey", "source.getBookSourceUrl", "source.getUrl": return definition.sourceURL
        case "source.getBookSourceName", "source.getName": return definition.name
        case "book.getName", "book.getTitle", "book.getAuthor", "book.getTocUrl", "book.getBookUrl", "book.getUrl",
             "chapter.getName", "chapter.getTitle", "chapter.getUrl", "chapter.getChapterUrl", "chapter.getChapterIndex", "chapter.getIndex":
            let parts = method.components(separatedBy: "."), kind = parts[0]
            let aliases = ["getName": kind == "chapter" ? "title" : "name", "getTitle": kind == "chapter" ? "title" : "name", "getAuthor": "author", "getTocUrl": "tocUrl", "getBookUrl": "bookUrl", "getUrl": kind == "chapter" ? "url" : "bookUrl", "getChapterUrl": "url", "getChapterIndex": "index", "getIndex": "index"]
            return (bindings[kind] as? [String: Any])?[aliases[parts[1]] ?? ""] ?? NSNull()
        case "source.get", "book.get", "chapter.get": return shared.get(variableScope(method) + string(0))
        case "source.put", "book.put", "chapter.put":
            try shared.set(variableScope(method) + string(0), string(1)); return string(1)
        case "cookie.getCookie":
            let url = try http.absolute(string(0, fallback: currentURL.absoluteString), baseURL: currentURL)
            guard LegadoHTTPExecutor.sameOrigin(url, http.origin) else { throw LegadoRequestError.unsupported("跨来源 Cookie") }
            let value = shared.cookies.header(for: url) ?? ""
            if args.count > 1 {
                return value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(string(1) + "=") }.map { String($0.dropFirst(string(1).count + 1)) } ?? ""
            }
            return value
        case "cookie.setCookie":
            let url = try http.absolute(string(0), baseURL: currentURL)
            guard LegadoHTTPExecutor.sameOrigin(url, http.origin) else { throw LegadoRequestError.unsupported("跨来源 Cookie") }
            shared.cookies.set(string(1), url: url); return true
        case "cookie.removeCookie": shared.cookies.remove(); return true
        case "java.base64Encode": return Data(string(0).utf8).base64EncodedString()
        case "java.base64Decode":
            guard let data = Data(base64Encoded: string(0), options: .ignoreUnknownCharacters) else { throw LegadoRequestError.invalid("Base64") }
            return try LegadoHTTPExecutor.decode(data, charset: args.count > 1 ? string(1) : nil)
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
    private func variableScope(_ method: String) -> String {
        let kind = method.components(separatedBy: ".")[0]
        let book = (bindings["book"] as? [String: Any])?["bookUrl"] as? String ?? ""
        let chapter = (bindings["chapter"] as? [String: Any])?["url"] as? String ?? ""
        return kind + ":" + (kind == "source" ? "" : StableContentID.make(book, kind == "chapter" ? chapter : "")) + ":"
    }
}
