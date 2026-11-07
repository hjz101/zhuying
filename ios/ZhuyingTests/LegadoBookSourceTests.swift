import XCTest
@testable import Zhuying

/// Original prose and source rules. HTTP responses are fixtures, while parsing,
/// URL expansion and every imported JavaScript expression use the real runtime.
private actor LegadoFixtureTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let json: Bool
    let nextChapterLink: Bool
    let fragments: Bool
    let searchNextLink: Bool
    let redirectedChapter: Bool
    init(json: Bool = false, nextChapterLink: Bool = false, fragments: Bool = false, searchNextLink: Bool = false, redirectedChapter: Bool = false) {
        self.json = json; self.nextChapterLink = nextChapterLink; self.fragments = fragments; self.searchNextLink = searchNextLink; self.redirectedChapter = redirectedChapter
    }
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
            case "/search", "/books/search":
                headers["Set-Cookie"] = "sid=fixture-session; Path=/; Secure; HttpOnly"
                body = "<html><div class='book'><a href='/book/1'><span class='name'>山海原稿</span></a><span class='author'>原创作者</span><img src='/cover.png'/></div>" + (searchNextLink ? "<a class='next' href='/more?cursor=two'>下一页</a>" : "") + "</html>"
            case "/more": body = "<html><div class='book'><a href='/book/2'><span class='name'>山海续稿</span></a><span class='author'>原创作者</span></div></html>"
            case "/book/1": body = "<h1>山海原稿</h1><span class='author'>原创作者</span><p class='intro'>仅用于竹影回归的原创故事。</p><a id='toc' href='/toc/1?page=1'>目录</a>"
            case "/toc/1":
                if fragments {
                    body = "<ul><li><a href='/reader#one'>第一章 信</a></li><li><a href='/reader#two'>第二章 山</a></li></ul>"
                } else if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value == "2" {
                    body = "<ul><li><a href='/chapter/one'>第一章 信</a></li><li><a href='/chapter/two'>第二章 山</a></li></ul><a class='next' href='?page=1'>上一页</a>"
                } else {
                    body = "<ul><li><a href='/chapter/one'>第一章 信</a></li></ul><a class='next' href='?page=2'>下一页</a>"
                }
            case "/chapter/one":
                if url.query == "part=2" { body = "<article id='content'><p>接续段落。</p><p>这封信来自山谷。</p></article><a class='next' href='\(nextChapterLink ? "/chapter/two" : "?part=2")'>下一页</a>" }
                else { body = "<article id='content'><p>午后，竹影落在信笺上。</p><p>接续段落。</p></article><a class='next' href='?part=2'>下一页</a>" }
            case "/chapter/two": body = "<article id='content'><p>山路上又传来新的脚步声。</p></article>"
            default: throw ContentFailure.invalidResponse
            }
        }
        let finalURL = redirectedChapter && url.path == "/chapter/one" && url.query == "part=2" ? URL(string: "https://fixture.test/chapter/two")! : url
        return (Data(body.utf8), HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: headers)!)
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

private actor LegadoGeneratedMetadataTransport: HTTPTransport {
    enum Mode: Equatable { case search, catalog, cursor }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!, object: [String: Any]
        if url.path == "/book/1" { object = ["name": "原创容量测试", "author": "竹影", "toc": "/toc/1"] }
        else if url.path == "/toc/1" {
            object = ["chapters": (0..<80).map { ["name": "第\($0)章", "index": $0] as [String: Any] }]
        } else if mode == .cursor {
            let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "number" }?.value ?? "1") ?? 1
            object = ["books": [["name": "page-\(page)", "url": "/book/1"]],
                      "next": "https://fixture.test/page?number=\(page + 1)&cursor=" + String(repeating: "x", count: 30_000)]
        } else {
            object = ["books": (0..<(mode == .search ? 80 : 1)).map { ["name": "原创\($0)", "url": "/book/1", "index": $0] as [String: Any] }]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json; charset=utf-8"])!)
    }
}

