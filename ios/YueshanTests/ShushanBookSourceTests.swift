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
        XCTAssertEqual(body["version"], "5.61")
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
