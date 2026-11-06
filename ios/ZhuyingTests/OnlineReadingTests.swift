import XCTest
@testable import Zhuying

private actor OnlineFixtureSource: BookSource {
    nonisolated let sourceID = "shushan"
    var failing = false
    var expired = false
    var calls: [String] = []
    var revision = ""
    func updateBody(_ value: String) { revision = value }
    func fail(_ value: Bool) { failing = value }
    func expire() { expired = true }
    func search(query: String, page: Int) async throws -> BookSearchPage {
        calls.append("search-\(query)-\(page)")
        if expired { throw ContentFailure.authenticationRequired }
        if query == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
        if failing { throw ContentFailure.unavailable }
        let record = Self.book(query)
        return .init(books: page == 1 ? [record, record] : [record, Self.book(query + "2")], nextPage: page == 1 ? 2 : nil)
    }
    nonisolated static func book(_ id: String = "book") -> LibraryBookRecord {
        .init(id: "remote-\(id)", title: id, author: "作者", summary: "简介", source: .init(sourceID: "shushan", nativeBookID: id, provider: "提供方", bookURL: "https://book.test/\(id)", origin: "https://source.test"), addedAt: Date())
    }
    nonisolated static func catalog(_ book: LibraryBookRecord) -> [ChapterRecord] {
        (0..<5).map { .init(id: book.id + "-\($0)", bookID: book.id, nativeChapterID: "\($0)", title: "第\($0 + 1)章", order: $0, access: $0 == 4 ? .restricted : .readable, requestParameters: ["version": "12"]) }
    }
    func details(for book: LibraryBookRecord) -> LibraryBookRecord { book }
    func chapters(for book: LibraryBookRecord) -> [ChapterRecord] { Self.catalog(book) }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        calls.append(chapter.id)
        if failing { throw ContentFailure.unavailable }
        return .init(chapterID: chapter.id, paragraphs: ["\(chapter.title)的真实测试正文。位置与作品必须对应。" + revision, "第二段👩🏽‍🚀。"])
    }
}

