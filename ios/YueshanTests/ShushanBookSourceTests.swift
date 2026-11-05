import XCTest
@testable import Yueshan

private actor ShushanFixtureTransport: HTTPTransport {
    let responses: [String: Data]
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(responses: [String: Data], status: Int = 200) { self.responses = responses; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = responses[request.url!.path] ?? Data("{}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class ShushanBookSourceTests: XCTestCase {
    private let searchBook: [String: Any] = ["source": "测试来源", "book_url": "https://books.example.test/123", "title": "测试书", "author": "测试作者", "bookid": "123"]
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func credential() throws -> ShushanCredential {
        .init(host: try ShushanClient.host(ShushanClient.defaultHost), apiKey: "fixture-only-key", nickname: "fixture")
    }
    private func setup(content: [String: Any] = ["content": "第一段真实内容。\n第二段真实内容。"], catalog: [[String: Any]]? = nil) throws -> (ShushanBookSource, ShushanFixtureTransport) {
        let transport = ShushanFixtureTransport(responses: [
            "/search": try json(["data": [searchBook, searchBook]]),
            "/details": try json(["data": ["title": "测试书", "author": "测试作者", "source": "测试来源", "book_url": "https://books.example.test/123", "bookid": "123", "desc": "真实简介", "tab": "novel"]]),
            "/catalog": try json(["data": catalog ?? [["name": "第一卷", "isVolume": true], ["name": "第一章", "cid": "c1", "url": "https://books.example.test/123/c1"], ["name": "受限章节", "cid": "c2", "isPay": true]]]),
            "/content": try json(["data": content])
        ])
        return (ShushanBookSource(credential: try credential(), transport: transport), transport)
    }
    func testNativeFourStepContractKeepsStableIDsAndSeparatesVolumesAndRestrictedChapters() async throws {
        let (source, transport) = try setup()
        let results = try await source.search(query: " 测试书 ", page: 1)
        XCTAssertEqual(results.books.count, 1, "Repeated source edition must be deduplicated")
        XCTAssertNil(results.nextPage, "Do not claim pagination before verifying source support")
        let book = try XCTUnwrap(results.books.first)
        let details = try await source.details(for: book)
        XCTAssertEqual(details.id, book.id)
        XCTAssertEqual(details.summary, "真实简介")
        let chapters = try await source.chapters(for: details)
        XCTAssertEqual(chapters.map(\.access), [.volume, .readable, .restricted])
        let document = try await source.document(for: chapters[1], book: details)
        XCTAssertEqual(document.chapterID, chapters[1].id)
        XCTAssertEqual(document.paragraphs.map(\.text), ["第一段真实内容。", "第二段真实内容。"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/search", "/details", "/catalog", "/content"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), try credential().authenticationHeader)
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-only-key"))
        }
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "key" }?.value, "测试书")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: String])
        XCTAssertEqual(body["cid"], "c1")
        XCTAssertEqual(body["source"], "测试来源")
        XCTAssertEqual(body["version"], "12")
    }
    func testEmptySearchDoesNotRequestAndVerifiedPaginationHasExplicitNextPage() async throws {
        let (source, transport) = try setup()
        let empty = try await source.search(query: "  ", page: 1)
        XCTAssertTrue(empty.books.isEmpty)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        let paged = ShushanBookSource(credential: try credential(), transport: transport, supportsPagination: true)
        let page = try await paged.search(query: "测试", page: 1)
        XCTAssertEqual(page.nextPage, 2)
        let again = try await source.search(query: "测试作者", page: 1)
        XCTAssertEqual(page.books.map(\.id), again.books.map(\.id))
    }
    func testHTTPAndBusinessAuthenticationErrorsNeverBecomeEmptySuccess() async throws {
        for status in [200, 401] {
            let transport = ShushanFixtureTransport(responses: ["/search": try json(["error": "访问被拒绝，缺少登录凭证"])], status: status)
            let source = ShushanBookSource(credential: try credential(), transport: transport)
            do { _ = try await source.search(query: "test", page: 1); XCTFail("Must report authentication failure") }
            catch { XCTAssertEqual(error as? ContentFailure, .authenticationRequired) }
        }
    }
    func testEmptyErrorFieldIsSuccessAndCatalogAcceptsReferenceTitleField() async throws {
        let transport = ShushanFixtureTransport(responses: [
            "/search": try json(["data": [searchBook], "error": ""]),
            "/catalog": try json(["data": [["title": "第一章 实际标题字段", "cid": "c1"]], "error": "  "])
        ])
        let source = ShushanBookSource(credential: try credential(), transport: transport)
        let page = try await source.search(query: "测试", page: 1)
        let book = try XCTUnwrap(page.books.first)
        let catalog = try await source.chapters(for: book)
        XCTAssertEqual(catalog.map(\.title), ["第一章 实际标题字段"])
    }
    func testAggregatePartialFailureKeepsUsableResultsButAuthenticationAndEmptyFailuresStillFail() async throws {
        for error in ["部分来源超时", "缺少登录凭证", "Unauthorized"] {
            let transport = ShushanFixtureTransport(responses: ["/search": try json(["data": [searchBook], "error": error])])
            let source = ShushanBookSource(credential: try credential(), transport: transport)
            do {
                let page = try await source.search(query: "测试", page: 1)
                XCTAssertEqual(error, "部分来源超时")
                XCTAssertEqual(page.books.count, 1)
                XCTAssertTrue(page.hasPartialFailures)
            } catch {
                XCTAssertNotEqual(error as? ContentFailure, .unavailable)
                XCTAssertEqual(error as? ContentFailure, .authenticationRequired)
            }
        }
        let transport = ShushanFixtureTransport(responses: ["/search": try json(["data": [], "error": "来源超时"])])
        do { _ = try await ShushanBookSource(credential: try credential(), transport: transport).search(query: "测试", page: 1); XCTFail("Empty failure must not become an empty success") }
        catch { XCTAssertEqual(error as? ContentFailure, .unavailable) }
    }
    func testDeviceHeaderIsOnlyInHeaderAndBusiness201CannotBecomeReadableProse() async throws {
        var account = try credential(); account.deviceID = "fixture-installation-id"
        for (message, expected) in [("缺少设备标识", ContentFailure.unavailable), ("请先登录", .authenticationRequired), ("需要会员", .restricted)] {
            let transport = ShushanFixtureTransport(responses: ["/content": try json(["status": 201, "data": ["content": message]])], status: 201)
            let source = ShushanBookSource(credential: account, transport: transport)
            let book = LibraryBookRecord(id: "book", title: "书", author: "", summary: "", source: .init(sourceID: "shushan", nativeBookID: "id", provider: "来源", bookURL: "url"), addedAt: Date())
            let chapter = ChapterRecord(id: "chapter", bookID: book.id, nativeChapterID: "1", title: "一", order: 0, access: .readable)
            do { _ = try await source.document(for: chapter, book: book); XCTFail("Business failure must never become content") }
            catch { XCTAssertEqual(error as? ContentFailure, expected) }
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), account.deviceID)
            XCTAssertFalse(request.url!.absoluteString.contains(account.deviceID!))
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(account.deviceID!))
        }
    }
    func testTextSearchExcludesComicAudioVideoAndDownloadEntriesBeforeBuildingBookIdentity() async throws {
        let rows = ["novel", "comic", "audio", "video", "download"].map { tab in searchBook.merging(["tab": tab, "book_url": "https://books.example.test/\(tab)"]) { _, new in new } }
        let transport = ShushanFixtureTransport(responses: ["/search": try json(["data": rows])])
        let result = try await ShushanBookSource(credential: try credential(), transport: transport).search(query: "测试", page: 1)
        XCTAssertEqual(result.books.count, 1)
        XCTAssertEqual(result.books.first?.source?.bookURL, "https://books.example.test/novel")
    }
    func testHTTP503IsServiceFailureEvenWhenBodyLooksLikeAChapter() async throws {
        let transport = ShushanFixtureTransport(responses: ["/search": try json(["data": [searchBook]])], status: 503)
        do { _ = try await ShushanBookSource(credential: try credential(), transport: transport).search(query: "测试", page: 1); XCTFail("Service failure") }
        catch { XCTAssertEqual(error as? ContentFailure, .unavailable) }
    }
    func testPositionalCatalogCIDIsOnlyARequestParameterAndInsertionPreservesChapterIdentity() async throws {
        let (first, _) = try setup(catalog: [["title": "旧章甲", "cid": 0], ["title": "旧章乙", "cid": 1]])
        let (updated, _) = try setup(catalog: [["title": "新插入", "cid": 0], ["title": "旧章甲", "cid": 1], ["title": "旧章乙", "cid": 2]])
        let results = try await first.search(query: "测试", page: 1)
        let book = try XCTUnwrap(results.books.first)
        let old = try await first.chapters(for: book), new = try await updated.chapters(for: book)
        XCTAssertEqual(old.map(\.id), Array(new.dropFirst()).map(\.id))
        XCTAssertEqual(old[0].requestParameters["cid"], "0")
        XCTAssertEqual(new[1].requestParameters["cid"], "1")
        XCTAssertNotEqual(old[0].nativeChapterID, "0")
        let (ambiguous, _) = try setup(catalog: [["title": "重名", "cid": 0], ["title": "重名", "cid": 1]])
        do { _ = try await ambiguous.chapters(for: book); XCTFail("Ambiguous title fallback must fail") }
        catch { XCTAssertEqual(error as? ContentFailure, .invalidResponse) }
    }
    func testNonNovelContentCannotBecomeProseDespiteSuccessfulHTTPAndLongText() async throws {
        for tab in ["comic", "audio", "video"] {
            let (source, _) = try setup(content: ["content": String(repeating: "https://example.test/media ", count: 20), "tab": tab])
            let result = try await source.search(query: "测试", page: 1)
            let book = try XCTUnwrap(result.books.first)
            let chapter = try await source.chapters(for: book)[1]
            do { _ = try await source.document(for: chapter, book: book); XCTFail("Unsupported media cannot become a text chapter") }
            catch { XCTAssertEqual(error as? ContentFailure, .invalidResponse) }
        }
    }
    func testRestrictedChapterNeverSendsContentRequest() async throws {
        let (source, transport) = try setup()
        let page = try await source.search(query: "测试", page: 1)
        let book = try XCTUnwrap(page.books.first)
        let chapters = try await source.chapters(for: book)
        do { _ = try await source.document(for: chapters[2], book: book); XCTFail("Restricted chapter") }
        catch { XCTAssertEqual(error as? ContentFailure, .restricted) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/content" })
    }
    func testDuplicateChapterIdentityFailsWithoutGuessingAnIndex() async throws {
        let (source, _) = try setup(catalog: [["name": "一", "cid": "same"], ["name": "二", "cid": "same"]])
        let page = try await source.search(query: "测试", page: 1)
        let book = try XCTUnwrap(page.books.first)
        do { _ = try await source.chapters(for: book); XCTFail("Duplicate chapter identity") }
        catch { XCTAssertEqual(error as? ContentFailure, .invalidResponse) }
    }
    func testBase64TextDecodesButUnknownEncodingDoesNotBecomeGibberish() async throws {
        let text = "正确解码的文字。\n保留段落结构。"
        let (source, _) = try setup(content: ["content": Data(text.utf8).base64EncodedString(), "encoding": "base64"])
        let page = try await source.search(query: "测试", page: 1)
        let book = try XCTUnwrap(page.books.first)
        let chapter = try await source.chapters(for: book)[1]
        let decoded = try await source.document(for: chapter, book: book)
        XCTAssertEqual(decoded.paragraphs.map(\.text), text.components(separatedBy: "\n"))
        let (unsupported, _) = try setup(content: ["content": "opaque", "encoding": "encrypted-unknown"])
        do { _ = try await unsupported.document(for: chapter, book: book); XCTFail("Unsupported encoding") }
        catch { XCTAssertEqual(error as? ContentFailure, .invalidResponse) }
    }
    func testCancelledSearchCannotReturnOrSendRequest() async throws {
        let (source, transport) = try setup()
        let task = Task { try await source.search(query: "测试", page: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
