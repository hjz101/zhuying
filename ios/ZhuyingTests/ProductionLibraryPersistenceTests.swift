import XCTest
import SQLite3
@testable import Zhuying

final class ProductionLibraryPersistenceTests: XCTestCase {
    private func makeBook(_ name: String = "来信", extra: String = "") throws -> Book {
        try BookImporter.prepare(data: Data("第一章 来信\n第一段正文。\n第二段👩🏽‍🚀文字。\n第二章 回声\n另一章正文。\(extra)".utf8), name: name + ".txt").book
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func execute(_ sql: String, url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw ContentFailure.storageFailure }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ContentFailure.storageFailure }
    }

    func testFreshLibraryIsEmptyAndMigrationIsIdempotent() async throws {
        let root = try directory()
        let backend = try ProductionLibraryPersistence(directory: root)
        let loaded = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertTrue(loaded.books.isEmpty)
        XCTAssertTrue(loaded.sources.isEmpty)
        XCTAssertTrue(loaded.snapshot.favorites.isEmpty)
        XCTAssertTrue(loaded.snapshot.progress.isEmpty)
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let marker = try await records.preference(key: ProductionLibraryPersistence.migrationKey)
        XCTAssertNotNil(marker)
        let reopened = try ProductionLibraryPersistence(directory: root)
        let second = try await reopened.bootstrap(legacySnapshot: Data("invalid old file".utf8), archiveURL: nil)
        XCTAssertTrue(second.books.isEmpty, "A completed migration must not reread stale legacy data")
        XCTAssertTrue(second.sources.isEmpty, "Reopening a fresh library must not seed a source")
        let storedSources = try await records.preference(key: ProductionLibraryPersistence.sourcesKey)
        XCTAssertEqual(try JSONDecoder().decode([DemoSource].self, from: XCTUnwrap(storedSources)), [])
    }

    func testSourceMigrationPreservesUserConfigurationsIncludingLegacyNativeAdapterIdentity() async throws {
        let root = try directory()
        let rules = NativeSourceRules(search:"lookup?q={query}&page={page}",details:"book/{bookID}",catalog:"toc/{bookID}",content:"text/{chapterID}")
        let configuration = try JSONSerialization.data(withJSONObject:["adapter":"json-v1","endpoints":JSONSerialization.jsonObject(with:JSONEncoder().encode(rules))])
        let saved = [DemoSource(id:"shushan",name:"用户保存的来源",group:"原分组",enabled:false,detail:"用户配置",url:"https://native-user.example.test",pinned:true),
                     DemoSource(id:"imported-json",name:"用户导入",group:"自定义",detail:"原生规则",url:"https://custom-user.example.test",configuration:configuration)]
        let original = try JSONEncoder().encode(saved)
        let backend = try ProductionLibraryPersistence(directory:root)
        let migrated = try await backend.bootstrap(legacySnapshot:nil,archiveURL:nil,legacySources:original)
        XCTAssertEqual(migrated.sources,saved)
        let records = try SQLiteLibraryRepository(url:root.appendingPathComponent("library.sqlite"))
        let legacyBytes = try await records.preference(key:"migration.sources.original.v1")
        XCTAssertEqual(legacyBytes,original)
        let reopened = try ProductionLibraryPersistence(directory:root)
        let restored = try await reopened.bootstrap(legacySnapshot:nil,archiveURL:nil,legacySources:Data("[]".utf8))
        XCTAssertEqual(restored.sources,saved,"A stale empty migration input must not erase existing user sources")
    }

    func testExplicitEmptySourcesRemainEmptyWhenStaleLegacyConfigurationReappears() async throws {
        let root = try directory(), backend = try ProductionLibraryPersistence(directory:root)
        let initial = try await backend.bootstrap(legacySnapshot:nil,archiveURL:nil,legacySources:Data("[]".utf8))
        XCTAssertTrue(initial.sources.isEmpty)
        let stale = [DemoSource(id:"shushan",name:"用户旧配置",detail:"旧迁移数据",url:"https://legacy-user.example.test")]
        let reopened = try ProductionLibraryPersistence(directory:root)
        let restored = try await reopened.bootstrap(legacySnapshot:nil,archiveURL:nil,legacySources:JSONEncoder().encode(stale))
        XCTAssertTrue(restored.sources.isEmpty)
        let records = try SQLiteLibraryRepository(url:root.appendingPathComponent("library.sqlite"))
        let original = try await records.preference(key:"migration.sources.original.v1")
        XCTAssertEqual(original,Data("[]".utf8))
    }

    func testLegacyMigrationPreservesBooksOrderUnicodeLocationPreferencesAndOriginalBytes() async throws {
        let root = try directory()
        let first = try makeBook(), second = try makeBook("另一封", extra: "第二本")
        let archive = root.appendingPathComponent("legacy-books.json")
        let archiveData = try JSONEncoder().encode([first, second])
        try archiveData.write(to: archive)
        var snapshot = LibrarySnapshot(favorites: [second.id, first.id, first.id], progress: [first.id: .init(chapter: 0, paragraph: 1, updatedAt: Date(timeIntervalSince1970: 42), characterOffset: 4)],
                                       settings: .init(fontSize: 25, lineSpacing: 18, theme: .dark), sort: .added, hasSeenReadingGuide: true, shelfLayout: "spines", importedGroups: [first.id: "待读", second.id: "读完"])
        snapshot.settings.preferences.leftMargin = 29
        let raw = try JSONEncoder().encode(snapshot)
        let backend = try ProductionLibraryPersistence(directory: root)
        let loaded = try await backend.bootstrap(legacySnapshot: raw, archiveURL: archive)
        XCTAssertEqual(Set(loaded.books), Set([first.metadataOnly(), second.metadataOnly()]))
        XCTAssertEqual(loaded.snapshot.favorites, [second.id, first.id])
        XCTAssertEqual(loaded.snapshot.settings, snapshot.settings)
        XCTAssertEqual(loaded.snapshot.sort, .added)
        XCTAssertEqual(loaded.snapshot.shelfLayout, "spines")
        XCTAssertEqual(loaded.snapshot.hasSeenReadingGuide, true)
        XCTAssertEqual(loaded.snapshot.importedGroups, snapshot.importedGroups)
        XCTAssertEqual(loaded.snapshot.progress[first.id]?.chapter, 0)
        XCTAssertEqual(loaded.snapshot.progress[first.id]?.paragraph, 1)
        XCTAssertEqual(loaded.snapshot.progress[first.id]?.characterOffset, 3, "An offset inside the emoji restores to its grapheme start")
        XCTAssertEqual(loaded.snapshot.progress[first.id]?.updatedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(try Data(contentsOf: archive), archiveData)
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let preserved = try await records.preference(key: ProductionLibraryPersistence.legacySnapshotKey)
        XCTAssertEqual(preserved, raw)
        try Data("broken stale archive".utf8).write(to: archive)
        let reopened = try ProductionLibraryPersistence(directory: root)
        let restored = try await reopened.bootstrap(legacySnapshot: Data("bad old state".utf8), archiveURL: archive)
        XCTAssertEqual(restored.snapshot.progress, loaded.snapshot.progress)
        XCTAssertEqual(Set(restored.books), Set(loaded.books))
    }

    func testCorruptLegacyInputsCannotMarkMigrationCompleteOrDiscardOriginal() async throws {
        let root = try directory(), book = try makeBook()
        let archive = root.appendingPathComponent("legacy.json")
        let original = try JSONEncoder().encode([book])
        try original.write(to: archive)
        let backend = try ProductionLibraryPersistence(directory: root)
        do { _ = try await backend.bootstrap(legacySnapshot: Data("broken".utf8), archiveURL: archive); XCTFail("Invalid snapshot must block migration") } catch {}
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let marker = try await records.preference(key: ProductionLibraryPersistence.migrationKey)
        let before = try await records.books()
        XCTAssertNil(marker)
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let snapshot = try JSONEncoder().encode(LibrarySnapshot(favorites: [book.id], progress: [:]))
        let repaired = try await backend.bootstrap(legacySnapshot: snapshot, archiveURL: archive)
        XCTAssertEqual(repaired.snapshot.favorites, [book.id])
    }

    func testUnsupportedLegacyVersionCannotCompleteMigration() async throws {
        let root = try directory()
        var snapshot = LibrarySnapshot(favorites: [], progress: [:]); snapshot.version = 99
        let backend = try ProductionLibraryPersistence(directory: root)
        do { _ = try await backend.bootstrap(legacySnapshot: JSONEncoder().encode(snapshot), archiveURL: nil); XCTFail("Unknown version") } catch {}
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let marker = try await records.preference(key: ProductionLibraryPersistence.migrationKey)
        XCTAssertNil(marker)
    }

    func testInvalidLegacyChapterIsRetainedAsUnresolvedUntilUserChoosesValidChapter() async throws {
        let root = try directory(), book = try makeBook()
        let archive = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode([book]).write(to: archive)
        let raw = try JSONEncoder().encode(LibrarySnapshot(favorites: [book.id], progress: [book.id: .init(chapter: 999, paragraph: 0, updatedAt: Date())]))
        let backend = try ProductionLibraryPersistence(directory: root)
        var loaded = try await backend.bootstrap(legacySnapshot: raw, archiveURL: archive)
        XCTAssertNil(loaded.snapshot.progress[book.id])
        XCTAssertTrue(loaded.unresolvedBookIDs.contains(book.id))
        loaded.snapshot.progress[book.id] = .init(chapter: 1, paragraph: 0, updatedAt: Date())
        try await backend.saveState(loaded.snapshot)
        let reopened = try ProductionLibraryPersistence(directory: root)
        let restored = try await reopened.bootstrap(legacySnapshot: raw, archiveURL: archive)
        XCTAssertEqual(restored.snapshot.progress[book.id]?.chapter, 1)
        XCTAssertFalse(restored.unresolvedBookIDs.contains(book.id))
    }

    func testImportPersistsContentFavoriteAndGroupWithoutLegacyArchive() async throws {
        let root = try directory(), book = try makeBook()
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        let imported = try await backend.importBook(book, group: "真实分组")
        let duplicate = try await backend.importBook(book, group: "不应覆盖")
        XCTAssertTrue(imported)
        XCTAssertFalse(duplicate)
        let reopened = try ProductionLibraryPersistence(directory: root)
        let loaded = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(loaded.books, [book.metadataOnly()])
        XCTAssertEqual(loaded.snapshot.favorites, [book.id])
        XCTAssertEqual(loaded.snapshot.importedGroups, [book.id: "真实分组"])
    }

    func testMetadataFailureAfterFileStageRollsBackNewManifestEntries() async throws {
        let root = try directory(), original = try makeBook(), addition = try makeBook("新书", extra: "新内容")
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        _ = try await backend.importBook(original, group: "原分组")
        try execute("CREATE TRIGGER reject_new_book BEFORE INSERT ON book_records WHEN NEW.id = '\(addition.id)' BEGIN SELECT RAISE(ABORT, 'injected write failure'); END", url: root.appendingPathComponent("library.sqlite"))
        do { _ = try await backend.importBook(addition, group: "新分组"); XCTFail("Metadata failure must be reported") } catch {}
        let reopened = try ProductionLibraryPersistence(directory: root)
        let loaded = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(loaded.books, [original.metadataOnly()])
        XCTAssertEqual(loaded.snapshot.favorites, [original.id])
        let files = try FileChapterRepository(directory: root.appendingPathComponent("chapters"))
        let ids = await files.chapterIDs()
        XCTAssertEqual(ids.count, original.chapters.count)
    }

    func testAtomicStateFailurePreservesAllPreviouslyCommittedState() async throws {
        let root = try directory(), book = try makeBook()
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        _ = try await backend.importBook(book, group: "原分组")
        let snapshot = LibrarySnapshot(favorites: [book.id], progress: [book.id: .init(chapter: 0, paragraph: 0, updatedAt: Date(timeIntervalSince1970: 10))], importedGroups: [book.id: "原分组"])
        try await backend.saveState(snapshot)
        try execute("CREATE TRIGGER reject_preferences BEFORE UPDATE ON preferences WHEN NEW.key = 'library.view-preferences.v1' BEGIN SELECT RAISE(ABORT, 'injected late failure'); END", url: root.appendingPathComponent("library.sqlite"))
        var changed = snapshot
        changed.favorites = []; changed.importedGroups = [book.id: "新分组"]
        changed.progress[book.id] = .init(chapter: 1, paragraph: 0, updatedAt: Date())
        changed.settings.fontSize = 29
        do { try await backend.saveState(changed); XCTFail("Late failure") } catch {}
        let reopened = try ProductionLibraryPersistence(directory: root)
        let loaded = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(loaded.snapshot.favorites, snapshot.favorites)
        XCTAssertEqual(loaded.snapshot.importedGroups, snapshot.importedGroups)
        XCTAssertEqual(loaded.snapshot.progress, snapshot.progress)
        XCTAssertEqual(loaded.snapshot.settings, snapshot.settings)
    }

    func testRemovingFavoriteRetainsProgressAcrossRestartAndInvalidSaveCannotAdvanceIt() async throws {
        let root = try directory(), book = try makeBook()
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        _ = try await backend.importBook(book, group: "待读")
        var state = LibrarySnapshot(favorites: [], progress: [book.id: .init(chapter: 1, paragraph: 0, updatedAt: Date(timeIntervalSince1970: 20))])
        try await backend.saveState(state)
        state.progress[book.id]?.chapter = 999
        do { try await backend.saveState(state); XCTFail("Invalid index") } catch { XCTAssertEqual(error as? ContentFailure, .missingChapter) }
        let reopened = try ProductionLibraryPersistence(directory: root)
        let loaded = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertTrue(loaded.snapshot.favorites.isEmpty)
        XCTAssertEqual(loaded.snapshot.progress[book.id]?.chapter, 1)
        XCTAssertEqual(loaded.books, [book.metadataOnly()])
    }

    func testConcurrentDuplicateImportsSerializeAndRecoverOrphanChapterFiles() async throws {
        let root = try directory(), book = try makeBook()
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        async let first = backend.importBook(book, group: "待读")
        async let second = backend.importBook(book, group: "待读")
        let results = try await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let files = try FileChapterRepository(directory: root.appendingPathComponent("chapters"))
        try await files.save(.init(chapterID: "interrupted-import", paragraphs: ["未提交的临时正文"]))
        let reopened = try ProductionLibraryPersistence(directory: root)
        let loaded = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(loaded.books, [book.metadataOnly()])
        let recoveredFiles = try FileChapterRepository(directory: root.appendingPathComponent("chapters"))
        let ids = await recoveredFiles.chapterIDs()
        XCTAssertFalse(ids.contains("interrupted-import"))
    }
}
