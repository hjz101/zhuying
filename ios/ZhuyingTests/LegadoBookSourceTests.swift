import XCTest
@testable import Zhuying

/// Original prose and source rules. HTTP responses are fixtures, while parsing,
/// URL expansion and every imported JavaScript expression use the real runtime.
private actor LegadoFixtureTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let json: Bool
    init(json: Bool = false) { self.json = json }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!, path = url.path
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        let body: String
        if json {
            headers["Content-Type"] = "application/json; charset=utf-8"
            switch path {
            case "/search": body = #"{"books":[{"name":"原稿","author":"原创作者","url":"/book/1"}]}"#
            case "/book/1": body = #"{"name":"竹影原稿","author":"原创作者","intro":"原创简介","toc":"/toc/1"}"#
            case "/toc/1": body = #"{"chapters":[{"name":"第一章 信","url":"/chapter/one"}]}"#
            case "/chapter/one": body = #"{"endpoint":"https://fixture.test/prose"}"#
            case "/prose": body = "这段文字通过同步 java.get 的真实 QuickJS 桥读取。"
            default: throw ContentFailure.invalidResponse
            }
        } else {
            switch path {
            case "/search":
                headers["Set-Cookie"] = "sid=fixture-session; Path=/; Secure; HttpOnly"
                body = "<html><div class='book'><a href='/book/1'><span class='name'>山海原稿</span></a><span class='author'>原创作者</span><img src='/cover.png'/></div></html>"
            case "/book/1": body = "<h1>山海原稿</h1><span class='author'>原创作者</span><p class='intro'>仅用于竹影回归的原创故事。</p><a id='toc' href='/toc/1?page=1'>目录</a>"
            case "/toc/1":
                if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value == "2" {
                    body = "<ul><li><a href='/chapter/one'>第一章 信</a></li><li><a href='/chapter/two'>第二章 山</a></li></ul><a class='next' href='?page=1'>上一页</a>"
                } else {
                    body = "<ul><li><a href='/chapter/one'>第一章 信</a></li></ul><a class='next' href='?page=2'>下一页</a>"
                }
            case "/chapter/one":
                if url.query == "part=2" { body = "<article id='content'><p>接续段落。</p><p>这封信来自山谷。</p></article><a class='next' href='?part=2'>本页</a>" }
                else { body = "<article id='content'><p>午后，竹影落在信笺上。</p><p>接续段落。</p></article><a class='next' href='?part=2'>下一页</a>" }
            case "/chapter/two": body = "<article id='content'><p>山路上又传来新的脚步声。</p></article>"
            default: throw ContentFailure.invalidResponse
            }
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

private actor LegadoWaitingTransport: HTTPTransport {
    private(set) var started = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        try await Task.sleep(for: .seconds(20))
        throw ContentFailure.unavailable
    }
}

final class LegadoBookSourceTests: XCTestCase {
    private func source(json: Bool = false, id: String = "original-legado", searchURL: String? = nil) throws -> DemoSource {
        var row: [String: Any] = [
            "bookSourceName": "竹影原创阅读规则回归", "bookSourceUrl": "https://fixture.test/",
            "searchUrl": searchURL ?? "/search?key={{key}}&page={{page}},{\"method\":\"POST\",\"body\":\"key={{key}}\",\"headers\":{\"X-Stage\":\"search\"}}",
            "header": "{\"X-Static\":\"original-fixture\"}",
            "jsLib": "function decorate(value){return '竹影·'+value;}",
            "ruleSearch": ["bookList": ".book", "name": ".name@text@js:decorate(result)", "author": ".author@text", "bookUrl": "a@href", "coverUrl": "img@src"],
            "ruleBookInfo": ["name": "h1@text", "author": ".author@text", "intro": ".intro@text", "tocUrl": "#toc@href"],
            "ruleToc": ["chapterList": "li", "chapterName": "a@text", "chapterUrl": "a@href", "nextTocUrl": ".next@href"],
            "ruleContent": ["content": "#content@html", "nextContentUrl": ".next@href"]
        ]
        if json {
            row["ruleSearch"] = ["bookList": "$.books[*]", "name": "@js:decorate(result.name)", "author": "$.author", "bookUrl": "$.url"]
            row["ruleBookInfo"] = ["name": "$.name", "author": "$.author", "intro": "$.intro", "tocUrl": "$.toc"]
            row["ruleToc"] = ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"]
            row["ruleContent"] = ["content": "@js:java.put('marker','原创尾注'); java.get(JSON.parse(result).endpoint).body() + '\n' + java.get('marker')"]
        }
        var source = DemoSource(id: id, name: "竹影原创阅读规则回归", detail: "原创 fixture", url: "https://fixture.test/")
        source.configuration = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        return source
    }

