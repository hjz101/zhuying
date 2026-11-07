import Foundation

struct NativeSourceRules: Codable, Equatable, Sendable {
    var version = 1
    var search: String
    var details: String
    var catalog: String
    var content: String
    var discover: String? = nil
    var categories: [String]? = nil
    var extraction: NativeExtractionSet? = nil
    func validate() throws {
        guard version == 1 else { throw SourceImportError.message("不支持的原生书源规则版本。") }
        for value in [search,details,catalog,content] + [discover].compactMap({ $0 }) {
            guard !value.isEmpty, value.count <= 2000, !value.contains(".."), !value.contains("\\"), !value.contains("://"), !value.hasPrefix("//") else { throw ContentFailure.invalidResponse }
        }
        guard search.contains("{query}"), details.contains("{bookID}"), catalog.contains("{bookID}"), content.contains("{chapterID}") else { throw ContentFailure.invalidResponse }
        try extraction?.validate()
    }
    static let example = NativeSourceRules(search: "search?q={query}&page={page}", details: "books/{bookID}", catalog: "books/{bookID}/chapters", content: "books/{bookID}/chapters/{chapterID}")
}

enum SourcePackages {
    /// Legacy readers also use bookSourceUrl as an opaque source identifier.
    /// Only runnable adapters require an HTTPS origin; retaining a legacy ID
    /// must not turn it into a network origin or execute its imported scripts.
    private static func identity(_ row: [String: Any]) -> String? {
        guard let value = (row["bookSourceUrl"] ?? row["url"]) as? String else { return nil }
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = try? ShushanClient.host(address) { return host.absoluteString }
        guard row["adapter"] == nil,
              ["searchUrl", "ruleSearch", "ruleToc", "ruleContent"].contains(where: { row[$0] != nil }),
              !address.isEmpty, address.utf8.count <= 2048,
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return address
    }
    static func hasValidIdentity(_ source: DemoSource) -> Bool {
        if (try? ShushanClient.host(source.url)) != nil { return true }
        guard source.id != "shushan", let data = source.configuration,
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return identity(row) == source.url
    }
    static func accountTitle(_ source: DemoSource,isDemo: Bool) -> String {
        if isDemo || source.id == "shushan" { return source.loginStatus.title }
        if (try? legadoDefinition(source)) != nil { return "阅读 3.0" }
        return (try? rules(source)) != nil ? "公开接口" : "规则未支持运行"
    }
    static func legadoDefinition(_ source: DemoSource) throws -> LegadoSourceDefinition {
        guard source.kind == .novel else { throw LegadoCompatibilityError.unsupported("漫画或音频书源") }
        return try LegadoSourceDefinition.decode(source)
    }
    static func isRunnable(_ source: DemoSource) -> Bool {
        source.id == "shushan" || (try? rules(source)) != nil || (try? legadoDefinition(source)) != nil
    }
    static func executionDetail(_ source: DemoSource, isDemo: Bool = false) -> String {
        if !isDemo, (try? legadoDefinition(source)) != nil { return "阅读 3.0 · 基础兼容 · 待实测" }
        return source.detail
    }
    static func rules(_ source: DemoSource) throws -> NativeSourceRules {
        guard let data = source.configuration, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["json-v1","extract-v1"].contains(object["adapter"] as? String ?? ""), let value = object["endpoints"] else {
            throw SourceImportError.message("该配置已保存，但规则格式尚不支持运行；当前支持书山、原生 JSON v1 和 extract-v1。")
        }
        let rules = try JSONDecoder().decode(NativeSourceRules.self, from: JSONSerialization.data(withJSONObject: value))
        guard object["adapter"] as? String != "extract-v1" || rules.extraction != nil else { throw ContentFailure.invalidResponse }
        try rules.validate(); return rules
    }
    static func export(_ sources: [DemoSource]) throws -> Data {
        let rows = try sources.map { source -> [String: Any] in
            var object = try source.configuration.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String:Any] } ?? [:]
            object["bookSourceName"] = source.name; object["bookSourceUrl"] = source.url
            object["bookSourceGroup"] = source.group; object["enabled"] = source.enabled
            if source.id == "shushan" { object["adapter"] = "shushan" }
            return scrub(object) as? [String:Any] ?? [:]
        }
        return try JSONSerialization.data(withJSONObject: ["format":"zhuying-sources", "version":1, "sources":rows], options: [.sortedKeys,.prettyPrinted])
    }
    static func parse(_ data: Data, existing: [DemoSource]) throws -> SourceImportPreview {
        guard data.count <= 5 * 1024 * 1024 else { throw SourceImportError.message("书源文件超过 5 MB。") }
        let json = try JSONSerialization.jsonObject(with: data)
        let rows: [[String:Any]]
        if let envelope = json as? [String:Any], envelope["format"] != nil {
            guard BrandCompatibility.accepts(envelope["format"] as? String, current:"zhuying-sources"), envelope["version"] as? Int == 1, let array = envelope["sources"] as? [[String:Any]] else { throw SourceImportError.message("不支持的书源包版本。") }
            rows = array
        } else if let array = json as? [[String:Any]] { rows = array }
        else if let object = json as? [String:Any] { rows = [object] }
        else { throw ContentFailure.invalidResponse }
        guard rows.count <= 1000 else { throw SourceImportError.message("一次最多导入 1000 个书源。") }
        var result: [DemoSource] = [], invalid = 0, duplicates = 0
        var seen = Set(existing.map { (try? ShushanClient.host($0.url).absoluteString) ?? $0.url.trimmingCharacters(in: .whitespacesAndNewlines) })
        for row in rows {
            guard let name = (row["bookSourceName"] ?? row["name"]) as? String,
                  let address = identity(row), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else { invalid += 1; continue }
            guard seen.insert(address).inserted else { duplicates += 1; continue }
            let config = try JSONSerialization.data(withJSONObject: scrub(row), options: .sortedKeys)
            var source = DemoSource(id: row["adapter"] as? String == "shushan" && !existing.contains(where: { $0.id == "shushan" }) && !result.contains(where: { $0.id == "shushan" }) ? "shushan" : UUID().uuidString,
                                    name: name.trimmingCharacters(in: .whitespacesAndNewlines), group: row["bookSourceGroup"] as? String ?? "导入书源", enabled: row["enabled"] as? Bool ?? true, detail: "已导入 · 规则未支持运行", url: address,
                                    kind: (row["bookSourceType"] as? Int) == 2 ? .comic : (row["bookSourceType"] as? Int) == 1 ? .audio : .novel)
            source.configuration = config
            if source.id == "shushan" { source.detail = "固定原生适配器 · 需登录" }
            else if let rules = try? rules(source) { source.detail = rules.extraction == nil ? "原生 JSON v1 · 待实测" : "原生解析规则 v1 · 待实测" }
            else if (try? legadoDefinition(source)) != nil { source.detail = executionDetail(source) }
            result.append(source)
        }
        return .init(sources: result, duplicates: duplicates, invalid: invalid)
    }
    private static func scrub(_ value: Any) -> Any {
        if let object = value as? [String:Any] {
            var cleaned = object.filter { key, _ in
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                return !["password","apikey","xapikey","authorization","cookie","cookies","token","accesstoken","refreshtoken","secret","clientsecret"].contains(normalized)
            }.mapValues(scrub)
            // Static request metadata is part of the rule dialect. Strip
            // credentials inside it while retaining User-Agent/Accept, etc.
            for key in ["header", "headers"] {
                if let text = cleaned[key] as? String,
                   let bytes = text.data(using: .utf8),
                   let headers = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: scrub(headers), options: .sortedKeys) {
                    cleaned[key] = String(decoding: data, as: UTF8.self)
                }
            }
            return cleaned
        }
        if let array = value as? [Any] { return array.map(scrub) }
        return value
    }
}

