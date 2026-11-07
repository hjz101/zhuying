import XCTest
@testable import Zhuying

private actor DiscoveryFixtureTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let object: [String: Any]
        if url.path == "/categories" { object = ["title": "动态榜单", "url": "/rank?page={{page}}"] }
        else {
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "1"
            object = ["books": page == "3" ? [] : [["name": "榜单作品" + page, "author": "原创作者", "intro": "分类真实解析", "url": "/book/" + page, "cover": "/cover.png"]]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
private actor SearchSelectionFixture: DiscoveryBookSource {
    nonisolated let sourceID: String
    nonisolated var supportsDiscovery: Bool { true }
    private(set) var searchCalls = 0
    private(set) var detailsCalls = 0
    init(_ id: String) { sourceID = id }
    func discoveryCategories() async throws -> [SourceDiscoveryCategory] { [.init(title: "慢分类", request: "slow"), .init(title: "新分类", request: "new")] }
    func search(query: String, page: Int) async throws -> BookSearchPage {
        searchCalls += 1
        let titles = page == 1 ? ["无关推荐", " 山 间 来 信 "] : page == 2 ? ["无关推荐二"] : ["山间来信"]
        return .init(books: titles.enumerated().map { index, title in record("\(page)-\(index)", title: title) }, nextPage: page < 3 ? page + 1 : nil)
    }
    func discover(category: String, page: Int) async throws -> BookSearchPage {
        if category == "slow" { try? await Task.sleep(for: .milliseconds(80)) }
        return .init(books: [record(category, title: category)], nextPage: nil)
    }
    private func record(_ id: String, title: String) -> LibraryBookRecord {
        .init(id: sourceID + id, title: title, author: "原创作者", summary: "简介", source: .init(sourceID: sourceID, nativeBookID: id, provider: sourceID, bookURL: "https://fixture.test/book/" + id), addedAt: Date())
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord {
        detailsCalls += 1; var value = book; value.summary = "刷新版本\(detailsCalls)"; return value
    }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] { [.init(id: book.id + "-1", bookID: book.id, nativeChapterID: "1", title: "第一章", order: 0, access: .readable)] }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument { .init(chapterID: chapter.id, paragraphs: ["原创正文"]) }
}

private final class DiscoveryFilterVault: LegadoSecretVault {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func read(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ data: Data, id: String) throws { lock.lock(); defer { lock.unlock() }; values[id] = data }
    func remove(id: String) throws { lock.lock(); defer { lock.unlock() }; values[id] = nil }
}
private actor DiscoveryFilterTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    var fails = false
    func fail(_ value: Bool) { fails = value }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if fails { throw ContentFailure.unavailable }
        let url = request.url!
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mode" }?.value ?? "不限"
        let object: [String: Any] = ["books": [["name": "筛选作品·" + mode, "author": "原创作者", "url": "/book/" + (mode == "不限" ? "all" : "filtered")]]]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

final class DiscoveryAndSearchTests: XCTestCase {
    private func makeService(_ sources: [any BookSource]) async throws -> (OnlineReadingService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let value = OnlineReadingService(cache: try RecentChapterCache(directory: root))
        await value.configure(sources: sources); return (value, root)
    }
    private func source(explore: String) throws -> DemoSource {
        let list = ["bookList": "$.books[*]", "name": "$.name", "author": "$.author", "intro": "$.intro", "bookUrl": "$.url", "coverUrl": "$.cover"]
        let row: [String: Any] = ["bookSourceName": "竹影原创发现", "bookSourceUrl": "https://discovery.fixture/", "searchUrl": "/search?key={{key}}&page={{page}}", "exploreUrl": explore,
                                  "ruleSearch": list, "ruleExplore": list, "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"], "ruleContent": ["content": "$.text"]]
        var value = DemoSource(id: "discovery-source", name: "竹影原创发现", detail: "", url: "https://discovery.fixture/")
        value.configuration = try JSONSerialization.data(withJSONObject: row); return value
    }
    private func filterSource(action: String? = nil) throws -> DemoSource {
        let action = action ?? "show(infoMap['任意维度'],'mode')"
        let encoded = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        let choices = String(decoding: try JSONEncoder().encode(["不限", "选项\"\\换行\n内容';throw new Error('不得作为脚本')"]), as: UTF8.self)
        var value = try source(explore: """
        @js:
        if(!source.getVariable()) source.setVariable(JSON.stringify({mode:'不限',keep:'保留字段'}));
        var filterConfig=JSON.parse(source.getVariable());
        JSON.stringify([
          {title:'任意分组'},
          {title:'任意维度',type:'select',chars:\(choices),default:filterConfig.mode,action:\(encoded)},
          {title:'辅助维度',type:'select',choices:filterConfig.mode==='不限'?['辅助甲','辅助乙']:['变化后的平台'],default:filterConfig.mode==='不限'?'辅助甲':'变化后的平台',action:'java.toast(infoMap["辅助维度"])'},
          {title:'榜单',url:'/rank?mode='+encodeURIComponent(filterConfig.mode)+'&page={{page}}'}
        ])
        """)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.configuration)) as? [String: Any])
        row["jsLib"] = """
        function show(m,t){
          var data=JSON.parse(source.getVariable());
          data[t]=m; data.actionCount=(data.actionCount||0)+1;
          data.otherBinding=infoMap['辅助维度'];
          data.resultBinding=result; data.valueBinding=value;
          source.setVariable(JSON.stringify(data)); java.refreshExplore();
        }
        """
        value.configuration = try JSONSerialization.data(withJSONObject: row)
        return value
    }
    func testSelectFilterParserKeepsSourceChoicesDefaultsAndActionsWithoutInventingHeaders() throws {
        let json = #"[{"title":"自定义维度","type":"select","chars":["不限","选项甲","选项甲"],"default":"选项甲","action":"show(infoMap['自定义维度'],'customKey')"},{"title":"另一个维度","type":"select","choices":["甲","乙"],"default":"源提供的默认值","action":"java.toast(result)"},{"title":"纯说明"}]"#
        let categories = try SourceDiscoveryCategory.parse(json)
        XCTAssertTrue(categories[0].isFilter); XCTAssertFalse(categories[0].isHeader); XCTAssertFalse(categories[0].readable)
        XCTAssertEqual(categories[0].filter?.choices, ["不限", "选项甲"])
        XCTAssertEqual(categories[0].filter?.selectedValue, "选项甲")
        XCTAssertEqual(categories[0].filter?.action, "show(infoMap['自定义维度'],'customKey')")
        XCTAssertEqual(categories[1].filter?.selectedValue, "源提供的默认值")
        XCTAssertTrue(categories[2].isHeader)
        let empty = try XCTUnwrap(SourceDiscoveryCategory.parse(#"[{"title":"当前无平台","type":"select","chars":[],"default":"","action":"noop()"}]"#).first)
        XCTAssertTrue(empty.isFilter); XCTAssertFalse(empty.isHeader)
        XCTAssertEqual(empty.filter?.choices, []); XCTAssertEqual(empty.filter?.selectedValue, "")
        for invalid in [
            #"[{"title":"筛选","type":"select","chars":"甲乙","action":"noop()"}]"#,
            #"[{"title":"筛选","type":"select","chars":["甲",3],"action":"noop()"}]"#,
            #"[{"title":"筛选","type":"select","chars":["甲"],"action":""}]"#
        ] { XCTAssertThrowsError(try SourceDiscoveryCategory.parse(invalid)) }
    }
    @MainActor func testConfirmedFilterActionBindsStringAndAllFieldsPersistsWithoutLoginAndReloadsCurrentBooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = DiscoveryFilterVault()
        let state = try LegadoPersistentState(sourceID: "filter-source", accountID: "reader", libraryProfile: "tests", directory: directory, vault: vault)
        let transport = DiscoveryFilterTransport(), source = try filterSource()
        let adapter = try LegadoBookSource(source: source, transport: transport, state: state)
        let (service, root) = try await makeService([adapter]); defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineDiscoveryStore(); store.open(sourceID: adapter.sourceID, service: service)
        try await wait { !store.busy }
        XCTAssertEqual(store.books.first?.title, "筛选作品·不限")
        let filter = try XCTUnwrap(store.categories.first { $0.isFilter })
        let value = try XCTUnwrap(filter.filter?.choices.last)
        let epoch = state.sessionRevision, status = state.authStatus
        store.applyFilter(filter, value: "不存在的选项", service: service)
        XCTAssertFalse(store.busy); XCTAssertEqual(store.books.first?.title, "筛选作品·不限")
        store.applyFilter(filter, value: value, service: service)
        XCTAssertEqual(store.books.first?.title, "筛选作品·不限", "Keep accepted books until the new request succeeds")
        try await wait { !store.busy }
        XCTAssertNil(store.message); XCTAssertEqual(store.selected?.title, "榜单")
        XCTAssertEqual(store.books.first?.title, "筛选作品·" + value)
        XCTAssertEqual(store.categories.first { $0.isFilter }?.filter?.selectedValue, value)
        XCTAssertEqual(store.categories.first { $0.title == "辅助维度" }?.filter?.choices, ["变化后的平台"])
        XCTAssertEqual(store.categories.first { $0.title == "辅助维度" }?.filter?.selectedValue, "变化后的平台")
        XCTAssertEqual(state.sessionRevision, epoch); XCTAssertEqual(state.authStatus, status)
        XCTAssertTrue(try state.getLoginInfo().isEmpty)
        let reopened = try LegadoPersistentState(sourceID: "filter-source", accountID: "reader", libraryProfile: "tests", directory: directory, vault: vault)
        let variables = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reopened.getVariable("source:variable").utf8)) as? [String: Any])
        XCTAssertEqual(variables["mode"] as? String, value); XCTAssertEqual(variables["keep"] as? String, "保留字段")
        XCTAssertEqual(variables["actionCount"] as? Int, 1)
        XCTAssertEqual(variables["otherBinding"] as? String, "辅助甲")
        XCTAssertEqual(variables["resultBinding"] as? String, value); XCTAssertEqual(variables["valueBinding"] as? String, value)
        let newAdapter = try LegadoBookSource(source: source, transport: transport, state: reopened)
        let reopenedCategories = try await newAdapter.discoveryCategories()
        XCTAssertEqual(reopenedCategories.first { $0.isFilter }?.filter?.selectedValue, value)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "refreshExplore only regenerates controls; it makes no hidden HTTP request")
    }
    @MainActor func testFilterActionAndReloadErrorsKeepAcceptedCategoriesAndBooks() async throws {
        let transport = DiscoveryFilterTransport()
        let adapter = try LegadoBookSource(source: filterSource(action: "throw new Error('original fixture failure')"), transport: transport)
        let (service, root) = try await makeService([adapter]); defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineDiscoveryStore(); store.open(sourceID: adapter.sourceID, service: service)
        try await wait { !store.busy }
        let oldBooks = store.books, oldCategories = store.categories, oldSelected = store.selected
        let filter = try XCTUnwrap(store.categories.first { $0.isFilter })
        store.applyFilter(filter, value: try XCTUnwrap(filter.filter?.choices.last), service: service)
        try await wait { !store.busy }
        XCTAssertNotNil(store.message); XCTAssertNil(store.feedback)
        XCTAssertEqual(store.books, oldBooks); XCTAssertEqual(store.categories, oldCategories); XCTAssertEqual(store.selected, oldSelected)
        let successfulAdapter = try LegadoBookSource(source: filterSource(), transport: transport)
        await service.configure(sources: [successfulAdapter])
        store.open(sourceID: successfulAdapter.sourceID, service: service)
        try await wait { !store.busy }
        let beforeFailure = store.books, beforeCategories = store.categories
        let nextFilter = try XCTUnwrap(store.categories.first { $0.isFilter })
        await transport.fail(true)
        store.applyFilter(nextFilter, value: try XCTUnwrap(nextFilter.filter?.choices.last), service: service)
        try await wait { !store.busy }
        XCTAssertNotNil(store.message); XCTAssertNil(store.feedback)
        XCTAssertEqual(store.books, beforeFailure); XCTAssertEqual(store.categories, beforeCategories)
    }
    @MainActor func testCancelBeforeConfirmedFilterTaskStartsDoesNotExecuteActionOrChangeSourceVariable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try LegadoPersistentState(sourceID: "filter-cancel", accountID: "reader", libraryProfile: "tests", directory: directory, vault: DiscoveryFilterVault())
        let transport = DiscoveryFilterTransport(), adapter = try LegadoBookSource(source: filterSource(), transport: transport, state: state)
        let (service, root) = try await makeService([adapter]); defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineDiscoveryStore(); store.open(sourceID: adapter.sourceID, service: service)
        try await wait { !store.busy }
        let before = try state.getVariable("source:variable"), books = store.books
        let filter = try XCTUnwrap(store.categories.first { $0.isFilter })
        let value = try XCTUnwrap(filter.filter?.choices.last)
        store.applyFilter(filter, value: value, service: service); store.cancel()
        // This queued operation has not crossed its explicit cancellation check.
        let pending = Task { try await adapter.applyDiscoveryFilter(category: filter, value: value) }; pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled filter action must not run") } catch is CancellationError { }
        XCTAssertEqual(try state.getVariable("source:variable"), before); XCTAssertEqual(store.books, books)
        XCTAssertNil(store.feedback); XCTAssertFalse(store.busy)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
    }
    func testStaticAndJSONExploreCategoriesPreserveRequestDescriptorsAndBounds() throws {
        let staticRows = try SourceDiscoveryCategory.parse("排行榜::/rank?page={{page}}&&推荐::/hot\n登录::@js:java.toast('已打开')")
        XCTAssertEqual(staticRows.map(\.title), ["排行榜", "推荐", "登录"])
        XCTAssertEqual(staticRows[0].request, "/rank?page={{page}}")
        XCTAssertEqual(try SourceDiscoveryCategory.parse(" 榜单 :: /rank &&榜单::/rank").count, 1)
        let json = "[{\"title\":\"分组\",\"url\":\"\"},{\"title\":\"热门\",\"url\":\"/hot,{\\\"method\\\":\\\"POST\\\"}\"}]"
        XCTAssertEqual(try SourceDiscoveryCategory.parse(json).first(where: \.readable)?.request, "/hot,{\"method\":\"POST\"}")
        XCTAssertTrue(try XCTUnwrap(SourceDiscoveryCategory.parse("[{\"title\":\"分类说明\"}]").first).isHeader)
        XCTAssertThrowsError(try SourceDiscoveryCategory.parse(String(repeating: "x", count: 512 * 1024 + 1)))
    }
    func testJSONHeadingsAllowMissingNullAndBlankURLsWithoutDiscardingRoutableCategories() throws {
        let rows: [[String: Any]] = [
            [:], ["style": ["layout_flexBasisPercent": 1]], ["title": NSNull(), "style": NSNull()],
            ["title": "小说分组", "style": ["layout_wrapBefore": true]],
            ["title": "分类说明", "url": NSNull()], ["title": "排行榜说明", "url": " \n"],
            ["title": "有效榜单", "url": "/rank?page={{page}}", "style": ["layout_flexGrow": 1]]
        ]
        let categories = try SourceDiscoveryCategory.parse(String(decoding: JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
        XCTAssertEqual(categories.map(\.title), ["小说分组", "分类说明", "排行榜说明", "有效榜单"])
        XCTAssertEqual(categories.map(\.isHeader), [true, true, true, false])
        XCTAssertEqual(categories.filter(\.readable).map(\.request), ["/rank?page={{page}}"])
    }
    func testExploreCategoryPrimitiveErrorsAnd512EntryBoundaryRemainControlled() throws {
        for invalid in ["[1]", "[{\"title\":7}]", "[{\"title\":{}}]", "[{\"title\":\"标题\",\"url\":false}]", "[{\"title\":\"标题\",\"url\":{}}]"] {
            XCTAssertThrowsError(try SourceDiscoveryCategory.parse(invalid))
        }
        let rows = (0..<512).map { ["title": "分类说明\($0)"] }
        let atLimit = try JSONSerialization.data(withJSONObject: rows)
        XCTAssertEqual(try SourceDiscoveryCategory.parse(String(decoding: atLimit, as: UTF8.self)).count, 512)
        let beyondLimit = try JSONSerialization.data(withJSONObject: rows + [["title": "超出限制"]])
        XCTAssertThrowsError(try SourceDiscoveryCategory.parse(String(decoding: beyondLimit, as: UTF8.self)))
        XCTAssertThrowsError(try SourceDiscoveryCategory.parse(String(repeating: "x", count: 2049)))
        XCTAssertThrowsError(try SourceDiscoveryCategory.parse("https://fixture.test/" + String(repeating: "x", count: 64 * 1024)))
    }
    func testPlainTextHeadingsNeverBecomeRelativeURLsAndDirectHTTPSEndpointsRemainCompatible() throws {
        let single = try XCTUnwrap(SourceDiscoveryCategory.parse("仅为分类说明").first)
        XCTAssertTrue(single.isHeader); XCTAssertFalse(single.readable); XCTAssertEqual(single.request, "")
        let categories = try SourceDiscoveryCategory.parse("分组标题&&空栏目:: \n榜单::/rank?page={{page}}")
        XCTAssertEqual(categories.map(\.isHeader), [true, true, false])
        XCTAssertEqual(categories.first(where: \.readable)?.title, "榜单")
        for endpoint in ["https://fixture.test/rank?page={{page}}", "http://fixture.test/rank"] {
            let category = try XCTUnwrap(SourceDiscoveryCategory.parse(endpoint).first)
            XCTAssertEqual(category.title, "全部"); XCTAssertEqual(category.request, endpoint); XCTAssertTrue(category.readable)
        }
    }
    @MainActor func testDynamicMixedHeadingsSelectFirstRouteAndSelectingHeaderMakesNoRequest() async throws {
        let transport = DiscoveryFixtureTransport()
        let script = "@js:JSON.stringify([{}, {style:{layout_flexBasisPercent:1}}, {title:'小说分组'}, {title:'分类说明',url:null}, {title:'空栏目',url:' '}, {title:'有效榜单',url:'/rank?page={{page}}'}])"
        let adapter = try LegadoBookSource(source: source(explore: script), transport: transport)
        let (service, root) = try await makeService([adapter]); defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineDiscoveryStore(); store.open(sourceID: adapter.sourceID, service: service)
        try await wait { !store.busy }
        XCTAssertEqual(store.categories.map(\.title), ["小说分组", "分类说明", "空栏目", "有效榜单"])
        XCTAssertEqual(store.selected?.title, "有效榜单"); XCTAssertEqual(store.books.first?.title, "榜单作品1")
        XCTAssertNil(store.message)
        store.select(try XCTUnwrap(store.categories.first), service: service)
        XCTAssertEqual(store.selected?.title, "有效榜单"); XCTAssertEqual(store.books.first?.title, "榜单作品1"); XCTAssertFalse(store.busy)
        let requests = await transport.requests; XCTAssertEqual(requests.map { $0.url?.path }, ["/rank"])
        for category in ["", "全部"] {
            let page = try await adapter.discover(category: category, page: 1)
            XCTAssertEqual(page.books.first?.title, "榜单作品1")
        }
        let allRequests = await transport.requests; XCTAssertTrue(allRequests.allSatisfy { $0.url?.path == "/rank" })
    }
    @MainActor func testAllHeadingsShowExplanationAndNeitherDefaultDiscoveryNorHeaderSelectionRequestsHTTP() async throws {
        let transport = DiscoveryFixtureTransport()
        let adapter = try LegadoBookSource(source: source(explore: "@js:JSON.stringify([{title:'小说分组'}, {title:'分类说明',url:null}, {title:'空栏目',url:''}])"), transport: transport)
        let (service, root) = try await makeService([adapter]); defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineDiscoveryStore(); store.open(sourceID: adapter.sourceID, service: service)
        try await wait { !store.busy }
        XCTAssertEqual(store.categories.count, 3); XCTAssertNil(store.selected); XCTAssertTrue(store.books.isEmpty)
        XCTAssertTrue(store.message?.contains("分类说明") == true)
        store.select(try XCTUnwrap(store.categories.first), service: service)
        XCTAssertNil(store.selected); XCTAssertFalse(store.busy)
        for category in ["", "全部"] {
            let page = try await adapter.discover(category: category, page: 1)
            XCTAssertTrue(page.books.isEmpty); XCTAssertNil(page.nextPage)
        }
        let plainTextAdapter = try LegadoBookSource(source: source(explore: "只有分类说明，没有请求地址"), transport: transport)
        let plainTextPage = try await plainTextAdapter.discover(category: "全部", page: 1)
        XCTAssertTrue(plainTextPage.books.isEmpty)
        await service.configure(sources: [plainTextAdapter])
        store.open(sourceID: plainTextAdapter.sourceID, service: service)
        try await wait { !store.busy }
        XCTAssertEqual(store.categories.first?.title, "只有分类说明，没有请求地址")
        XCTAssertNil(store.selected); XCTAssertTrue(store.books.isEmpty)
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testDynamicExploreRunsQuickJSAndHTTPThenParsesRealRuleExploreAcrossPages() async throws {
        let transport = DiscoveryFixtureTransport()
        let adapter = try LegadoBookSource(source: source(explore: "@js:JSON.stringify([JSON.parse(java.ajax('https://discovery.fixture/categories'))])"), transport: transport)
        let categories = try await adapter.discoveryCategories()
        XCTAssertEqual(categories.map(\.title), ["动态榜单"])
        let first = try await adapter.discover(category: categories[0].request, page: 1)
        XCTAssertEqual(first.books.first?.title, "榜单作品1"); XCTAssertEqual(first.books.first?.summary, "分类真实解析")
        XCTAssertEqual(first.books.first?.coverURL, "https://discovery.fixture/cover.png"); XCTAssertEqual(first.nextPage, 2)
        let second = try await adapter.discover(category: categories[0].request, page: 2)
        XCTAssertEqual(second.books.first?.title, "榜单作品2"); XCTAssertNotEqual(first.books.first?.id, second.books.first?.id)
        let exhausted = try await adapter.discover(category: categories[0].request, page: 3)
        XCTAssertTrue(exhausted.books.isEmpty); XCTAssertNil(exhausted.nextPage)
        let requests = await transport.requests; XCTAssertEqual(requests.map { $0.url?.path }, ["/categories", "/rank", "/rank", "/rank"])
    }
    func testPureActionDiscoveryCategoryShowsFeedbackWithoutInventingANetworkURL() async throws {
        let transport = DiscoveryFixtureTransport()
        let adapter = try LegadoBookSource(source: source(explore: "登录::@js:java.toast('已打开登录栏目')"), transport: transport)
        let categories = try await adapter.discoveryCategories()
        let page = try await adapter.discover(category: categories[0].request, page: 1)
        XCTAssertTrue(page.books.isEmpty); XCTAssertNil(page.nextPage)
        XCTAssertEqual(page.feedback, "已打开登录栏目")
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
        let (service, root) = try await makeService([adapter]); defer { try? FileManager.default.removeItem(at: root) }
        let aggregate = try await service.discover(category: categories[0].request, page: 1, subscribed: [adapter.sourceID])
        XCTAssertEqual(aggregate.feedback, "已打开登录栏目"); XCTAssertFalse(aggregate.hasPartialFailures); XCTAssertNil(aggregate.nextPage)
    }
    func testExactMatchingUsesWholeNormalizedTitleOrAuthor() {
        XCTAssertTrue(BookSearchMatching.exact("  山 间 来 信\n", title: "山间来信", author: "作者"))
        XCTAssertTrue(BookSearchMatching.exact("ABC", title: "ＡＢＣ", author: "作者"))
        XCTAssertTrue(BookSearchMatching.exact("作者", title: "别的作品", author: "作者"))
        XCTAssertFalse(BookSearchMatching.exact("山间", title: "山间来信", author: "作者"))
        XCTAssertFalse(BookSearchMatching.exact("", title: "", author: ""))
    }
    @MainActor func testExactSearchFiltersEveryPageWithoutLosingLaterMatchesAndHonorsSelectedSource() async throws {
        let a = SearchSelectionFixture("a"), b = SearchSelectionFixture("b")
        let (service, root) = try await makeService([a, b]); defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineSearchStore()
        store.search("山间来信", service: service, debounce: false, exactMatch: true, sourceIDs: ["b"])
        try await wait { !store.busy }; XCTAssertEqual(store.results.count, 1)
        XCTAssertEqual(store.results.first?.source?.sourceID, "b")
        store.more(service: service); try await wait { !store.busy }
        XCTAssertEqual(store.results.count, 1); XCTAssertEqual(store.nextPage, 3)
        store.more(service: service); try await wait { !store.busy }
        XCTAssertEqual(store.results.count, 2); XCTAssertNil(store.nextPage)
        let callsA = await a.searchCalls, callsB = await b.searchCalls
        XCTAssertEqual(callsA, 0); XCTAssertEqual(callsB, 3)
        store.search("山间来信", service: service, debounce: false, exactMatch: false, sourceIDs: ["b"])
        try await wait { !store.busy }; XCTAssertEqual(store.results.count, 2)
    }
    @MainActor func testChangingDiscoveryCategoryRejectsLateResultsAndRefreshRequestsAgain() async throws {
        let source = SearchSelectionFixture("a"), (service, root) = try await makeService([source])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnlineDiscoveryStore(); store.open(sourceID: "a", service: service)
        try await wait { !store.categories.isEmpty }
        store.select(store.categories[1], service: service)
        try await wait { !store.busy }; XCTAssertEqual(store.books.map(\.title), ["new"])
        try await Task.sleep(for: .milliseconds(120)); XCTAssertEqual(store.books.map(\.title), ["new"])
        store.refresh(service: service); try await wait { !store.busy }
        XCTAssertEqual(store.selected?.title, "新分类"); XCTAssertEqual(store.books.map(\.title), ["new"])
    }
    func testDetailRefreshFetchesMetadataAndCatalogAgain() async throws {
        let source = SearchSelectionFixture("a"), (service, root) = try await makeService([source])
        defer { try? FileManager.default.removeItem(at: root) }
        let search = try await service.search(query: "作品", page: 1)
        let book = try XCTUnwrap(search.books.first)
        let first = try await service.details(book), second = try await service.details(book)
        XCTAssertEqual(first.0.summary, "刷新版本1"); XCTAssertEqual(second.0.summary, "刷新版本2")
        XCTAssertEqual(first.1.map(\.id), second.1.map(\.id))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Discovery/search did not finish")
    }
}
