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
    func testStaticAndJSONExploreCategoriesPreserveRequestDescriptorsAndBounds() throws {
        let staticRows = try SourceDiscoveryCategory.parse("排行榜::/rank?page={{page}}&&推荐::/hot\n登录::@js:java.toast('已打开')")
        XCTAssertEqual(staticRows.map(\.title), ["排行榜", "推荐", "登录"])
        XCTAssertEqual(staticRows[0].request, "/rank?page={{page}}")
        XCTAssertEqual(try SourceDiscoveryCategory.parse(" 榜单 :: /rank &&榜单::/rank").count, 1)
        let json = "[{\"title\":\"分组\",\"url\":\"\"},{\"title\":\"热门\",\"url\":\"/hot,{\\\"method\\\":\\\"POST\\\"}\"}]"
        XCTAssertEqual(try SourceDiscoveryCategory.parse(json).first?.request, "/hot,{\"method\":\"POST\"}")
        XCTAssertThrowsError(try SourceDiscoveryCategory.parse("[{\"title\":\"缺少地址\"}]"))
        XCTAssertThrowsError(try SourceDiscoveryCategory.parse(String(repeating: "x", count: 512 * 1024 + 1)))
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