/// Versioned, declarative JSON routes. No imported scripts or parser expressions
/// run here; unsupported legacy rules remain editable and explicitly non-runnable.
protocol DiscoveryBookSource: BookSource {
    var supportsDiscovery: Bool { get }
    func discover(category: String,page: Int) async throws -> BookSearchPage
    func discoveryCategories() async throws -> [SourceDiscoveryCategory]
    func applyDiscoveryFilter(category: SourceDiscoveryCategory, value: String) async throws -> SourceDiscoveryFilterResult
}
extension DiscoveryBookSource {
    func applyDiscoveryFilter(category: SourceDiscoveryCategory, value: String) async throws -> SourceDiscoveryFilterResult {
        throw SourceImportError.message("此书源暂不支持发现筛选操作。")
    }
    func discoveryCategories() async throws -> [SourceDiscoveryCategory] { [.init(title: "全部", request: "全部")] }
}
struct ConfigurableBookSource: DiscoveryBookSource {
    struct RemoteBook: Codable { let id: String; let title: String; let author: String; var summary: String?; var coverURL: String? }
    struct SearchResponse: Codable { let books: [RemoteBook]; let nextPage: Int? }
    struct RemoteChapter: Codable { let id: String; let title: String; var access: ChapterRecord.Access? }
    struct BodyResponse: Codable { let chapterID: String; let paragraphs: [String] }
    let sourceID: String
    let host: URL
    let name: String
    let rules: NativeSourceRules
    let transport: any HTTPTransport
    var supportsDiscovery: Bool { rules.discover != nil }
    func discoveryCategories() async throws -> [SourceDiscoveryCategory] {
        (rules.categories?.isEmpty == false ? rules.categories! : ["全部"]).map { .init(title: $0, request: $0) }
    }
    init(source: DemoSource, transport: any HTTPTransport = SourceHTTPTransport()) throws {
        sourceID = source.id; host = try ShushanClient.host(source.url); name = source.name
        rules = try SourcePackages.rules(source); self.transport = transport
    }
    private func get<T: Decodable>(_ path: String, values: [String:String] = [:], as: T.Type) async throws -> T {
        var path = path
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for (key, value) in values { path = path.replacingOccurrences(of: "{" + key + "}", with: value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        guard !path.contains("{"), let url = URL(string: path, relativeTo: host.appendingPathComponent("/"))?.absoluteURL,
              url.scheme == host.scheme, url.host == host.host, url.port == host.port, url.user == nil, url.password == nil else { throw ContentFailure.invalidResponse }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await transport.send(request); try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode), data.count <= 4 * 1024 * 1024 else {
            if [401,403].contains(response.statusCode) { throw ContentFailure.authenticationRequired }; throw ContentFailure.unavailable
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ContentFailure.invalidResponse }
    }
    private func metadata(_ value: RemoteBook) throws -> LibraryBookRecord {
        guard !value.id.isEmpty, !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContentFailure.invalidResponse }
        let reference = SourceBookReference(sourceID: sourceID, nativeBookID: value.id, provider: name, bookURL: host.absoluteString, origin: host.absoluteString)
        return .init(id: "remote-" + reference.id, title: value.title, author: value.author, summary: value.summary ?? "", coverURL: value.coverURL, source: reference, addedAt: Date())
    }
    func search(query: String, page: Int) async throws -> BookSearchPage {
        let result = try await get(rules.search, values: ["query":query,"page":String(page)], as: SearchResponse.self)
        guard result.books.count <= 500, result.nextPage.map({ $0 > page }) ?? true else { throw ContentFailure.invalidResponse }
        return .init(books: try result.books.map(metadata), nextPage: result.nextPage)
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord {
        guard let source = book.source, source.sourceID == sourceID, source.origin == host.absoluteString else { throw ContentFailure.sourceDisabled }
        let result = try metadata(await get(rules.details, values: ["bookID":source.nativeBookID], as: RemoteBook.self))
        guard result.id == book.id else { throw ContentFailure.invalidResponse }; return result
    }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] {
        guard let source = book.source, source.sourceID == sourceID, source.origin == host.absoluteString else { throw ContentFailure.sourceDisabled }
        let values = try await get(rules.catalog, values: ["bookID":source.nativeBookID], as: [RemoteChapter].self)
        guard values.count <= 50_000, Set(values.map(\.id)).count == values.count else { throw ContentFailure.invalidResponse }
        return values.enumerated().map { index, chapter in
            .init(id: StableContentID.make(book.id, chapter.id), bookID: book.id, nativeChapterID: chapter.id, title: chapter.title, order: index, access: chapter.access ?? .readable)
        }
    }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        guard chapter.access == .readable, chapter.bookID == book.id, let source = book.source else { throw ContentFailure.restricted }
        guard source.sourceID == sourceID, source.origin == host.absoluteString else { throw ContentFailure.sourceDisabled }
        let result = try await get(rules.content, values: ["bookID":source.nativeBookID,"chapterID":chapter.nativeChapterID], as: BodyResponse.self)
        guard result.chapterID == chapter.nativeChapterID, !result.paragraphs.isEmpty,
              result.paragraphs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ContentFailure.invalidResponse }
        return .init(chapterID: chapter.id, paragraphs: result.paragraphs)
    }
    func discover(category: String, page: Int) async throws -> BookSearchPage {
        guard let path = rules.discover else { throw ContentFailure.sourceDisabled }
        let response = try await get(path, values: ["category":category,"page":String(page)], as: SearchResponse.self)
        return .init(books: try response.books.map(metadata), nextPage: response.nextPage)
    }
}