final class LegadoBookSourceTests: XCTestCase {
    func testScriptedContentPreservesParagraphCommentsThroughFileAndRecentCaches() async throws {
        var source = try source(json: true)
        var definition = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.configuration)) as? [String: Any])
        let html = "<p>脚本返回的原创正文。<comment ident='https://fixture.test/paragraph?para=0' count='18'/></p><note text='原创神评文字' ident='https://fixture.test/paragraph?para=0'/>"
        let literal = String(decoding: try JSONEncoder().encode(html), as: UTF8.self)
        definition["ruleContent"] = ["content": "@js:" + literal]
        source.configuration = try JSONSerialization.data(withJSONObject: definition)
        let adapter = try LegadoBookSource(source: source, transport: LegadoFixtureTransport(json: true))
        let search = try await adapter.search(query: "原创", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(search.books.first))
        let catalog = try await adapter.chapters(for: book)
        let chapter = try XCTUnwrap(catalog.first)
        let document = try await adapter.document(for: chapter, book: book)
        XCTAssertEqual(document.paragraphs.map(\.text), ["脚本返回的原创正文。"])
        let paragraph = try XCTUnwrap(document.paragraphs.first)
        XCTAssertEqual(document.sourceComments?[paragraph.id]?.count, 18)
        XCTAssertEqual(document.sourceComments?[paragraph.id]?.hotComment?.text, "原创神评文字")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileChapterRepository(directory: root.appendingPathComponent("files"))
        try await files.save(document)
        let reopened = try FileChapterRepository(directory: root.appendingPathComponent("files"))
        let restored = try await reopened.document(chapterID: document.chapterID)
        XCTAssertEqual(restored, document)
        let recent = try RecentChapterCache(directory: root.appendingPathComponent("recent"))
        _ = try await recent.save(document, bookID: book.id, fingerprint: "original", protecting: nil)
        let cached = try await recent.document(bookID: book.id, chapterID: chapter.id, fingerprint: "original")
        XCTAssertEqual(cached, document)
    }
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
            row["ruleContent"] = ["content": #"@js:java.put('marker','原创尾注'); java.get(JSON.parse(result).endpoint).body() + '\n' + java.get('marker')"#]
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

    func testBookAndChapterRequestDescriptorsRetainPOSTOptionsOutsideBookMetadata() async throws {
        for section in ["ruleSearch", "ruleToc"] {
            var configured = try source()
            var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
            var rules = try XCTUnwrap(package[section] as? [String: String])
            let path = section == "ruleSearch" ? "/book/1" : "/chapter/one"
            rules[section == "ruleSearch" ? "bookUrl" : "chapterUrl"] = "@js:" + String(decoding: try JSONSerialization.data(withJSONObject: path + #",{"method":"POST","body":"chapter=1"}"#, options: .fragmentsAllowed), as: UTF8.self)
            package[section] = rules; configured.configuration = try JSONSerialization.data(withJSONObject: package)
            let transport = LegadoFixtureTransport(), adapter = try LegadoBookSource(source: configured, transport: transport)
            let results = try await adapter.search(query: "request options", page: 1)
            let book = try await adapter.details(for: XCTUnwrap(results.books.first))
            let chapters = try await adapter.chapters(for: book)
            _ = try await adapter.document(for: XCTUnwrap(chapters.first), book: book)
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first { $0.url?.path == path && $0.httpMethod == "POST" })
            XCTAssertEqual(request.httpBody, Data("chapter=1".utf8))
            XCTAssertFalse(book.source?.bookURL.contains("chapter=1") ?? true)
            XCTAssertFalse(chapters.contains { $0.nativeChapterID.contains("chapter=1") })
        }
    }

    func testOptionalCoverRequestCredentialsNeverEnterPersistentBookMetadata() async throws {
        var configured = try source()
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(configured.configuration)) as? [String: Any])
        let descriptor = #"https://fixture.test/cover,{"headers":{"Authorization":"original-private-fixture-value"}}"#
        let rule = "@js:" + String(decoding: try JSONSerialization.data(withJSONObject: descriptor, options: .fragmentsAllowed), as: UTF8.self)
        for section in ["ruleSearch", "ruleBookInfo"] {
            var rules = try XCTUnwrap(package[section] as? [String: String]); rules["coverUrl"] = rule; package[section] = rules
        }
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let adapter = try LegadoBookSource(source: configured, transport: LegadoFixtureTransport())
        let searched = try await adapter.search(query: "原创封面", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(searched.books.first))
        XCTAssertNil(book.coverURL)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(book), as: UTF8.self).contains("original-private-fixture-value"))
    }

    func testUnsupportedContentTransformsNeverReturnUnprocessedProseAsSuccess() async throws {
        var configured = try source()
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        var rules = try XCTUnwrap(package["ruleContent"] as? [String: String])
        rules["webJs"] = "document.querySelector('#content').innerText"
        package["ruleContent"] = rules
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let adapter = try LegadoBookSource(source: configured, transport: LegadoFixtureTransport())
        let results = try await adapter.search(query: "source", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(results.books.first))
        let chapters = try await adapter.chapters(for: book)
        do { _ = try await adapter.document(for: XCTUnwrap(chapters.first), book: book); XCTFail("WebView transforms require an explicit unsupported error") }
        catch { XCTAssertEqual(error as? LegadoCompatibilityError, .unsupported("ruleContent.webJs")) }
    }

    func testContentPaginationStopsBeforeNextKnownChapterIncludingAfterAdapterRecreation() async throws {
        let transport = LegadoFixtureTransport(nextChapterLink: true), configured = try source()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LegadoPaginationVault()
        let state = try LegadoPersistentState(sourceID: configured.id, directory: directory, vault: vault)
        let adapter = try LegadoBookSource(source: configured, transport: transport, state: state)
        let results = try await adapter.search(query: "pages", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(results.books.first))
        let chapters = try await adapter.chapters(for: book)
        XCTAssertEqual(chapters.count, 2)
        guard chapters.count == 2 else { return }
        XCTAssertEqual(chapters[0].requestParameters["legado.nextChapterURL"], chapters[1].nativeChapterID)
        let first = try await adapter.document(for: chapters[0], book: book)
        XCTAssertEqual(first.paragraphs.map(\.text), ["午后，竹影落在信笺上。", "接续段落。", "这封信来自山谷。"])
        let restored = try LegadoPersistentState(sourceID: configured.id, directory: directory, vault: vault)
        let recreated = try LegadoBookSource(source: configured, transport: transport, state: restored)
        let reopened = try await recreated.document(for: chapters[0], book: book)
        XCTAssertEqual(reopened, first)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/chapter/two" }, "A chapter's next-page rule must never fetch the next chapter")
    }

    func testFragmentChapterAddressesAreRejectedBeforeDeduplicationCanCollapseThem() async throws {
        let adapter = try LegadoBookSource(source: source(), transport: LegadoFixtureTransport(fragments: true))
        let results = try await adapter.search(query: "fragments", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(results.books.first))
        do { _ = try await adapter.chapters(for: book); XCTFail("Fragment chapter addresses are not HTTP chapter identities") }
        catch { XCTAssertEqual(error as? LegadoRequestError, .unsupported("依赖 URL fragment 的书籍或章节地址")) }
    }

    func testContentPageRedirectToKnownChapterCannotMergeAnotherChapterBody() async throws {
        let adapter = try LegadoBookSource(source: source(), transport: LegadoFixtureTransport(redirectedChapter: true))
        let results = try await adapter.search(query: "redirect", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(results.books.first))
        let chapters = try await adapter.chapters(for: book)
        let document = try await adapter.document(for: XCTUnwrap(chapters.first), book: book)
        XCTAssertEqual(document.paragraphs.map(\.text), ["午后，竹影落在信笺上。", "接续段落。"])
    }

    func testRequestHeaderOverridesAreCaseInsensitiveAndNeverRandomlyReplaceCredentials() async throws {
        var configured = try source()
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        package["header"] = #"{"Authorization":"old","Cookie":"old-cookie","X-Static":"preserved"}"#
        package["searchUrl"] = #"/search?key={{key}},{"headers":{"authorization":"new","cookie":"new-cookie"}}"#
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let transport = LegadoFixtureTransport(), adapter = try LegadoBookSource(source: configured, transport: transport)
        _ = try await adapter.search(query: "headers", page: 1)
        let requests = await transport.requests, request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "new")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "new-cookie")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Static"), "preserved")
        XCTAssertThrowsError(try LegadoHTTPExecutor.headers(["Cookie": "one", "cookie": "two"]))
    }

    func testRecursiveURLScriptsCannotReenterNewJavaScriptVMsUntilTheNativeStackOverflows() async throws {
        var configured = try source(searchURL: "@js:loop()")
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        package["jsLib"] = "function loop(){return java.ajax('@js:loop()')}"
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let transport = LegadoFixtureTransport(), adapter = try LegadoBookSource(source: configured, transport: transport)
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await adapter.search(query: "recursive", page: 1); XCTFail("Recursive native reentry must hit a source quota") }
        catch { XCTAssertTrue(error.localizedDescription.contains("重入"), error.localizedDescription) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testVariableAggregateQuotaRejectsNewAndReplacementValuesWithoutPollutingPriorState() async throws {
        var configured = try source()
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        package["ruleContent"] = ["content": #"@js:java.put('keep','stable');let big='x'.repeat(131072);for(let i=0;i<3;i++){java.put('v'+i,big)};let failures=0;try{java.put('overflow',big)}catch(e){failures++}try{java.put('keep',big)}catch(e){failures++}if(failures!==2){throw Error('quota did not reject writes')}java.get('keep')+'|'+java.get('overflow')"#]
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let adapter = try LegadoBookSource(source: configured, transport: LegadoFixtureTransport())
        let results = try await adapter.search(query: "variables", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(results.books.first))
        let chapters = try await adapter.chapters(for: book)
        let document = try await adapter.document(for: XCTUnwrap(chapters.first), book: book)
        XCTAssertEqual(document.paragraphs.map(\.text), ["stable|"])
    }

    func testSourceCookieJarHasAnAggregateByteQuotaAndEvictsOldValues() throws {
        let jar = LegadoCookieJar(), url = try XCTUnwrap(URL(string: "https://fixture.test/"))
        for index in 0..<100 { jar.set("item\(index)=" + String(repeating: "x", count: 2000) + "; Path=/; Secure", url: url) }
        let header = try XCTUnwrap(jar.header(for: url))
        XCTAssertLessThanOrEqual(header.utf8.count, 128 * 1024)
        XCTAssertFalse(header.contains("item0="))
        XCTAssertTrue(header.contains("item99="))
    }

    func testSearchNextPageURLUsesReturnedCursorInsteadOfRepeatingInitialTemplate() async throws {
        var configured = try source(searchURL: "/search?key={{key}}")
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        var rules = try XCTUnwrap(package["ruleSearch"] as? [String: String])
        rules["nextPageUrl"] = ".next@href"; package["ruleSearch"] = rules
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let transport = LegadoFixtureTransport(searchNextLink: true), adapter = try LegadoBookSource(source: configured, transport: transport)
        let first = try await adapter.search(query: "next", page: 1)
        XCTAssertEqual(first.nextPage, 2)
        let second = try await adapter.search(query: "next", page: 2)
        XCTAssertEqual(second.books.first?.title, "竹影·山海续稿")
        XCTAssertNotEqual(first.books.first?.id, second.books.first?.id)
        XCTAssertNil(second.nextPage)
        let requests = await transport.requests
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/search", "/more"])
        do { _ = try await adapter.search(query: "different", page: 2); XCTFail("A different keyword must never reuse another query's cursor") }
        catch { XCTAssertEqual(error as? LegadoRequestError, .unsupported("没有该关键词的下一页地址，请重新搜索")) }
    }

    func testGeneratedLongURLsCannotExceedSearchOrCatalogMetadataBudgets() async throws {
        for mode in [LegadoGeneratedMetadataTransport.Mode.search, .catalog] {
            var configured = try source(json: true)
            var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
            package["ruleSearch"] = ["bookList": "$.books[*]", "name": "$.name", "bookUrl": mode == .search ? "@js:'/book/'+'x'.repeat(30000)+result.index" : "$.url"]
            package["ruleToc"] = ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "@js:'/chapter/'+'x'.repeat(30000)+result.index"]
            configured.configuration = try JSONSerialization.data(withJSONObject: package)
            let adapter = try LegadoBookSource(source: configured, transport: LegadoGeneratedMetadataTransport(mode))
            do {
                let result = try await adapter.search(query: "metadata", page: 1)
                if mode == .catalog {
                    let book = try await adapter.details(for: XCTUnwrap(result.books.first))
                    _ = try await adapter.chapters(for: book)
                }
                XCTFail("Generated metadata over 2 MiB must be rejected before it is returned or cached")
            } catch { XCTAssertEqual(error as? LegadoRequestError, .limit) }
        }
    }

    func testSearchCursorByteQuotaRejectsNewPagesWithoutDestroyingExistingCursors() async throws {
        var configured = try source(json: true, searchURL: "/search?key={{key}}")
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        package["ruleSearch"] = ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url", "nextPageUrl": "$.next"]
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let adapter = try LegadoBookSource(source: configured, transport: LegadoGeneratedMetadataTransport(.cursor))
        var reachedLimit = false
        for page in 1...30 {
            do { _ = try await adapter.search(query: "cursor quota", page: page) }
            catch { XCTAssertEqual(error as? LegadoRequestError, .limit); reachedLimit = true; break }
        }
        XCTAssertTrue(reachedLimit, "Session cursor URLs must have a 512 KiB aggregate budget")
        let saved = try await adapter.search(query: "cursor quota", page: 2)
        XCTAssertEqual(saved.books.first?.title, "page-2", "A failed new cursor must leave previously accepted cursor URLs intact")
    }

    func testRelativeSearchURLResolvesAgainstSourcePathWhileRequestsStayInsideOrigin() async throws {
        var configured = try source(searchURL: "search?key={{key}}")
        var package = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configured.configuration)) as? [String: Any])
        package["bookSourceUrl"] = "https://fixture.test/books/"
        configured.configuration = try JSONSerialization.data(withJSONObject: package)
        let transport = LegadoFixtureTransport(), adapter = try LegadoBookSource(source: configured, transport: transport)
        let result = try await adapter.search(query: "relative", page: 1)
        XCTAssertEqual(result.books.first?.title, "竹影·山海原稿")
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.path, "/books/search")
        XCTAssertEqual(result.books.first?.source?.origin, "https://fixture.test/")
    }
}

private final class LegadoPaginationVault: LegadoSecretVault {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func save(_ data: Data, id: String) throws { values[id] = data }
    func remove(id: String) throws { values[id] = nil }
}
