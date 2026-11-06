import Foundation

struct ShushanCommentContext: Codable, Equatable, Sendable {
    let source: String
    let bookID: String
    let chapterID: String
    let origin: String?
    init?(book: LibraryBookRecord,chapter: ChapterRecord) {
        guard let reference = book.source,reference.sourceID == "shushan",chapter.bookID == book.id else { return nil }
        let provider = reference.provider
        if provider.contains("番茄") { source = "fq" }
        else if provider == "起点" { source = "qd" }
        else if provider.contains("QQ") || provider.contains("企鹅") { source = "qq" }
        else if provider == "晋江" { source = "jj" }
        else { return nil }
        bookID = reference.remoteBookID
        origin = reference.origin
        let parameter = source == "fq" ? "item_id" : source == "jj" ? "chapterId" : "chapterid"
        let query = URLComponents(string:chapter.nativeChapterID)?.queryItems ?? []
        var nativeID = chapter.requestParameters[parameter] ?? query.first(where:{$0.name.lowercased() == parameter.lowercased()})?.value ?? ""
        if nativeID.isEmpty,source == "fq",let range = chapter.nativeChapterID.range(of:"/reader/[0-9]+",options:.regularExpression) { nativeID = String(chapter.nativeChapterID[range]).components(separatedBy:"/").last ?? "" }
        guard Self.numeric(bookID),Self.numeric(nativeID) else { return nil }; chapterID = nativeID
    }
    private static func numeric(_ text: String) -> Bool { !text.isEmpty && text.count <= 64 && text.allSatisfy({$0.isASCII && $0.isNumber}) }
}
struct SourceParagraphCount: Codable, Equatable, Sendable { let nativeID: String; let count: Int; let hot: Bool }
struct SourceComment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let author: String
    let text: String
    let likes: Int
    let createdAt: Date?
}
struct SourceCommentPage: Codable, Equatable, Sendable {
    let comments: [SourceComment]
    let sourceQuote: String?
    let nextCursor: String?
}
struct ShushanCommentsClient: Sendable {
    let credential: ShushanCredential
    var transport: any HTTPTransport = ResilientSourceTransport(base:BoundedAudioHTTPTransport(maximumBytes:2 * 1024 * 1024))
    var cacheScope: String { StableContentID.make(credential.host.absoluteString,credential.apiKey) }
    func page(_ context: ShushanCommentContext,paragraph: String,cursor: String = "0") async throws -> SourceCommentPage {
        try Self.decodePage(await pageData(context,paragraph:paragraph,cursor:cursor),currentCursor:cursor)
    }
    func pageData(_ context: ShushanCommentContext,paragraph: String,cursor: String = "0") async throws -> Data {
        // Only the live-verified Fanqie JSON contract is enabled. Other sites'
        // HTML shells are not silently treated as compatible comment data.
        guard context.source == "fq",context.origin == nil || context.origin == credential.host.absoluteString,
              !paragraph.isEmpty,paragraph.utf8.count <= 128,!cursor.isEmpty,cursor.utf8.count <= 128 else { throw ContentFailure.sourceDisabled }
        let response = try await fetch(path:"idea_comment",query:["api":"1","book_id":context.bookID,"item_id":context.chapterID,"para":paragraph,"cursor":cursor,"count":"20","sort":"1"])
        return response.data
    }
    static func decodePage(_ data: Data,currentCursor: String) throws -> SourceCommentPage {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],root["code"] == nil || root["code"] as? Int == 0,
              let payload = root["data"] as? [String:Any],let list = payload["data_list"] as? [[String:Any]],list.count <= 100 else { throw ContentFailure.invalidResponse }
        var seen = Set<String>()
        let comments = try list.map { item -> SourceComment in
            guard let comment = item["comment"] as? [String:Any],let common = comment["common"] as? [String:Any],
                  let id = text(comment["comment_id"]),!id.isEmpty,id.utf8.count <= 128,seen.insert(id).inserted else { throw ContentFailure.invalidResponse }
            let content = common["content"] as? [String:Any],user = common["user_info"] as? [String:Any],base = user?["base_info"] as? [String:Any],stat = comment["stat"] as? [String:Any]
            let body = text(content?["text"]) ?? "",author = text(base?["user_name"]) ?? "匿名"
            guard body.utf8.count <= 32000,author.utf8.count <= 1024 else { throw ContentFailure.invalidResponse }
            let seconds = Double(text(common["create_timestamp"]) ?? "")
            return .init(id:id,author:author,text:body,likes:max(0,min(100000000,Int(text(stat?["digg_count"]) ?? "") ?? 0)),createdAt:seconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970:$0) : nil })
        }
        let pagination = root["common_list_info"] as? [String:Any]
        let hasMore = pagination?["has_more"] as? Bool ?? ((pagination?["has_more"] as? Int) == 1)
        let next = text(pagination?["cursor"])
        if hasMore { guard let next,!next.isEmpty,next != currentCursor,next.utf8.count <= 128,!comments.isEmpty else { throw ContentFailure.invalidResponse } }
        let quote = text(payload["para_src_content"])
        guard (quote?.utf8.count ?? 0) <= 100000 else { throw ContentFailure.invalidResponse }
        return .init(comments:comments,sourceQuote:quote,nextCursor:hasMore ? next : nil)
    }
    static func sameParagraph(_ quote: String,_ paragraph: String) -> Bool {
        func normalized(_ value: String) -> String { value.replacingOccurrences(of:"<[^>]*>",with:"",options:.regularExpression).replacingOccurrences(of:"&nbsp;",with:" ").filter{!$0.isWhitespace}.precomposedStringWithCanonicalMapping }
        let value = normalized(quote); return !value.isEmpty && value == normalized(paragraph)
    }
    func counts(_ context: ShushanCommentContext) async throws -> [SourceParagraphCount] {
        guard context.origin == nil || context.origin == credential.host.absoluteString else { throw ContentFailure.sourceDisabled }
        let data = try await fetch(path:"para",query:["source":context.source,"book_id":context.bookID,"chapter_id":context.chapterID]).data
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],object["code"] as? Int == 0,let payload = object["data"] as? [String:Any],let rows = payload["list"] as? [[String:Any]],rows.count <= 10000 else { throw ContentFailure.invalidResponse }
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = Self.text(row["paragraph_id"] ?? row["paragraphId"]),id.utf8.count <= 128,seen.insert(id).inserted,
                  let count = Int(Self.text(row["comment_count"] ?? row["textCount"]) ?? ""),count >= 0,count <= 100000000 else { throw ContentFailure.invalidResponse }
            return .init(nativeID:id,count:count,hot:row["hot"] as? Int == 1 || row["is_hot_comment"] as? Int == 1 || row["isHotComment"] as? Bool == true)
        }
    }
    func shell(_ context: ShushanCommentContext,paragraph: String) async throws -> (data: Data,mime: String?) {
        guard context.origin == nil || context.origin == credential.host.absoluteString else { throw ContentFailure.sourceDisabled }
        let path: String,query: [String:String]
        switch context.source {
        case "fq": path = "idea_comment"; query = ["item_id":context.chapterID,"book_id":context.bookID,"para":paragraph,"sessionid":""]
        case "jj": path = "jj_comment"; query = ["bid":context.bookID,"cid":context.chapterID,"para":paragraph]
        case "qq": path = "qq_comment"; query = ["bid":context.bookID,"cid":context.chapterID,"para":paragraph]
        case "qd": path = "qd_comment"; query = ["bid":context.bookID,"cid":context.chapterID,"para":paragraph]
        default: throw ContentFailure.sourceDisabled
        }
        return try await fetch(path:path,query:query)
    }
    func fetch(path: String,query: [String:String]) async throws -> (data: Data,mime: String?) {
        guard !path.contains(".."),!path.hasPrefix("/"),!path.contains("://") else { throw ContentFailure.invalidResponse }
        var url = URLComponents(url:credential.host.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        url.queryItems = query.sorted{$0.key < $1.key}.map{.init(name:$0.key,value:$0.value)}
        var request = URLRequest(url:url.url!); request.timeoutInterval = 15
        request.setValue(credential.authenticationHeader,forHTTPHeaderField:"X-Api-Key"); request.setValue("SHUSAN_READ_2025",forHTTPHeaderField:"X-Novel-Token"); request.setValue("ios",forHTTPHeaderField:"X-Device-Type")
        if let id = credential.deviceID { request.setValue(id,forHTTPHeaderField:"X-Device-Id") }
        let (data,response) = try await transport.send(request); try Task.checkCancellation()
        guard data.count <= 2 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw response.statusCode == 401 || response.statusCode == 403 ? ContentFailure.authenticationRequired : ContentFailure.unavailable }
        return (data,response.mimeType)
    }
    static func text(_ value: Any?) -> String? { if let text = value as? String { return text }; if let number = value as? NSNumber { return number.stringValue }; return nil }
    static func map(_ counts: [SourceParagraphCount],context: ShushanCommentContext,document: ChapterDocument) -> [String:SourceParagraphCount] {
        var nativeIndex = 0,map: [String:String] = [:]
        for paragraph in document.paragraphs {
            let plain = paragraph.text.replacingOccurrences(of:"<[^>]*>",with:"",options:.regularExpression).replacingOccurrences(of:"&nbsp;",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !plain.isEmpty,!ReaderInlineImage.isToken(paragraph.text) else { continue }
            let id = String(nativeIndex + (context.source == "fq" ? 0 : 1)); map[id] = paragraph.id; nativeIndex += 1
        }
        return Dictionary(counts.compactMap { row in guard let id = map[row.nativeID] else { return nil }; return (id,row) },uniquingKeysWith:{ first, _ in first })
    }
}