struct SourceSearchReport: Equatable, Sendable { let sourceID: String; let status: String; let count: Int }

struct BookCandidateGroup: Identifiable {
    let id: String
    let records: [LibraryBookRecord]
    static func groups(_ books: [LibraryBookRecord]) -> [BookCandidateGroup] {
        var order: [String] = [], buckets: [String:[LibraryBookRecord]] = [:]
        for book in books {
            let title = book.title.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
            let author = book.author.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
            let key = title.isEmpty || author.isEmpty || author == "未知" ? book.id : StableContentID.make(title,author)
            if buckets[key] == nil { order.append(key) }; buckets[key,default:[]].append(book)
        }
        return order.map { .init(id:$0,records:buckets[$0]!) }
    }
}

struct DiscoverySourceRequest: BookSource {
    let provider: any DiscoveryBookSource
    var sourceID: String { provider.sourceID }
    func search(query: String,page: Int) async throws -> BookSearchPage { try await provider.discover(category:query,page:page) }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { try await provider.details(for:book) }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] { try await provider.chapters(for:book) }
    func document(for chapter: ChapterRecord,book: LibraryBookRecord) async throws -> ChapterDocument { try await provider.document(for:chapter,book:book) }
}

actor MultiSourceSearch {
    private var cursors: [String:Int] = [:]
    private var query = ""
    private var revision = UUID()
    func search(_ text: String, page: Int, sources: [any BookSource], limit: Int = 3) async throws -> BookSearchPage {
        if page == 1 { query = text; cursors = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID,1) }) }
        guard query == text else { throw CancellationError() }
        let current = UUID(); revision = current
        let requests = sources.compactMap { source in cursors[source.sourceID].map { (source,$0) } }
        var results: [String:BookSearchPage] = [:], reports: [SourceSearchReport] = []
        await withTaskGroup(of: (String,BookSearchPage?,String).self) { group in
            var next = 0
            func enqueue() {
                guard next < requests.count else { return }
                let (source, page) = requests[next]; next += 1
                group.addTask {
                    do { return (source.sourceID, try await source.search(query: text, page: page), "成功") }
                    catch is CancellationError { return (source.sourceID,nil,"已取消") }
                    catch { return (source.sourceID,nil,error as? ContentFailure == .timedOut ? "超时" : "失败") }
                }
            }
            for _ in 0..<min(max(1,limit),requests.count) { enqueue() }
            while let (id,result,status) = await group.next() {
                results[id] = result; reports.append(.init(sourceID: id, status: status, count: result?.books.count ?? 0))
                if Task.isCancelled { group.cancelAll() } else { enqueue() }
            }
        }
        try Task.checkCancellation(); guard current == revision else { throw CancellationError() }
        for (id,result) in results { cursors[id] = result.nextPage }
        // Failed sources remain retryable on the next request; an empty successful
        // page is exhausted according to its adapter cursor.
        let books = sources.flatMap { results[$0.sourceID]?.books ?? [] }
        if results.isEmpty && !requests.isEmpty { throw ContentFailure.unavailable }
        let messages = sources.compactMap { results[$0.sourceID]?.feedback }.filter { !$0.isEmpty }
        return .init(books: books, nextPage: cursors.isEmpty ? nil : page + 1, hasPartialFailures: reports.contains { $0.status != "成功" }, sourceReports: reports, feedback: messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }
}