final class OnlineReadingTests: XCTestCase {
    private final class CacheClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance() { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(2) }
    }
    func testExpiredCacheRefreshesChangedContentButRemainsReadableDuringNetworkFailureAndLogout() async throws {
        let clock = CacheClock(), cache = try RecentChapterCache(directory: root(), maximumAge: 1, now: { clock.now() })
        let source = OnlineFixtureSource(), service = OnlineReadingService(cache: cache)
        let book = OnlineFixtureSource.book(), chapter = OnlineFixtureSource.catalog(book)[0]
        let old = ChapterDocument(chapterID: chapter.id, paragraphs: ["上次缓存的旧版本正文。"])
        let key = RecentChapterCache.fingerprint(book: book, chapter: chapter)
        _ = try await cache.save(old, bookID: book.id, fingerprint: key, protecting: chapter.id)
        await service.configure(source: source)
        let freshHit = try await service.document(book: book, chapter: chapter); XCTAssertEqual(freshHit, old)
        clock.advance(); await source.fail(true)
        let offline = try await service.document(book: book, chapter: chapter); XCTAssertEqual(offline, old)
        await source.fail(false)
        let refreshed = try await service.document(book: book, chapter: chapter); XCTAssertNotEqual(refreshed.version, old.version)
        clock.advance(); await service.configure(source: nil, failure: .sourceDisabled)
        let signedOut = try await service.document(book: book, chapter: chapter); XCTAssertEqual(signedOut, refreshed)
        var changed = chapter; changed.requestParameters["revision"] = "different"
        do { _ = try await service.document(book: book, chapter: changed); XCTFail("Different request identity cannot reuse stale text") } catch {}
    }
    private final class FailingCacheWriter: AtomicFileWriting, @unchecked Sendable {
        var rejectManifest = false
        func write(_ data: Data, to url: URL) throws {
            if rejectManifest && url.lastPathComponent == "cache.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }
    func testCacheFailedCommitAndClearKeepOfflineChapterAndUsageCountsActualOrphanBytes() async throws {
        let root = try root(), writer = FailingCacheWriter(), cache = try RecentChapterCache(directory: root, writer: writer)
        let first = ChapterDocument(chapterID: "first", paragraphs: ["已提交正文必须保留。"])
        _ = try await cache.save(first, bookID: "book", fingerprint: "v1", protecting: "first")
        let baseline = await cache.usage()
        writer.rejectManifest = true
        do { _ = try await cache.save(.init(chapterID: "second", paragraphs: ["未提交正文"]), bookID: "book", fingerprint: "v1", protecting: "first"); XCTFail("Injected manifest failure") } catch {}
        do { try await cache.clear(); XCTFail("Failed clear cannot claim success") } catch {}
        let retained = try await cache.document(bookID: "book", chapterID: "first", fingerprint: "v1")
        XCTAssertEqual(retained, first)
        let unchanged = await cache.usage(); XCTAssertEqual(unchanged.bytes, baseline.bytes); XCTAssertEqual(unchanged.chapters, 1)
        let orphan = Data("interrupted staging".utf8)
        try orphan.write(to: root.appendingPathComponent(FileResourceStore.digest(orphan) + ".json"))
        let actual = await cache.usage(); XCTAssertEqual(actual.bytes, baseline.bytes + orphan.count)
        writer.rejectManifest = false
        try await cache.clear()
        let cleared = await cache.usage(); XCTAssertEqual(cleared.bytes, 0); XCTAssertEqual(cleared.chapters, 0)
    }
    @MainActor func testAuthenticationExpirationInvalidatesSourceAndCallsLoginRecovery() async throws {
        let source = OnlineFixtureSource(), service = OnlineReadingService(cache: try RecentChapterCache(directory: root()))
        var expired = false
        await service.setAuthenticationHandler { @MainActor in expired = true }
        await service.configure(source: source); await source.expire()
        do { _ = try await service.search(query: "作品", page: 1); XCTFail("Expired") } catch { XCTAssertEqual(error as? ContentFailure, .authenticationRequired) }
        XCTAssertTrue(expired)
        do { _ = try await service.search(query: "作品", page: 1); XCTFail("Needs login") } catch {}
        let count = await source.calls.count; XCTAssertEqual(count, 1)
    }
    func testDisposableCacheCorruptionIsQuarantinedAndDoesNotPreventReopening() async throws {
        let root = try root()
        try Data("damaged-cache".utf8).write(to: root.appendingPathComponent("cache.json"))
        let cache = try RecentChapterCache(directory: root)
        let usage = await cache.usage(); XCTAssertEqual(usage.chapters, 0)
        let originals = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("cache.damaged-") }
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(originals[0])), Data("damaged-cache".utf8))
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    func testCacheQuotaProtectsCurrentChapterVersionAndSurvivesReopen() async throws {
        let root = try root(), cache = try RecentChapterCache(directory: root, maximumBytes: 10_000, maximumCount: 2)
        let book = OnlineFixtureSource.book(), catalog = OnlineFixtureSource.catalog(book)
        for index in 0..<3 {
            _ = try await cache.save(.init(chapterID: catalog[index].id, paragraphs: ["正文\(index)"]), bookID: book.id,
                                     fingerprint: RecentChapterCache.fingerprint(book: book, chapter: catalog[index]), protecting: catalog[0].id, speculative: index > 0)
        }
        let usage = await cache.usage(); XCTAssertEqual(usage.chapters, 2)
        let reopened = try RecentChapterCache(directory: root)
        let first = try await reopened.document(bookID: book.id, chapterID: catalog[0].id, fingerprint: RecentChapterCache.fingerprint(book: book, chapter: catalog[0]))
        XCTAssertNotNil(first)
        let wrong = try await reopened.document(bookID: "wrong", chapterID: catalog[0].id, fingerprint: RecentChapterCache.fingerprint(book: book, chapter: catalog[0]))
        XCTAssertNil(wrong)
        var changed = catalog[0]; changed.requestParameters["version"] = "new"
        let stale = try await reopened.document(bookID: book.id, chapterID: changed.id, fingerprint: RecentChapterCache.fingerprint(book: book, chapter: changed))
        XCTAssertNil(stale)
        try await reopened.clear(); let cleared = await reopened.usage(); XCTAssertEqual(cleared.bytes, 0)
    }
    func testCachedOfflineHitMissAndPrefetchDoNotAdvanceProgress() async throws {
        let cache = try RecentChapterCache(directory: root()), service = OnlineReadingService(cache: cache), source = OnlineFixtureSource()
        let book = OnlineFixtureSource.book(), chapters = OnlineFixtureSource.catalog(book)
        await service.configure(source: source)
        let document = try await service.document(book: book, chapter: chapters[0])
        await service.prefetchNext(book: book, current: chapters[0], next: chapters[1])
        for _ in 0..<100 { if await source.calls.contains(chapters[1].id) { break }; try await Task.sleep(for: .milliseconds(2)) }
        await service.configure(source: nil, failure: .sourceDisabled)
        let offline = try await service.document(book: book, chapter: chapters[0])
        XCTAssertEqual(offline, document)
        do { _ = try await service.document(book: book, chapter: chapters[3]); XCTFail("Uncached disabled source") }
        catch { XCTAssertEqual(error as? ContentFailure, .sourceDisabled) }
        do { _ = try await service.document(book: book, chapter: chapters[4]); XCTFail("Restricted") }
        catch { XCTAssertEqual(error as? ContentFailure, .restricted) }
    }
    @MainActor func testSearchIgnoresLateQueryAndPaginationFailureKeepsResultsForRetry() async throws {
        let source = OnlineFixtureSource(), service = OnlineReadingService(cache: try RecentChapterCache(directory: root())), store = OnlineSearchStore()
        await service.configure(source: source)
        store.search("slow", service: service, debounce: false)
        try await Task.sleep(for: .milliseconds(10))
        store.search("new", service: service, debounce: false)
        try await wait { !store.busy }
        XCTAssertEqual(store.results.map(\.title), ["new"])
        try await Task.sleep(for: .milliseconds(180)); XCTAssertEqual(store.results.map(\.title), ["new"])
        await source.fail(true); store.more(service: service); try await wait { !store.busy }
        XCTAssertEqual(store.results.count, 1); XCTAssertNotNil(store.message); XCTAssertEqual(store.nextPage, 2)
        await source.fail(false); store.more(service: service); try await wait { !store.busy }
        XCTAssertEqual(store.results.map(\.title), ["new", "new2"]); XCTAssertNil(store.nextPage)
        store.search("  ", service: service, debounce: false); XCTAssertTrue(store.results.isEmpty); XCTAssertFalse(store.busy)
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        XCTFail("Operation did not finish")
    }
    @MainActor func testOpeningOnlineBookSkipsLeadingVolumeAndChapterNavigationSkipsOnlyVolumes() async throws {
        let root = try root(), domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = OnlineReadingService(cache: try RecentChapterCache(directory: root.appendingPathComponent("cache")))
        await service.configure(source: OnlineFixtureSource())
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                   productionPersistence: try ProductionLibraryPersistence(directory: root.appendingPathComponent("db")), onlineService: service)
        await library.bootstrapProductionIfNeeded()
        let record = OnlineFixtureSource.book()
        var catalog = OnlineFixtureSource.catalog(record)
        catalog[0].access = .volume; catalog[2].access = .volume
        let book = try await library.registerRemoteBook(record, chapters: catalog)
        library.read(book)
        XCTAssertEqual(library.reader?.chapter, 1, "A volume heading has no body to load")
        let session = ReadingSessionController(repository: library.chapterRepository(for: book))
        let accepted = await session.load(try library.chapterRequest(for: book, chapter: XCTUnwrap(library.reader?.chapter)))
        XCTAssertTrue(accepted); XCTAssertEqual(session.document?.chapterID, catalog[1].id)
        XCTAssertEqual(library.readableChapterIndex(for: book, startingAt: 2), 3)
        XCTAssertEqual(library.readableChapterIndex(for: book, startingAt: 2, direction: -1), 1)
        XCTAssertNil(library.readableChapterIndex(for: book, startingAt: 0, direction: -1))
        XCTAssertEqual(library.readableChapterIndex(for: book, startingAt: 4), 4, "Restricted content must keep its access explanation")
        _ = library.confirmChapter(book, chapter: 1, document: try XCTUnwrap(session.document), anchor: .init())
        library.read(book); XCTAssertEqual(library.reader?.chapter, 1)
        library.read(book, chapter: 0); XCTAssertEqual(library.reader?.chapter, 1)
        library.reader = nil
        catalog = catalog.map { var chapter = $0; chapter.access = .volume; return chapter }
        let volumeOnly = try await library.registerRemoteBook(record, chapters: catalog)
        library.read(volumeOnly, chapter: 0); XCTAssertNil(library.reader)
    }
    @MainActor func testOnlineProgressUnfavoritedRestartCatalogInsertionAndSourceRemovalKeepHistory() async throws {
        let root = try root(), defaults = UserDefaults(suiteName: "online-tests-\(UUID().uuidString)")!
        let service = OnlineReadingService(cache: try RecentChapterCache(directory: root.appendingPathComponent("cache")))
        await service.configure(source: OnlineFixtureSource())
        let backend = try ProductionLibraryPersistence(directory: root.appendingPathComponent("db"))
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false, productionPersistence: backend, onlineService: service)
        await library.bootstrapProductionIfNeeded()
        let record = OnlineFixtureSource.book(), catalog = OnlineFixtureSource.catalog(record)
        let book = try await library.registerRemoteBook(record, chapters: catalog)
        library.read(book, chapter: 1); XCTAssertNil(library.progress[book.id])
        let session = ReadingSessionController(repository: library.chapterRepository(for: book))
        let loaded = await session.load(try library.chapterRequest(for: book, chapter: 1)); XCTAssertTrue(loaded)
        let document = try XCTUnwrap(session.document)
        _ = library.confirmChapter(book, chapter: 1, document: document, anchor: .init(paragraph: 1, offset: 4))
        _ = try await library.saveBookmark(book, chapter: 1, paragraph: 1, offset: 4, title: "网络书签")
        library.updateSources([]); let flushed = await library.flushPendingWrites(); XCTAssertTrue(flushed)
        var inserted = catalog; inserted.insert(.init(id: "new", bookID: book.id, nativeChapterID: "new", title: "插入", order: 0, access: .readable), at: 0)
        for index in inserted.indices { inserted[index].order = index }
        _ = try await library.registerRemoteBook(record, chapters: inserted)
        XCTAssertEqual(library.progress[book.id]?.chapter, 2)
        let reopened = LibraryStore(books: [], defaults: defaults, seedDemoData: false, productionPersistence: try ProductionLibraryPersistence(directory: root.appendingPathComponent("db")), onlineService: service)
        await reopened.bootstrapProductionIfNeeded()
        XCTAssertTrue(reopened.sources.isEmpty); XCTAssertTrue(reopened.favorites.isEmpty)
        XCTAssertEqual(reopened.progress[book.id]?.chapter, 2); XCTAssertEqual(reopened.bookmarks.count, 1)
        _ = try await reopened.registerRemoteBook(record, chapters: inserted.filter { $0.id != catalog[1].id })
        XCTAssertTrue(reopened.unresolvedBookIDs.contains(book.id)); XCTAssertNil(reopened.progress[book.id])
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("db/library.sqlite"))
        let preserved = try await records.progress(bookID: book.id); XCTAssertEqual(preserved?.chapterID, catalog[1].id)
    }
}


