import Foundation

struct NativeExtractionSet: Codable, Equatable, Sendable {
    struct Items: Codable, Equatable, Sendable {
        var rows: ExtractionRule
        var id: ExtractionRule
        var title: ExtractionRule
        var author: ExtractionRule? = nil
    }
    var version = 1
    var search: Items
    var nextPage: ExtractionRule? = nil
    var detailTitle: ExtractionRule
    var detailAuthor: ExtractionRule? = nil
    var detailSummary: ExtractionRule? = nil
    var catalog: Items
    var paragraphs: ExtractionRule
    func validate() throws {
        guard version == 1 else { throw RuleExtractionError.invalid("书源解析配置仅支持 v1。") }
        let rules = [search.rows,search.id,search.title,detailTitle,catalog.rows,catalog.id,catalog.title,paragraphs] + [search.author,nextPage,detailAuthor,detailSummary].compactMap{$0}
        for rule in rules { try rule.validate() }
    }
}

/// Opt-in extract-v1. Imported reader dialects are preserved but never assumed
/// executable; every response is parsed using the selected, versioned rule.
struct ExtractionBookSource: BookSource {
    let sourceID: String
    let name: String
    let host: URL
    let routes: NativeSourceRules
    let rules: NativeExtractionSet
    var transport: any HTTPTransport
    init(source: DemoSource,transport: any HTTPTransport = BoundedAudioHTTPTransport(maximumBytes:2 * 1024 * 1024)) throws {
        sourceID = source.id; name = source.name; host = try ShushanClient.host(source.url); routes = try SourcePackages.rules(source)
        guard let rules = routes.extraction else { throw ContentFailure.invalidResponse }; try rules.validate(); self.rules = rules; self.transport = transport
    }
    private func get(_ path: String,values: [String:String]) async throws -> String {
        var path = path
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        for (key,value) in values { path = path.replacingOccurrences(of:"{" + key + "}",with:value.addingPercentEncoding(withAllowedCharacters:allowed) ?? "") }
        guard !path.contains("{"),let url = URL(string:path,relativeTo:host.appendingPathComponent("/"))?.absoluteURL,url.scheme == host.scheme,url.host == host.host,url.port == host.port,url.user == nil,url.password == nil else { throw ContentFailure.invalidResponse }
        var request = URLRequest(url:url); request.timeoutInterval = 15
        let (data,response) = try await transport.send(request); try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode),response.url?.host == host.host,response.url?.scheme == host.scheme,response.url?.port == host.port,data.count <= 2 * 1024 * 1024,let text = String(data:data,encoding:.utf8) else { throw ContentFailure.invalidResponse }; return text
    }
    private func first(_ rule: ExtractionRule?,_ input: String,required: Bool = false) throws -> String {
        guard let rule else { return "" }; let values = try RuleExtraction.extract(rule,from:input)
        guard values.count <= 1 else { throw RuleExtractionError.invalid("单值字段匹配到多项。") }
        let value = values.first?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard (!required || !value.isEmpty),value.utf8.count <= 100000 else { throw ContentFailure.invalidResponse }; return value
    }
    private func reference(_ book: LibraryBookRecord) throws -> SourceBookReference {
        guard let reference = book.source,reference.sourceID == sourceID,reference.origin == host.absoluteString else { throw ContentFailure.sourceDisabled }; return reference
    }
    func search(query: String,page: Int) async throws -> BookSearchPage {
        guard page > 0,query.count <= 200 else { throw ContentFailure.invalidResponse }
        let input = try await get(routes.search,values:["query":query,"page":String(page)]),rows = try RuleExtraction.extract(rules.search.rows,from:input)
        guard rows.count <= 500 else { throw RuleExtractionError.limit }
        var seen = Set<String>()
        let books = try rows.map { row -> LibraryBookRecord in
            let id = try first(rules.search.id,row,required:true); guard id.utf8.count <= 512,seen.insert(id).inserted else { throw ContentFailure.invalidResponse }
            let reference = SourceBookReference(sourceID:sourceID,nativeBookID:id,provider:name,bookURL:host.absoluteString,origin:host.absoluteString)
            return .init(id:"remote-" + reference.id,title:try first(rules.search.title,row,required:true),author:try first(rules.search.author,row),summary:"",source:reference,addedAt:Date())
        }
        let next = try first(rules.nextPage,input)
        guard next.isEmpty || Int(next).map({$0 > page && $0 < 100000}) == true else { throw ContentFailure.invalidResponse }
        return .init(books:books,nextPage:Int(next))
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord {
        let reference = try reference(book),input = try await get(routes.details,values:["bookID":reference.nativeBookID])
        var result = book; result.title = try first(rules.detailTitle,input,required:true)
        if rules.detailAuthor != nil { result.author = try first(rules.detailAuthor,input) }
        if rules.detailSummary != nil { result.summary = try first(rules.detailSummary,input) }
        return result
    }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] {
        let reference = try reference(book),input = try await get(routes.catalog,values:["bookID":reference.nativeBookID]),rows = try RuleExtraction.extract(rules.catalog.rows,from:input)
        var seen = Set<String>()
        return try rows.enumerated().map { index,row in
            let id = try first(rules.catalog.id,row,required:true); guard id.utf8.count <= 512,seen.insert(id).inserted else { throw ContentFailure.invalidResponse }
            return .init(id:StableContentID.make(book.id,id),bookID:book.id,nativeChapterID:id,title:try first(rules.catalog.title,row,required:true),order:index,access:.readable)
        }
    }
    func document(for chapter: ChapterRecord,book: LibraryBookRecord) async throws -> ChapterDocument {
        let reference = try reference(book)
        guard chapter.bookID == book.id,chapter.access == .readable else { throw ContentFailure.restricted }
        let input = try await get(routes.content,values:["bookID":reference.nativeBookID,"chapterID":chapter.nativeChapterID]),paragraphs = try RuleExtraction.extract(rules.paragraphs,from:input).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        guard !paragraphs.isEmpty else { throw ContentFailure.invalidResponse }; return .init(chapterID:chapter.id,paragraphs:paragraphs)
    }
}
