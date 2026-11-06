import XCTest
@testable import Yueshan

private actor SourceConcurrencyProbe {
    var active = 0, maximum = 0
    func run() async throws {
        active += 1; maximum = max(maximum,active); defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15))
    }
}
private struct SearchProbeSource: BookSource {
    let sourceID: String
    let probe: SourceConcurrencyProbe
    var fails = false
    func search(query: String, page: Int) async throws -> BookSearchPage {
        try await probe.run(); if fails { throw ContentFailure.timedOut }
        let reference = SourceBookReference(sourceID: sourceID, nativeBookID: "native", provider: sourceID, bookURL: "https://reader.test")
        return .init(books: [.init(id: "remote-" + reference.id, title: "同名作品", author: "同名作者", summary: query, source: reference, addedAt: Date())], nextPage: page == 1 ? 3 : nil)
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { book }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] { [.init(id: sourceID + "-chapter", bookID: book.id, nativeChapterID: "1", title: "第一章", order: 0, access: .readable)] }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument { .init(chapterID: chapter.id, paragraphs: [sourceID + " 的真实测试链路正文"]) }
}
private actor NativeJSONTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path, object: Any
        if path == "/search" { object = ["books":[["id":"b","title":"山间来信","author":"原创作者"]],"nextPage":NSNull()] }
        else if path == "/books/b" { object = ["id":"b","title":"山间来信","author":"原创作者","summary":"详情"] }
        else if path == "/books/b/chapters" { object = [["id":"one","title":"第一章"],["id":"two","title":"第二章"]] }
        else { object = ["chapterID":"one","paragraphs":["正文来自可运行的 JSON 适配器。"]] }
        return (try JSONSerialization.data(withJSONObject: object),HTTPURLResponse(url: request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}

final class ConfigurableSourceTests: XCTestCase {
    private func source() throws -> DemoSource {
        let endpoints = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeSourceRules.example))
        let row: [String:Any] = ["bookSourceName":"原创 JSON 源","bookSourceUrl":"https://reader.test","adapter":"json-v1","endpoints":endpoints]
        return try XCTUnwrap(SourcePackages.parse(JSONSerialization.data(withJSONObject: row), existing: []).sources.first)
    }
    func testSourcePackageRoundtripRetainsRulesRejectsVersionsAndRemovesSecrets() throws {
        let source = try source(), bytes = try SourcePackages.export([source])
        let restored = try SourcePackages.parse(bytes, existing: [])
        XCTAssertEqual(try SourcePackages.rules(source), try SourcePackages.rules(restored.sources[0]))
        XCTAssertEqual(try SourcePackages.parse(bytes, existing: [source]).duplicates,1)
        XCTAssertThrowsError(try SourcePackages.parse(Data("{\"format\":\"yueshan-sources\",\"version\":2,\"sources\":[]}".utf8), existing: []))
        let legacy = Data("{\"bookSourceName\":\"旧规则\",\"bookSourceUrl\":\"https://legacy.test\",\"ruleSearch\":{\"name\":\".title\"},\"headers\":{\"Authorization\":\"secret\"}}".utf8)
        let unsupported = try SourcePackages.parse(legacy, existing: []).sources[0]
        XCTAssertThrowsError(try SourcePackages.rules(unsupported))
        let exported = String(decoding: try SourcePackages.export([unsupported]), as: UTF8.self)
        XCTAssertTrue(exported.contains("ruleSearch")); XCTAssertFalse(exported.contains("secret")); XCTAssertFalse(exported.contains("Authorization"))
    }
    func testNativeJSONFourStepsEncodeQueryAndVerifyChapterIdentity() async throws {
        let transport = NativeJSONTransport(), adapter = try ConfigurableBookSource(source: source(), transport: transport)
        let result = try await adapter.search(query: "山间 & ?", page: 1)
        let book = try XCTUnwrap(result.books.first), details = try await adapter.details(for: book)
        let chapters = try await adapter.chapters(for: details), document = try await adapter.document(for: chapters[0], book: details)
        XCTAssertEqual(document.chapterID, chapters[0].id); XCTAssertEqual(chapters.count, 2)
        let requests = await transport.requests
        XCTAssertEqual(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "山间 & ?")
        do { _ = try await adapter.document(for: chapters[1], book: details); XCTFail("Wrong chapter response") } catch { XCTAssertEqual(error as? ContentFailure,.invalidResponse) }
    }
    func testMultiSourceLimitsConcurrencyPreservesCandidatesAndPartialFailure() async throws {
        let probe = SourceConcurrencyProbe(), coordinator = MultiSourceSearch()
        let sources = (0..<7).map { SearchProbeSource(sourceID: String($0), probe: probe, fails: $0 == 3) }
        let page = try await coordinator.search("原书", page: 1, sources: sources, limit: 2)
        XCTAssertEqual(page.books.count, 6); XCTAssertEqual(Set(page.books.map(\.id)).count,6)
        XCTAssertTrue(page.hasPartialFailures); XCTAssertEqual(page.sourceReports.count,7)
        let max = await probe.maximum; XCTAssertLessThanOrEqual(max,2)
        let next = try await coordinator.search("原书", page: 2, sources: sources, limit: 2)
        XCTAssertEqual(next.books.count,6)
    }
    func testOnlineServiceRoutesDetailsAndContentToSelectedProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = OnlineReadingService(cache: try RecentChapterCache(directory: root)), probe = SourceConcurrencyProbe()
        await service.configure(sources: [SearchProbeSource(sourceID:"a",probe:probe),SearchProbeSource(sourceID:"b",probe:probe)])
        let page = try await service.search(query:"作品",page:1), book = try XCTUnwrap(page.books.first(where: { $0.source?.sourceID == "b" }))
        let (details,catalog) = try await service.details(book), document = try await service.document(book: details,chapter:catalog[0])
        XCTAssertTrue(document.paragraphs[0].text.hasPrefix("b"))
    }
    func testDiagnosticStepsAndBatchResultsComeFromExecutionAndCancellationPropagates() async throws {
        let probe = SourceConcurrencyProbe(), source = SearchProbeSource(sourceID:"diagnostic",probe:probe)
        let result = try await SourceDiagnostics.run(source:source,query:"原创",through:.content)
        XCTAssertEqual(result.map(\.step),["搜索","详情","目录","正文"])
        XCTAssertTrue(result.allSatisfy { $0.status == "成功" }); XCTAssertGreaterThan(result.last?.count ?? 0,0)
        let failures = try await SourceDiagnostics.batch(sources:[source,SearchProbeSource(sourceID:"failure",probe:probe,fails:true)],query:"原创",concurrency:2,timeout:5)
        XCTAssertTrue(failures.contains { $0.sourceID == "failure" && $0.status == "超时" && $0.step == "搜索" })
        let cancelled = Task { try await SourceDiagnostics.batch(sources:[source],query:"取消",concurrency:1,timeout:5) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled diagnostics") } catch is CancellationError {}
    }
    @MainActor func testImportedSourceConfigurationSurvivesDatabaseRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!
        defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:domain) }
        let library = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root))
        await library.bootstrapProductionIfNeeded()
        let demo = FeatureDemoStore(seedDemoData:false); demo.connectReader(library)
        let original = try source(), imported = SourceImportPreview(sources:[original],duplicates:0,invalid:0)
        XCTAssertEqual(demo.confirmSourceImport(imported),1)
        let saved = await library.flushPendingWrites(); XCTAssertTrue(saved)
        let reopened = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root))
        await reopened.bootstrapProductionIfNeeded()
        let restored = try XCTUnwrap(reopened.sources.first { $0.id == original.id })
        XCTAssertEqual(try SourcePackages.rules(restored),try SourcePackages.rules(original))
    }
}