private actor PendingCacheSource: BookSource {
    nonisolated let sourceID = "shushan"
    private var pending: CheckedContinuation<ChapterDocument, Error>?
    func isWaiting() -> Bool { pending != nil }
    func finish(_ chapter: ChapterRecord) { pending?.resume(returning: .init(chapterID: chapter.id, paragraphs: ["清除后才返回的旧请求"])); pending = nil }
    func search(query: String, page: Int) -> BookSearchPage { .init(books: [], nextPage: nil) }
    func details(for book: LibraryBookRecord) -> LibraryBookRecord { book }
    func chapters(for book: LibraryBookRecord) -> [ChapterRecord] { [] }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
}

extension OnlineReadingTests {
    func testExplicitRefreshBypassesFreshCacheAndKeepsOldContentOnFailure() async throws {
        let cache = try RecentChapterCache(directory: root()), service = OnlineReadingService(cache: cache), source = OnlineFixtureSource()
        let book = OnlineFixtureSource.book(), chapter = OnlineFixtureSource.catalog(book)[0]
        await service.configure(source: source)
        let old = try await service.document(book: book, chapter: chapter)
        await source.updateBody("更新的正文")
        let hit = try await service.document(book: book, chapter: chapter)
        XCTAssertEqual(hit, old)
        await source.fail(true)
        do { _ = try await service.refreshDocument(book: book, chapter: chapter); XCTFail("A failed refresh must report its failure") }
        catch { XCTAssertEqual(error as? ContentFailure, .unavailable) }
        let preserved = try await service.cachedDocument(book: book, chapter: chapter)
        XCTAssertEqual(preserved, old)
        await source.fail(false)
        let fresh = try await service.refreshDocument(book: book, chapter: chapter)
        XCTAssertNotEqual(fresh.version, old.version)
        let cached = try await service.document(book: book, chapter: chapter)
        XCTAssertEqual(cached, fresh)
    }

