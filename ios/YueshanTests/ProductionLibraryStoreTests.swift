import XCTest
import SQLite3
@testable import Yueshan

@MainActor
final class ProductionLibraryStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var domain: String!
    private let text = "第一章 来信\n从真实导入读取的第一段。\n第二章 回声\n另一章里的一段正文。"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        domain = "com.yueshan.production.store.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
    private func store(writer: any AtomicFileWriting = AtomicFileWriter()) throws -> LibraryStore {
        let backend = try ProductionLibraryPersistence(directory: root.appendingPathComponent("database"), writer: writer)
        return LibraryStore(books: [], defaults: defaults, importsURL: root.appendingPathComponent("legacy/books.json"), seedDemoData: false, productionPersistence: backend)
    }
    private func prepare() throws -> Book { try BookImporter.prepare(data: Data(text.utf8), name: "来信.txt").book }
    private func execute(_ sql: String) throws {
        var database: OpaquePointer?
        let path = root.appendingPathComponent("database/library.sqlite").path
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw ContentFailure.storageFailure }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ContentFailure.storageFailure }
    }

    func testImportSessionUsesDurableBackendAndRestoresReadingAndPreferencesWithoutLegacyWrites() async throws {
        let library = try store()
        XCTAssertEqual(library.loadState, .loading)
        await library.bootstrapProductionIfNeeded()
        XCTAssertEqual(library.loadState, .ready)
        let session = BookImportSession()
        await session.add([.text(text)], encoding: .automatic, library: library)
        await session.commit(library: library, group: "真实分组")
        XCTAssertEqual(session.items.map(\.status), [.imported])
        let book = try XCTUnwrap(library.books.first)
        XCTAssertEqual(library.favorites, [book.id])
        library.read(book, chapter: 1)
        library.record(book, chapter: 1, characterOffset: 4)
        library.settings = .init(fontSize: 24, lineSpacing: 17, theme: .dark)
        library.sort = .title; library.shelfLayout = .spines
        library.completeReadingGuide()
        let saved = await library.flushPendingWrites()
        XCTAssertTrue(saved)
        XCTAssertNil(defaults.data(forKey: LibraryStore.storageKey), "Production must not keep rewriting the legacy snapshot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy/books.json").path))
        let restored = try store()
        await restored.bootstrapProductionIfNeeded()
        XCTAssertEqual(restored.books, library.books)
        XCTAssertEqual(restored.favorites, library.favorites)
        XCTAssertEqual(restored.progress, library.progress)
        XCTAssertEqual(restored.settings, library.settings)
        XCTAssertEqual(restored.shelfLayout, .spines)
        XCTAssertEqual(restored.sort, .title)
        XCTAssertTrue(restored.hasSeenReadingGuide)
        XCTAssertEqual(restored.importedGroups[book.id], "真实分组")
    }

    func testMigrationKeepsLegacySnapshotAndArchiveAndBlocksInvalidHistoryUntilExplicitSelection() async throws {
        let book = try prepare()
        let archive = root.appendingPathComponent("legacy/books.json")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode([book]); try original.write(to: archive)
        let snapshot = LibrarySnapshot(favorites: [book.id], progress: [book.id: .init(chapter: 888, paragraph: 0, updatedAt: Date())], settings: .init(fontSize: 23))
        let originalSnapshot = try JSONEncoder().encode(snapshot)
        defaults.set(originalSnapshot, forKey: LibraryStore.storageKey)
        let library = try store()
        await library.bootstrapProductionIfNeeded()
        XCTAssertEqual(library.loadState, .ready)
        XCTAssertTrue(library.unresolvedBookIDs.contains(book.id))
        library.read(book)
        XCTAssertNil(library.reader)
        XCTAssertNil(library.progress[book.id])
        XCTAssertNotNil(library.storageMessage)
        library.read(book, chapter: 1)
        XCTAssertEqual(library.reader?.chapter, 1)
        XCTAssertFalse(library.unresolvedBookIDs.contains(book.id))
        let saved = await library.flushPendingWrites()
        XCTAssertTrue(saved)
        XCTAssertEqual(defaults.data(forKey: LibraryStore.storageKey), originalSnapshot)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let restored = try store()
        await restored.bootstrapProductionIfNeeded()
        restored.read(book)
        XCTAssertEqual(restored.reader?.chapter, 1)
        _ = await restored.flushPendingWrites()
    }

    func testFailedBootstrapCannotWriteOverLegacyStateAndCanRetryAfterRepair() async throws {
        let broken = Data("broken-state".utf8)
        defaults.set(broken, forKey: LibraryStore.storageKey)
        let library = try store()
        await library.bootstrapProductionIfNeeded()
        XCTAssertEqual(library.loadState, .failed)
        library.settings.fontSize = 29
        let flushed = await library.flushPendingWrites()
        XCTAssertFalse(flushed)
        do { _ = try await library.importBookDurably(prepare()); XCTFail("Blocked while storage is unavailable") } catch {}
        XCTAssertEqual(defaults.data(forKey: LibraryStore.storageKey), broken)
        defaults.set(try JSONEncoder().encode(LibrarySnapshot(favorites: [], progress: [:])), forKey: LibraryStore.storageKey)
        await library.bootstrapProductionIfNeeded()
        XCTAssertEqual(library.loadState, .ready)
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertNil(library.storageMessage)
    }

    private struct RejectManifest: AtomicFileWriting {
        func write(_ data: Data, to url: URL) throws {
            if url.lastPathComponent == "manifest.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }
    func testImportFailureNeverReportsSuccessOrChangesPublishedShelf() async throws {
        let library = try store(writer: RejectManifest())
        await library.bootstrapProductionIfNeeded()
        let session = BookImportSession()
        await session.add([.text(text)], encoding: .automatic, library: library)
        await session.commit(library: library, group: "待读")
        XCTAssertEqual(session.failedCount, 1)
        XCTAssertTrue(session.summary.contains("成功 0 项"))
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertTrue(library.favorites.isEmpty)
        let reopened = try store()
        await reopened.bootstrapProductionIfNeeded()
        XCTAssertTrue(reopened.books.isEmpty)
    }

    func testQueuedSettingsCannotEraseAnImportAndConcurrentDuplicatesOnlySucceedOnce() async throws {
        let library = try store()
        await library.bootstrapProductionIfNeeded()
        let book = try prepare()
        let first = Task { try await library.importBookDurably(book, group: "待读") }
        let second = Task { try await library.importBookDurably(book, group: "待读") }
        for size in 20...28 { library.settings.fontSize = Double(size); await Task.yield() }
        let results = try await [first.value, second.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let saved = await library.flushPendingWrites()
        XCTAssertTrue(saved)
        let restored = try store()
        await restored.bootstrapProductionIfNeeded()
        XCTAssertEqual(restored.favorites, [book.id])
        XCTAssertEqual(restored.books.count, 1)
        XCTAssertEqual(restored.settings.fontSize, 28)
        XCTAssertEqual(restored.importedGroups[book.id], "待读")
    }

    func testWriteFailureShowsMessageRetainsDatabaseAndRetriesLatestPosition() async throws {
        let library = try store()
        await library.bootstrapProductionIfNeeded()
        let book = try prepare()
        _ = try await library.importBookDurably(book)
        library.record(book, chapter: 0)
        let initial = await library.flushPendingWrites()
        XCTAssertTrue(initial)
        try execute("CREATE TRIGGER deny_state BEFORE UPDATE ON preferences WHEN NEW.key = 'library.view-preferences.v1' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        library.record(book, chapter: 1)
        let failed = await library.flushPendingWrites()
        XCTAssertFalse(failed)
        XCTAssertNotNil(library.storageMessage)
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("database/library.sqlite"))
        let old = try await records.progress(bookID: book.id)
        let catalog = try await records.chapters(bookID: book.id)
        XCTAssertEqual(old?.chapterID, catalog[0].id)
        try execute("DROP TRIGGER deny_state")
        let retried = await library.flushPendingWrites()
        XCTAssertTrue(retried)
        XCTAssertNil(library.storageMessage)
        let restored = try store()
        await restored.bootstrapProductionIfNeeded()
        XCTAssertEqual(restored.progress[book.id]?.chapter, 1)
    }

    func testContinuousReadingSavesPeriodicallyBeforeScrollingStops() async throws {
        let library = try store()
        await library.bootstrapProductionIfNeeded()
        let book = try prepare()
        _ = try await library.importBookDurably(book)
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("database/library.sqlite"))
        library.record(book, chapter: 0, now: Date(timeIntervalSince1970: 100))
        _ = await library.flushPendingWrites()
        var savedWhileActive = false
        for index in 0..<40 {
            library.record(book, chapter: 0, characterOffset: index % 5, now: Date(timeIntervalSince1970: 200 + Double(index)))
            if index > 5, let saved = try await records.progress(bookID: book.id), saved.updatedAt > Date(timeIntervalSince1970: 100) {
                savedWhileActive = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(savedWhileActive, "Continuous changes must not postpone every save until the reader stops")
        _ = await library.flushPendingWrites()
    }

    func testAlternatingBooksKeepIndependentPositionsAndRemovalPreservesUnfavoritedHistory() async throws {
        let library = try store()
        await library.bootstrapProductionIfNeeded()
        let first = try prepare()
        let second = try BookImporter.prepare(data: Data("第一章 入山\n另一部作品的真实正文。\n第二章 归来\n还有下一章的不同正文。".utf8), name: "山路.txt").book
        _ = try await library.importBookDurably(first, group: "已读")
        _ = try await library.importBookDurably(second, group: "待读")
        library.record(first, chapter: 1, characterOffset: 3, now: Date(timeIntervalSince1970: 100))
        library.record(second, chapter: 0, characterOffset: 6, now: Date(timeIntervalSince1970: 200))
        let removal = library.removeFavorites([first.id])
        // Reading an unfavorited book must continue to save its own position.
        library.record(first, chapter: 0, characterOffset: 5, now: Date(timeIntervalSince1970: 300))
        let flushed = await library.flushPendingWrites()
        XCTAssertTrue(flushed)
        let reopened = try store()
        await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.favorites, [second.id])
        XCTAssertEqual(reopened.history.map(\.id), [first.id, second.id])
        XCTAssertEqual(reopened.progress[first.id]?.chapter, 0)
        XCTAssertEqual(reopened.progress[first.id]?.characterOffset, 5)
        XCTAssertEqual(reopened.progress[second.id]?.chapter, 0)
        XCTAssertEqual(reopened.progress[second.id]?.characterOffset, 6)
        XCTAssertEqual(reopened.importedGroups[first.id], "已读")
        reopened.undoRemoval(removal)
        let restored = await reopened.flushPendingWrites()
        XCTAssertTrue(restored)
        let final = try store()
        await final.bootstrapProductionIfNeeded()
        XCTAssertEqual(final.favorites, [second.id, first.id])
        XCTAssertEqual(final.progress, reopened.progress)
    }
}