    func testOriginalHTMLRulesSearchDetailsCatalogPagesAndReadableProse() async throws {
        let transport = LegadoFixtureTransport(), adapter = try LegadoBookSource(source: source(), transport: transport)
        let results = try await adapter.search(query: "山海", page: 1)
        let searched = try XCTUnwrap(results.books.first)
        XCTAssertEqual(searched.title, "竹影·山海原稿")
        XCTAssertEqual(searched.coverURL, "https://fixture.test/cover.png")
        XCTAssertEqual(results.nextPage, 2)
        let book = try await adapter.details(for: searched)
        XCTAssertEqual(book.id, searched.id, "Detail extraction cannot replace stable URL identity")
        XCTAssertEqual(book.summary, "仅用于竹影回归的原创故事。")
        let chapters = try await adapter.chapters(for: book)
        XCTAssertEqual(chapters.map(\.title), ["第一章 信", "第二章 山"])
        XCTAssertEqual(chapters.map(\.order), [0, 1])
        XCTAssertEqual(Set(chapters.map(\.id)).count, 2)
        let prose = try await adapter.document(for: chapters[0], book: book)
        XCTAssertEqual(prose.chapterID, chapters[0].id)
        XCTAssertEqual(prose.paragraphs.map(\.text), ["午后，竹影落在信笺上。", "接续段落。", "这封信来自山谷。"])
        let again = try await adapter.chapters(for: book)
        XCTAssertEqual(again.map(\.id), chapters.map(\.id))
        let requests = await transport.requests
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Stage"), "search")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Static"), "original-fixture")
        XCTAssertEqual(String(data: try XCTUnwrap(requests[0].httpBody), encoding: .utf8), "key=山海")
        XCTAssertEqual(requests.first { $0.url?.path == "/book/1" }?.value(forHTTPHeaderField: "Cookie"), "sid=fixture-session")
        XCTAssertTrue(requests.allSatisfy { !$0.httpShouldHandleCookies })
    }

    func testOriginalJSONRulesUseRealQuickJSCompletionLibraryAndSynchronousHTTPBridge() async throws {
        let transport = LegadoFixtureTransport(json: true), adapter = try LegadoBookSource(source: source(json: true), transport: transport)
        let result = try await adapter.search(query: "原稿", page: 1)
        let searched = try XCTUnwrap(result.books.first)
        XCTAssertEqual(searched.title, "竹影·原稿")
        let book = try await adapter.details(for: searched)
        let chapters = try await adapter.chapters(for: book)
        let chapter = try XCTUnwrap(chapters.first)
        let document = try await adapter.document(for: chapter, book: book)
        XCTAssertEqual(document.paragraphs.map(\.text), ["这段文字通过同步 java.get 的真实 QuickJS 桥读取。", "原创尾注"])
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.url?.path == "/prose" })
    }

    func testCookieSessionsStayIsolatedBetweenSourceInstancesAtSameOrigin() async throws {
        let transport = LegadoFixtureTransport()
        let first = try LegadoBookSource(source: source(id: "first"), transport: transport)
        let second = try LegadoBookSource(source: source(id: "second"), transport: transport)
        let result = try await first.search(query: "one", page: 1)
        _ = try await first.details(for: XCTUnwrap(result.books.first))
        _ = try await second.search(query: "two", page: 1)
        let requests = await transport.requests
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "sid=fixture-session")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Cookie"))
    }

    func testCancellationAndIndependentDeadlineDoNotWaitForSynchronousBridgeNetwork() async throws {
        let transport = LegadoWaitingTransport()
        let adapter = try LegadoBookSource(source: source(), transport: transport)
        let operation = Task { try await adapter.search(query: "cancel", page: 1) }
        for _ in 0..<100 { if await transport.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let start = ProcessInfo.processInfo.systemUptime
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled operation must not return search results") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let timed = try LegadoBookSource(source: source(), transport: transport, deadline: 0.15)
        do { _ = try await timed.search(query: "deadline", page: 1); XCTFail("Deadline must interrupt the source operation") }
        catch { XCTAssertEqual(error as? ContentFailure, .timedOut) }
    }

    func testCharsetAndRequestOptionsAreValidatedWithoutLosingChineseText() throws {
        let text = "竹影原创正文", encoding = try LegadoHTTPExecutor.encoding("gb18030")
        XCTAssertEqual(try LegadoHTTPExecutor.decode(XCTUnwrap(text.data(using: encoding)), charset: "GBK"), text)
        XCTAssertEqual(try LegadoHTTPExecutor.decode(Data(text.utf8), charset: nil), text)
        let (address, options) = try LegadoHTTPExecutor.split("/search,{\"method\":\"POST\",\"body\":{\"key\":\"竹影\"}}")
        XCTAssertEqual(address, "/search"); XCTAssertEqual(options["method"] as? String, "POST")
        XCTAssertThrowsError(try LegadoHTTPExecutor.headers(["Host": "different.example"]))
        XCTAssertFalse(LegadoHTTPExecutor.sameOrigin(URL(string: "https://fixture.test/")!, URL(string: "https://other.test/")!))
    }

    func testSearchKeywordEncodingProtectsURLSeparatorsAndJSONRequestOptions() async throws {
        let transport = LegadoFixtureTransport()
        let adapter = try LegadoBookSource(source: source(), transport: transport)
        let keyword = "竹影 &?=+\""
        _ = try await adapter.search(query: keyword, page: 1)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "key" }?.value, keyword)
        XCTAssertEqual(components.queryItems?.count, 2)
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "key=" + keyword)
    }

    func testBookAndChapterRequestOptionsAreExplicitlyRejectedInsteadOfSilentlyDropped() async throws {
        for section in ["ruleSearch", "ruleToc"] {
            var configured = try source()
            var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
            var rules = try XCTUnwrap(package[section] as? [String: String])
            rules[section == "ruleSearch" ? "bookUrl" : "chapterUrl"] = #"@js:'/chapter/one,{"method":"POST","body":"chapter=1"}'"#
            package[section] = rules
            configured.configuration = try JSONSerialization.data(withJSONObject: package)
            let transport = LegadoFixtureTransport(), adapter = try LegadoBookSource(source: configured, transport: transport)
            do {
                let results = try await adapter.search(query: "request options", page: 1)
                let book = try await adapter.details(for: XCTUnwrap(results.books.first))
                _ = try await adapter.chapters(for: book)
                XCTFail("URL request options must not be discarded")
            } catch {
                XCTAssertEqual(error as? LegadoRequestError, .unsupported("书籍、目录或章节地址附带请求选项"))
            }
            let requests = await transport.requests
            XCTAssertFalse(requests.contains { $0.url?.path == "/chapter/one" })
        }
    }
}
