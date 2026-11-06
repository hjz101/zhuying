import XCTest
@testable import Zhuying

final class ContentToolsTests: XCTestCase {
    func testChineseSubstringsPunctuationUnicodeOffsetsAndEveryOccurrence() async throws {
        let index = try TextSearchIndex()
        let text = "👩🏽‍🚀山间来信，来信。e\u{301}星光"
        let doc = ChapterDocument(chapterID: "chapter", paragraphs: [text])
        try await index.replace([.init(bookID: "book", document: doc)])
        let hits = try await index.search("来信")
        XCTAssertEqual(hits.count, 2); XCTAssertEqual(hits[0].offset, (text as NSString).range(of: "来信").location)
        let long = try await index.search("山间来信")
        XCTAssertEqual(long.count, 1)
        let punctuation = try await index.search("，")
        XCTAssertEqual(punctuation.count, 1)
        let unicode = try await index.search("e\u{301}")
        XCTAssertEqual(unicode.count, 1)
    }
    func testReindexRemovesChangedTextAndOmittedCacheAndPersistsAcrossRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let index = try TextSearchIndex(url: url)
        try await index.replace([.init(bookID: "b", document: .init(chapterID: "c", paragraphs: ["旧正文", ReaderInlineImage.prefix + "internal"]))])
        let reopened = try TextSearchIndex(url: url)
        let original = try await reopened.search("旧正文"); XCTAssertEqual(original.count, 1)
        let resource = try await reopened.search("internal"); XCTAssertTrue(resource.isEmpty)
        try await reopened.replace([.init(bookID: "b", document: .init(chapterID: "c", paragraphs: ["新正文"]))])
        let old = try await reopened.search("旧正文"); XCTAssertTrue(old.isEmpty)
        try await reopened.replace([])
        let cleared = try await reopened.search("新正文"); XCTAssertTrue(cleared.isEmpty)
    }
    func testReadingClockIgnoresBackgroundIdleDuplicateAndWallClockChanges() {
        var clock = ReadingActivityClock(); let start = Date(timeIntervalSince1970: 100000)
        func tick(_ time: Double, active: Bool = true, interacted: Bool = false, wall: Double? = nil) -> ActivitySession? {
            clock.advance(bookID: "book", active: active, interacted: interacted, wall: start.addingTimeInterval(wall ?? time), uptime: time)
        }
        XCTAssertNil(tick(0, interacted: true)); XCTAssertEqual(tick(5)?.seconds, 5)
        XCTAssertNil(tick(5)); XCTAssertEqual(tick(10, active: false)?.seconds, 5)
        XCTAssertNil(tick(15, active: false)); XCTAssertNil(tick(20, interacted: true))
        for second in stride(from: 25.0, through: 80, by: 5) { XCTAssertEqual(tick(second)?.seconds, 5) }
        XCTAssertNil(tick(85)); XCTAssertNil(tick(90, interacted: true)); XCTAssertEqual(tick(95)?.seconds, 5)
        XCTAssertNil(tick(100, wall: 1000)); XCTAssertNil(tick(200, wall: 1100))
    }
    func testReadingClockSplitsCrossMidnightAndBookSwitchWithoutDoubleCounting() {
        var clock = ReadingActivityClock(); let midnight = Date(timeIntervalSince1970: 86400)
        _ = clock.advance(bookID: "first", active: true, interacted: true, wall: midnight.addingTimeInterval(-2), uptime: 0)
        let first = clock.advance(bookID: "second", active: true, interacted: true, wall: midnight.addingTimeInterval(3), uptime: 5)
        XCTAssertEqual(first?.bookID, "first"); XCTAssertEqual(first?.seconds, 5)
        let before = DateInterval(start: midnight.addingTimeInterval(-86400), end: midnight)
        XCTAssertEqual(first?.duration(in: before), 2)
        let second = clock.advance(bookID: nil, active: false, interacted: false, wall: midnight.addingTimeInterval(8), uptime: 10)
        XCTAssertEqual(second?.bookID, "second"); XCTAssertEqual(second?.seconds, 5)
    }
    @MainActor func testRealActivitySubscriptionsAndUnreadUpdatesPersistWithoutRepeatedNotifications() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "updates-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!
        defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:domain) }
        let provider = UpdateCatalogSource(), service = OnlineReadingService(cache:try RecentChapterCache(directory:root.appendingPathComponent("cache")))
        await service.configure(source:provider)
        let backend = try ProductionLibraryPersistence(directory:root.appendingPathComponent("db"))
        let library = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:backend,onlineService:service)
        await library.bootstrapProductionIfNeeded()
        library.updateSources([.init(id:provider.sourceID,name:"更新测试源",detail:"原创测试",url:"https://updates.test")])
        let record = try await provider.search(query:"作品",page:1).books[0]
        let originalCatalog = try await provider.chapters(for:record)
        let presentation = try await library.registerRemoteBook(record,chapters:originalCatalog)
        _ = library.toggleFavorite(presentation); library.subscribe(sourceID:provider.sourceID,enabled:true)
        await provider.addChapter()
        let first = try await library.checkSubscribedUpdates(); XCTAssertEqual(first.added,1)
        let updated = try XCTUnwrap(library.books.first { $0.id == record.id }); XCTAssertEqual(library.updateCount(updated),1)
        let repeated = try await library.checkSubscribedUpdates(); XCTAssertEqual(repeated.added,0); XCTAssertEqual(library.updateCount(updated),1)
        let request = try library.chapterRequest(for:updated,chapter:2), doc = try await provider.document(for:request.chapter,book:record)
        XCTAssertTrue(library.confirmChapter(updated,chapter:2,document:doc,anchor:.init()))
        XCTAssertEqual(library.updateCount(updated),0)
        let date = Date(timeIntervalSince1970:100000)
        library.trackReading(updated.id,interacted:true,now:date,uptime:0)
        library.trackReading(nil,now:date.addingTimeInterval(5),uptime:5)
        _ = await library.flushPendingWrites()
        let reopened = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root.appendingPathComponent("db")))
        await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.subscribedSourceIDs,[provider.sourceID]); XCTAssertEqual(reopened.activitySessions.reduce(0) { $0 + $1.seconds },5)
        XCTAssertEqual(reopened.updateCount(updated),0)
        library.subscribe(sourceID:provider.sourceID,enabled:false)
        let cancelled = try await library.checkSubscribedUpdates(); XCTAssertEqual(cancelled.checked,0)
    }
    @MainActor func testListeningTransitionDoesNotAlsoCountAsReadingTime() {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let library = LibraryStore(books:[],defaults:defaults,seedDemoData:false), date = Date(timeIntervalSince1970:100000)
        library.trackReading("book",interacted:true,now:date,uptime:0)
        library.narrationPlaybackChanged(true,now:date.addingTimeInterval(5),uptime:5)
        library.trackReading("book",now:date.addingTimeInterval(10),uptime:10)
        library.narrationPlaybackChanged(false,now:date.addingTimeInterval(15),uptime:15)
        library.trackReading(nil,now:date.addingTimeInterval(20),uptime:20)
        XCTAssertEqual(library.activitySessions.reduce(0){$0 + $1.seconds},10)
    }
}

private actor UpdateCatalogSource: BookSource {
    nonisolated let sourceID = "updates"
    private var count = 2
    func addChapter() { count += 1 }
    func search(query: String,page: Int) async throws -> BookSearchPage {
        .init(books:[.init(id:"remote-updates",title:"更新测试作品",author:"原创作者",summary:"",source:.init(sourceID:sourceID,nativeBookID:"test",provider:"更新测试",bookURL:"https://updates.test"),addedAt:Date())],nextPage:nil)
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { book }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] { (0..<count).map { .init(id:book.id + String($0),bookID:book.id,nativeChapterID:String($0),title:"第\($0 + 1)章 更新",order:$0,access:.readable) } }
    func document(for chapter: ChapterRecord,book: LibraryBookRecord) async throws -> ChapterDocument { .init(chapterID:chapter.id,paragraphs:["新章节的真实测试正文，\(chapter.title)。"]) }
}