    func testClearingOneBookKeepsOtherBooksAndRejectsLateCacheWrites() async throws {
        let cache = try RecentChapterCache(directory: root()), source = PendingCacheSource(), service = OnlineReadingService(cache: cache)
        let book = OnlineFixtureSource.book(), chapter = OnlineFixtureSource.catalog(book)[0], other = OnlineFixtureSource.book("other")
        let otherChapter = OnlineFixtureSource.catalog(other)[0]
        let otherDocument = ChapterDocument(chapterID: otherChapter.id, paragraphs: ["另一本书的缓存"])
        _ = try await cache.save(otherDocument, bookID: other.id, fingerprint: RecentChapterCache.fingerprint(book: other, chapter: otherChapter), protecting: nil)
        await service.configure(source: source)
        let pending = Task { try await service.document(book: book, chapter: chapter) }
        for _ in 0..<1000 { if await source.isWaiting() { break }; try await Task.sleep(for: .milliseconds(1)) }
        let waiting = await source.isWaiting(); XCTAssertTrue(waiting)
        try await service.clearCache(bookID: book.id)
        await source.finish(chapter); _ = try await pending.value
        let removed = try await service.cachedDocument(book: book, chapter: chapter)
        let retained = try await service.cachedDocument(book: other, chapter: otherChapter)
        XCTAssertNil(removed); XCTAssertEqual(retained, otherDocument)
    }

