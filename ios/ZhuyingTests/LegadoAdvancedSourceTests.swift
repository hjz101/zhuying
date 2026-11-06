import XCTest
@testable import Zhuying

private final class AdvancedSourceMemoryVault: LegadoSecretVault {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ data: Data, id: String) throws { lock.lock(); values[id] = data; lock.unlock() }
    func remove(id: String) throws { lock.lock(); values[id] = nil; lock.unlock() }
}

/// All books, prose, endpoints and rules are original fixtures. They exercise
/// the real parser, request executor, storage and QuickJS host without live I/O.
private actor AdvancedSourceTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try XCTUnwrap(request.url), path = url.path
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        let data: Data
        if path == "/search" {
            data = try JSONSerialization.data(withJSONObject: ["books": [
                ["id": "A", "title": "山谷来信", "author": "竹影原创"],
                ["id": "B", "title": "竹林日记", "author": "竹影原创"]
            ]])
        } else if path.hasPrefix("/toc/") {
            let book = String(path.dropFirst(5))
            data = try JSONSerialization.data(withJSONObject: ["chapters": [
                ["book_id": book, "item_id": "1", "title": "第一章 \(book)"],
                ["book_id": book, "item_id": "2", "title": "第二章 \(book)"]
            ]])
        } else if path.hasPrefix("/content/") {
            headers["Content-Type"] = "text/plain; charset=utf-8"
            let identity = String(path.dropFirst(9)).replacingOccurrences(of: "/", with: "-")
            data = Data("原创正文\(identity)。\n原创续段\(identity)。".utf8)
        } else if path == "/set-cookie" {
            // Deliberately broad Domain: the source/account/origin boundary
            // must be stricter than the cookie's domain matching permission.
            headers["Set-Cookie"] = "sid=alpha-only; Domain=.fixture.test; Path=/; Secure; HttpOnly"
            data = Data("{}".utf8)
        } else if path == "/inspect-cookie" { data = Data("{}".utf8) }
        else { throw ContentFailure.invalidResponse }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

