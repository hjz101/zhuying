import Foundation

/// A fixed native adapter for the documented v5.61 request shapes. It does not
/// evaluate imported JavaScript, nor claim compatibility with arbitrary rules.
struct ShushanBookSource: BookSource {
    // The reference file is v5.61; its content API protocol field is "12".
    static let contentRequestVersion = "12"
    let sourceID = "shushan"
    let credential: ShushanCredential
    let transport: any HTTPTransport
    var supportsPagination = false
    init(credential: ShushanCredential, transport: any HTTPTransport = SourceHTTPTransport(), supportsPagination: Bool = false) {
        self.credential = credential; self.transport = transport; self.supportsPagination = supportsPagination
    }

    func search(query: String, page: Int) async throws -> BookSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .init(books: [], nextPage: nil) }
        guard page > 0 else { throw ContentFailure.invalidResponse }
        let response = try await request("search", query: ["login": "search", "key": query, "page": String(page)], allowPartialResults: true)
        guard let data = response["data"] as? [[String: Any]] else { throw ContentFailure.invalidResponse }
        var seen = Set<String>()
        let novels = data.filter { Self.text($0["tab"]).map { $0 == "novel" } ?? true }
        let books = try novels.map { try book(from: $0) }.filter { seen.insert($0.id).inserted }
        let hasMore = response["has_more"] as? Bool ?? (supportsPagination && !data.isEmpty)
        return .init(books: books, nextPage: hasMore ? page + 1 : nil,
                     hasPartialFailures: !(Self.text(response["error"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord {
        guard let source = book.source, source.sourceID == sourceID else { throw ContentFailure.invalidResponse }
        let response = try await request("details", body: ["source": source.provider, "url": source.bookURL,
                                                          "cover": book.coverURL ?? "", "desc": book.summary, "name": book.title, "tab": "novel"])
        guard let data = response["data"] as? [String: Any] else { throw ContentFailure.invalidResponse }
        var result = book
        result.title = Self.text(data["title"]) ?? book.title
        result.author = Self.text(data["author"]) ?? book.author
        result.summary = Self.text(data["desc"]) ?? book.summary
        result.coverURL = Self.text(data["cover"]) ?? book.coverURL
        result.source?.provider = Self.text(data["source"]) ?? source.provider
        result.source?.bookURL = Self.text(data["book_url"]) ?? source.bookURL
        result.source?.remoteBookID = Self.text(data["bookid"]) ?? source.remoteBookID
        if let tab = Self.text(data["tab"]), tab != "novel" { throw ContentFailure.invalidResponse }
        return result
    }

    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] {
        guard let source = book.source, source.sourceID == sourceID else { throw ContentFailure.invalidResponse }
        let response = try await request("catalog", body: ["source": source.provider, "url": source.bookURL,
                                                          "name": book.title, "bookid": source.remoteBookID, "tab": "novel"])
        guard let data = response["data"] as? [[String: Any]] else { throw ContentFailure.invalidResponse }
        var seen = Set<String>()
        return try data.enumerated().map { order, row in
            guard let title = Self.text(row["title"]) ?? Self.text(row["name"]), !title.isEmpty else { throw ContentFailure.invalidResponse }
            let isVolume = row["isVolume"] as? Bool == true
            let cid = Self.text(row["cid"]) ?? ""
            let address = Self.text(row["url"]) ?? ""
            let nativeID: String
            if isVolume { nativeID = "volume-\(order)-\(title)" }
            else if !address.isEmpty { nativeID = address }
            else if let position = Int(cid), (0...data.count).contains(position) {
                // Real catalogs use cid as a request position. A unique title is
                // a safer fallback identity: insertion preserves it; renaming
                // becomes missing history instead of silently opening another chapter.
                nativeID = "title-v1-" + StableContentID.make(title)
            } else { nativeID = cid }
            guard !nativeID.isEmpty else { throw ContentFailure.invalidResponse }
            let id = StableContentID.make(book.id, nativeID)
            guard seen.insert(id).inserted else { throw ContentFailure.invalidResponse }
            var parameters = ["cid": cid.isEmpty ? nativeID : cid, "source": source.provider, "version": Self.contentRequestVersion]
            let queryItems = URLComponents(string: address)?.queryItems ?? []
            func value(_ name: String) -> String? { queryItems.first { $0.name == name }?.value }
            if ["番茄小说", "番茄短剧", "番茄听书", "番茄畅听"].contains(source.provider) {
                parameters["book_id"] = source.remoteBookID
                parameters["item_id"] = value("item_id")
            } else { parameters["url"] = source.bookURL }
            if ["企鹅看书", "QQ阅读", "起点"].contains(source.provider) {
                parameters["bookid"] = source.remoteBookID
                parameters["chapterid"] = value("chapterid")
            }
            if source.provider == "晋江" {
                parameters["novelId"] = source.remoteBookID
                parameters["chapterId"] = value("chapterId")
            }
            if source.provider == "七猫小说" { parameters["qm_url"] = address }
            let restricted = row["isPay"] as? Bool == true || row["isVip"] as? Bool == true
            return ChapterRecord(id: id, bookID: book.id, nativeChapterID: nativeID, title: title, order: order,
                                 access: isVolume ? .volume : restricted ? .restricted : .readable, requestParameters: parameters)
        }
    }

    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        guard chapter.bookID == book.id, book.source?.sourceID == sourceID else { throw ContentFailure.invalidResponse }
        guard chapter.access == .readable else { throw ContentFailure.restricted }
        let response = try await request("content", body: chapter.requestParameters)
        guard let data = response["data"] as? [String: Any], var text = data["content"] as? String else { throw ContentFailure.invalidResponse }
        if let tab = Self.text(data["tab"]), tab != "novel" { throw ContentFailure.invalidResponse }
        if let encoding = data["encoding"] as? String, encoding != "utf8" && encoding != "base64" { throw ContentFailure.invalidResponse }
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let looksEncoded = compact.count >= 64 && compact.count.isMultiple(of: 4) && compact.unicodeScalars.allSatisfy { alphabet.contains($0) }
        if data["encoding"] as? String == "base64" || looksEncoded {
            guard let bytes = Data(base64Encoded: compact), let decoded = String(data: bytes, encoding: .utf8),
                  !decoded.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else { throw ContentFailure.invalidResponse }
            text = decoded
        }
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { throw ContentFailure.invalidResponse }
        return .init(chapterID: chapter.id, paragraphs: paragraphs)
    }

    private func book(from row: [String: Any]) throws -> LibraryBookRecord {
        guard let provider = Self.text(row["source"]), let url = Self.text(row["book_url"]),
              let title = Self.text(row["title"]), !title.isEmpty, !provider.isEmpty, !url.isEmpty else { throw ContentFailure.invalidResponse }
        let nativeID = Self.text(row["bookid"]) ?? url
        let reference = SourceBookReference(sourceID: sourceID, nativeBookID: StableContentID.make(provider, nativeID),
                                            provider: provider, bookURL: url, remoteBookID: Self.text(row["bookid"]) ?? "")
        return .init(id: "remote-" + reference.id, title: title, author: Self.text(row["author"]) ?? "",
                     summary: Self.text(row["desc"]) ?? "", coverURL: Self.text(row["cover"]), source: reference, addedAt: Date())
    }

    private func request(_ path: String, query: [String: String] = [:], body: [String: String]? = nil, allowPartialResults: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        let host = try ShushanClient.host(credential.host.absoluteString)
        var components = URLComponents(url: host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(credential.authenticationHeader, forHTTPHeaderField: "X-Api-Key")
        request.setValue("SHUSAN_READ_2025", forHTTPHeaderField: "X-Novel-Token")
        request.setValue("ios", forHTTPHeaderField: "X-Device-Type")
        if let deviceID = credential.deviceID { request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        if response.statusCode == 401 || response.statusCode == 403 { throw ContentFailure.authenticationRequired }
        guard (200..<300).contains(response.statusCode) else { throw ContentFailure.unavailable }
        guard data.count <= 20 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContentFailure.invalidResponse }
        if let error = object["error"] as? String, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if error.contains("登录") || error.contains("凭证") || error.localizedCaseInsensitiveContains("unauthorized") { throw ContentFailure.authenticationRequired }
            guard allowPartialResults, let partial = object["data"] as? [[String: Any]], !partial.isEmpty else { throw ContentFailure.unavailable }
        }
        if let code = object["code"] as? Int, code != 200 {
            throw code == 401 || code == 403 ? ContentFailure.authenticationRequired : ContentFailure.unavailable
        }
        if let status = object["status"] as? Int, status != 200 {
            // This service uses HTTP 201 plus a short content message for
            // device/authentication failures. It must never become prose.
            let message = (object["data"] as? [String: Any])?["content"] as? String ?? ""
            if status == 401 || status == 403 || message.contains("登录") || message.contains("凭证") { throw ContentFailure.authenticationRequired }
            if message.contains("会员") || message.contains("付费") { throw ContentFailure.restricted }
            throw ContentFailure.unavailable
        }
        return object
    }
    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