    func testRefreshingDownloadedChapterPersistsNewVersionAndClearOnlyRemovesTemporaryCache() async throws {
        let directory = try root(), downloads = try OfflineDownloadStore(directory: directory.appendingPathComponent("downloads"))
        let cache = try RecentChapterCache(directory: directory.appendingPathComponent("cache")), service = OnlineReadingService(cache: cache, downloads: downloads)
        let book = OnlineFixtureSource.book(), chapter = OnlineFixtureSource.catalog(book)[0], source = OnlineFixtureSource()
        await downloads.configure { _, chapter in .init(chapterID: chapter.id, paragraphs: ["旧的下载正文"]) }
        await downloads.connectivity(connected: true, wifi: true)
        _ = try await downloads.enqueue(book: book, chapters: [chapter], wifiOnly: false)
        for _ in 0..<1000 { if await downloads.list().first?.status == .completed { break }; try await Task.sleep(for: .milliseconds(1)) }
        let downloaded = try await service.document(book: book, chapter: chapter)
        XCTAssertEqual(downloaded.paragraphs.first?.text, "旧的下载正文")
        await service.configure(source: source)
        let fresh = try await service.refreshDocument(book: book, chapter: chapter)
        XCTAssertNotEqual(fresh.version, downloaded.version)
        try await service.clearCache(bookID: book.id)
        let usage = await service.cacheUsage(); XCTAssertEqual(usage.chapters, 0)
        let reopened = try OfflineDownloadStore(directory: directory.appendingPathComponent("downloads"))
        let kept = try await reopened.document(book: book, chapter: chapter)
        XCTAssertEqual(kept, fresh)
        let task = await reopened.list().first
        XCTAssertEqual(task?.status, .completed); XCTAssertEqual(task?.completed, [chapter.id])
    }
}