final class LegadoAdvancedSourceTests: XCTestCase {
    private let sourceID = "original-opaque-advanced"
    private var directory: URL!
    private var vault: AdvancedSourceMemoryVault!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingAdvanced-" + UUID().uuidString)
        vault = AdvancedSourceMemoryVault()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func state(account: String = "reader") throws -> LegadoPersistentState {
        try .init(sourceID: sourceID, accountID: account, directory: directory, vault: vault)
    }
    private func source() throws -> DemoSource {
        let library = #"""
            var host=['https://alpha.fixture.test','https://beta.fixture.test'];
            source.setVariable('libraryBoots',String(Number(source.getVariable('libraryBoots')||0)+1));
            var libraryCounter=0;
            function selectedHost(){return source.getVariable('server')||host[0];}
            function inlineRef(value,type){return 'data:;base64,'+java.base64Encode(JSON.stringify(value))+','+JSON.stringify({type:type});}
            function readInline(hex){
              if(!/^[0-9a-f]+$/i.test(hex)||hex.length%2)throw new Error('Expected original HEX input');
              source.setVariable('lastInlineHex',hex);return JSON.parse(java.hexDecodeToString(hex));
            }
            function bookRef(row){return inlineRef({book_id:row.id,sources:'original',tab:'novel',url:selectedHost()},'qingtian');}
            function tocItems(hex){const meta=readInline(hex);java.put('active-book',meta.book_id);return JSON.parse(java.ajax(selectedHost()+'/toc/'+meta.book_id)).chapters;}
            function chapterRef(row){return inlineRef({book_id:row.book_id,item_id:row.item_id,sources:'original',tab:'novel',url:selectedHost()},'qingtian3');}
            function chapterBody(hex){const meta=readInline(hex);if(java.get('active-book')!==meta.book_id)throw new Error('Cross-book java variable');return java.ajax(selectedHost()+'/content/'+meta.book_id+'/'+meta.item_id);}
            """#
        let login = #"""
            var loginLibraryValue='共享登录库';
            function login(){
              source.putLoginInfo(JSON.stringify(result));
              source.setVariable('loginShared',loginLibraryValue+':'+(++libraryCounter));
              cache.put('login-cache',result['账号'],300);
              source.setLoginHeader({'X-Reader':result['账号']});
              java.toast('原创登录操作已提交');
            }
            """#
        let row: [String: Any] = [
            "bookSourceName": "竹影原创内部引用回归", "bookSourceUrl": "竹影·原创聚合源",
            "jsLib": library, "loginUrl": login,
            "searchUrl": "@js:selectedHost()+'/search?key='+java.encodeURI(key)",
            "ruleSearch": ["bookList": "$.books[*]", "name": "@js:loginLibraryValue+':'+result.title", "author": "$.author", "bookUrl": "@js:bookRef(result)"],
            "ruleBookInfo": ["name": "@js:'原创书籍'+readInline(result).book_id", "intro": "@js:'HEX:'+result", "tocUrl": "@js:inlineRef(readInline(result),'qingtian2')"],
            "ruleToc": ["chapterList": "@js:tocItems(result)", "chapterName": "$.title", "chapterUrl": "@js:chapterRef(result)"],
            "ruleContent": ["content": "@js:chapterBody(result)"]
        ]
        var source = DemoSource(id: sourceID, name: "竹影原创内部引用回归", detail: "原创离线回归", url: "竹影·原创聚合源")
        source.configuration = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return source
    }

    func testOpaqueSourceDeclaredHostsAndOriginalInlineHexReadEveryChapterOfTwoBooks() async throws {
        let configured = try source(), state = try state(), transport = AdvancedSourceTransport()
        let adapter = try LegadoBookSource(source: configured, transport: transport, state: state)
        XCTAssertNil(adapter.definition.baseURL)
        XCTAssertEqual(Set(adapter.definition.policy.allowedOrigins.compactMap(\.host)), ["alpha.fixture.test", "beta.fixture.test"])
        let searched = try await adapter.search(query: "原创", page: 1)
        XCTAssertEqual(searched.books.map(\.title), ["共享登录库:山谷来信", "共享登录库:竹林日记"])
        XCTAssertEqual(searched.books.count, 2)
        var allChapterIDs = Set<String>()
        var firstReading: (LibraryBookRecord, ChapterRecord)?
        for (index, searchBook) in searched.books.enumerated() {
            let identity = index == 0 ? "A" : "B"
            XCTAssertTrue(searchBook.source?.bookURL.hasPrefix("legado-ref:") == true)
            XCTAssertFalse(searchBook.id.contains("data:"))
            let book = try await adapter.details(for: searchBook)
            XCTAssertEqual(book.id, searchBook.id)
            XCTAssertEqual(book.title, "原创书籍" + identity)
            let summaryHex = String(book.summary.dropFirst(4))
            let summaryData = try XCTUnwrap(try? LegadoCryptoHost.hex(summaryHex))
            let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: summaryData) as? [String: String])
            XCTAssertEqual(summary["book_id"], identity)
            let chapters = try await adapter.chapters(for: book)
            XCTAssertEqual(chapters.map(\.title), ["第一章 \(identity)", "第二章 \(identity)"])
            XCTAssertEqual(chapters.count, 2)
            if index == 0, let chapter = chapters.first { firstReading = (book,chapter) }
            for (chapterIndex, chapter) in chapters.enumerated() {
                XCTAssertTrue(allChapterIDs.insert(chapter.id).inserted, "Identical item_id values in different books must remain separate")
                XCTAssertTrue(chapter.nativeChapterID.hasPrefix("legado-ref:"))
                let document = try await adapter.document(for: chapter, book: book)
                XCTAssertEqual(document.chapterID, chapter.id)
                XCTAssertEqual(document.paragraphs.map(\.text), ["原创正文\(identity)-\(chapterIndex+1)。", "原创续段\(identity)-\(chapterIndex+1)。"])
            }
        }
        XCTAssertEqual(allChapterIDs.count, 4)
        let last = try JSONSerialization.jsonObject(with: LegadoCryptoHost.hex(state.getVariable("source:lastInlineHex"))) as? [String: String]
        XCTAssertEqual(last?["book_id"], "B"); XCTAssertEqual(last?["item_id"], "2")
        if let (book,chapter) = firstReading {
            let revisited = try await adapter.document(for: chapter, book: book)
            XCTAssertEqual(revisited.paragraphs.first?.text, "原创正文A-1。", "Book B's java.put values must not replace book A's values")
        }
        XCTAssertEqual(try state.getVariable("source:libraryBoots"), "1", "Every rule and request must reuse one library initialization")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 8, "Inline details/catalog references must never be sent as network requests")
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "alpha.fixture.test" })
    }

    func testRestartAndChangingDeclaredRoutePreserveBookChapterAndReadingIdentity() async throws {
        let configured = try source(), firstState = try state(), transport = AdvancedSourceTransport()
        let first = try LegadoBookSource(source: configured, transport: transport, state: firstState)
        let originalSearch = try await first.search(query: "原创", page: 1)
        let originalBook = try await first.details(for: XCTUnwrap(originalSearch.books.first))
        let originalChapters = try await first.chapters(for: originalBook)
        let originalDocument = try await first.document(for: XCTUnwrap(originalChapters.first), book: originalBook)
        try firstState.setVariable("https://beta.fixture.test", key: "source:server")
        let reopenedState = try state(), reopened = try LegadoBookSource(source: configured, transport: transport, state: reopenedState)
        let reread = try await reopened.document(for: XCTUnwrap(originalChapters.first), book: originalBook)
        XCTAssertEqual(reread, originalDocument, "Saved opaque references must survive process recreation")
        let renewedSearch = try await reopened.search(query: "原创", page: 1)
        XCTAssertEqual(renewedSearch.books.map(\.id), originalSearch.books.map(\.id))
        let renewedBook = try await reopened.details(for: XCTUnwrap(renewedSearch.books.first))
        let renewedChapters = try await reopened.chapters(for: renewedBook)
        XCTAssertEqual(renewedBook.id, originalBook.id)
        XCTAssertEqual(renewedChapters.map(\.id), originalChapters.map(\.id))
        XCTAssertEqual(renewedChapters.map(\.nativeChapterID), originalChapters.map(\.nativeChapterID))
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.url?.host == "beta.fixture.test" && $0.url?.path == "/content/A/1" })
        XCTAssertEqual(try reopenedState.getVariable("source:libraryBoots"), "2")
    }

    func testLoginFunctionsAndLibraryGlobalsShareScopeAndPersistThroughStateRecreation() async throws {
        let configured = try source(), state = try state(), transport = AdvancedSourceTransport()
        let adapter = try LegadoBookSource(source: configured, transport: transport, state: state)
        let result = try await adapter.login(action: "login()", values: ["账号": "原创读者", "密码": "fixture-password"])
        XCTAssertTrue(result.message.contains("原创登录操作已提交"))
        XCTAssertEqual(try state.getVariable("source:loginShared"), "共享登录库:1")
        XCTAssertEqual(try state.cacheGet("login-cache"), "原创读者")
        XCTAssertEqual(state.authStatus, .unverified, "Completing a script must not manufacture authentication success")
        _ = try await adapter.search(query: "原创", page: 1)
        XCTAssertEqual(try state.getVariable("source:libraryBoots"), "1")
        let reopened = try self.state()
        XCTAssertEqual(try reopened.getLoginInfoMap(), ["账号": "原创读者", "密码": "fixture-password"])
        XCTAssertEqual(try reopened.cacheGet("login-cache"), "原创读者")
        let headerAction = try await adapter.login(action: "java.toast(JSON.stringify(source.getLoginHeader()))", values: ["账号": "原创读者", "密码": "fixture-password"])
        let header = try LegadoHTTPExecutor.headers(headerAction.message)
        XCTAssertEqual(header["x-reader"], "原创读者")
        XCTAssertEqual(try self.state(account: "different").getLoginInfo(), "")
    }

    func testCookiesNeverCrossDeclaredHostsWithPersistentOrEphemeralSessions() async throws {
        for persistent in [false, true] {
            let transport = AdvancedSourceTransport(), state = persistent ? try self.state() : nil
            try await Task.detached {
                let alpha = URL(string: "https://alpha.fixture.test/")!, beta = URL(string: "https://beta.fixture.test/")!
                let policy = try LegadoSourcePolicy(sourceID: "cookie-fixture", declaredOrigins: [alpha,beta])
                let http = LegadoHTTPExecutor(origin: nil, policy: policy, state: state, transport: transport,
                                              control: LegadoOperationControl(timeout: 5), cookies: LegadoCookieJar())
                _ = try http.request(alpha.absoluteString + "set-cookie")
                _ = try http.request(beta.absoluteString + "inspect-cookie")
                _ = try http.request(alpha.absoluteString + "inspect-cookie")
            }.value
            let requests = await transport.requests
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"), "Cookie leaked across declared hosts; persistent=\(persistent)")
            XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Cookie"), "sid=alpha-only")
            XCTAssertTrue(requests.allSatisfy { !$0.httpShouldHandleCookies })
        }
    }

    func testInheritedAuthorizationAndManualCookieStayAtTheirHostWhileExplicitOptionsRemainExplicit() async throws {
        for (hasBase, explicitHeaders) in [(false,false),(false,true),(true,false)] {
            var configured = try source()
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(configured.configuration)) as? [String: Any])
            if hasBase { row["bookSourceUrl"] = "https://alpha.fixture.test/" }
            row["header"] = #"{"Authorization":"Bearer inherited-fixture","Cookie":"manual=alpha","X-Private":"inherited-private-fixture","Accept":"application/json"}"#
            let prepare = hasBase ? "" : "java.ajax(host[0]+'/inspect-cookie');"
            row["searchUrl"] = "@js:" + prepare + "host[1]+'/search'" +
                (explicitHeaders ? #"+',{"headers":{"Authorization":"Bearer explicit-fixture","Cookie":"manual=beta"}}'"# : "")
            configured.configuration = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let transport = AdvancedSourceTransport(), adapter = try LegadoBookSource(source: configured, transport: transport)
            let results = try await adapter.search(query: "原创", page: 1)
            XCTAssertEqual(results.books.count, 2)
            let requests = await transport.requests
            if !hasBase {
                let first = try XCTUnwrap(requests.first)
                XCTAssertEqual(first.url?.host, "alpha.fixture.test")
                XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer inherited-fixture")
                XCTAssertEqual(first.value(forHTTPHeaderField: "Cookie"), "manual=alpha")
            }
            let crossHost = try XCTUnwrap(requests.last)
            XCTAssertEqual(crossHost.url?.host, "beta.fixture.test")
            XCTAssertEqual(crossHost.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(crossHost.value(forHTTPHeaderField: "X-Private"))
            if explicitHeaders {
                XCTAssertEqual(crossHost.value(forHTTPHeaderField: "Authorization"), "Bearer explicit-fixture")
                XCTAssertEqual(crossHost.value(forHTTPHeaderField: "Cookie"), "manual=beta")
            } else {
                XCTAssertNil(crossHost.value(forHTTPHeaderField: "Authorization"), "Inherited authentication crossed source-declared hosts")
                XCTAssertNil(crossHost.value(forHTTPHeaderField: "Cookie"), "Inherited manual Cookie crossed source-declared hosts")
            }
        }
    }
}
