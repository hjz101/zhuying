import XCTest
@testable import Zhuying

@MainActor final class LibraryBackupTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var domain: String!
    private var activeFonts: ReadingFontLibrary?
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        domain = "backup-tests-\(UUID().uuidString)"; defaults = UserDefaults(suiteName: domain)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        activeFonts?.reload(reset: true); activeFonts = nil
        ReadingFontLibrary(directory: root.appendingPathComponent("fonts")).reload(reset: true)
        try? FileManager.default.removeItem(at: root)
    }
    private func workspace(_ name: String = "data", writer: any AtomicFileWriting = AtomicFileWriter()) -> LibraryWorkspace {
        .init(root: root.appendingPathComponent(name), legacyFonts: root.appendingPathComponent("fonts"), writer: writer)
    }
    private func library(_ workspace: LibraryWorkspace) -> LibraryStore {
        .init(books: [], defaults: defaults, seedDemoData: false, productionFactory: { try ProductionLibraryPersistence(directory: workspace.databaseDirectory()) }, workspace: workspace)
    }
    func testRestoreStopsOldWorkButLeavesForegroundDownloadsReadyForNewRequests() async throws {
        let workspace = workspace(), downloads = try OfflineDownloadStore(directory:root.appendingPathComponent("downloads"))
        let service = OnlineReadingService(cache:try RecentChapterCache(directory:root.appendingPathComponent("cache")),downloads:downloads)
        let library = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionFactory:{ try ProductionLibraryPersistence(directory:workspace.databaseDirectory()) },onlineService:service,workspace:workspace)
        await library.bootstrapProductionIfNeeded()
        let backup = try LibraryBackup.decode(await library.createBackup())
        await downloads.configure { _,chapter in .init(chapterID:chapter.id,paragraphs:["恢复后的原创下载正文。"]) }
        try await library.restoreBackup(backup)
        let book = LibraryBookRecord(id:"after-restore",title:"恢复下载测试",author:"原创",summary:"",source:.init(sourceID:"test",nativeBookID:"test",provider:"测试",bookURL:"https://test.invalid"),addedAt:Date())
        let chapter = ChapterRecord(id:"after-restore-chapter",bookID:book.id,nativeChapterID:"one",title:"第一章",order:0,access:.readable)
        _ = try await downloads.enqueue(book:book,chapters:[chapter],wifiOnly:false)
        for _ in 0..<200 {
            await downloads.connectivity(connected:true,wifi:true)
            if await downloads.list().first?.status == .completed { return }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Foreground downloads must remain usable after backup restore")
    }
    private func appearance(_ fonts: ReadingFontLibrary, workspace: LibraryWorkspace) throws -> AppearanceMigrationInput {
        fonts.useDirectory(try workspace.fontDirectory())
        return .init(fallbackThemeLibrary: FeatureDemoStore(seedDemoData: false).themeSnapshot, originalFontManifest: try fonts.prepareManagedStorage(), fontHashes: fonts.recordedHashes)
    }
    func testInvalidOrDuplicateGroupsNeverReportCreationOrMergeExistingGroups() async throws {
        let workspace = workspace(), library = library(workspace); await library.bootstrapProductionIfNeeded()
        for name in ["", "全部", "未分组", String(repeating: "组", count: 101)] { XCTAssertFalse(library.createGroup(name)) }
        XCTAssertTrue(library.createGroup("新分组")); XCTAssertFalse(library.createGroup(" 新分组 "))
        XCTAssertTrue(library.createGroup("另一组"))
        XCTAssertFalse(library.renameGroup("新分组", to: "另一组"))
        XCTAssertFalse(library.renameGroup("新分组", to: "全部"))
        XCTAssertTrue(library.renameGroup("新分组", to: "重命名"))
        let saved = await library.flushPendingWrites(); XCTAssertTrue(saved)
        let reopened = self.library(workspace); await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(Set(reopened.groupNames), ["另一组", "重命名"])
    }
    func testBackupRestoresCleanGenerationIncludingProseLocationBookmarkThemeFontAndEmptyGroups() async throws {
        let workspace = workspace(), fonts = ReadingFontLibrary(directory: root.appendingPathComponent("fonts"), managed: true)
        activeFonts = fonts
        _ = try fonts.prepareManagedStorage()
        let fontBytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReaderTestFont", withExtension: "ttf")))
        let entries = try fonts.importFont(data: fontBytes, originalName: "ReaderTestFont.ttf")
        let library = library(workspace)
        await library.bootstrapProductionIfNeeded(prepareAppearance: { try self.appearance(fonts, workspace: workspace) })
        let original = try BookImporter.prepare(data: Data("第一章 来信\n应完整恢复的第一段👩🏽‍🚀。\n第二章 山林\n应恢复的第二章正文。".utf8), name: "原书.txt").book
        _ = try await library.importBookDurably(original, group: "待读")
        library.record(original, chapter: 1, characterOffset: 3)
        _ = try await library.saveBookmark(original, chapter: 1, paragraph: 0, offset: 3, title: "山林")
        library.createGroup("空分组")
        library.settings.fontSize = 27
        library.settings.preferences.fontName = entries[0].postScriptName; library.settings.preferences.fontResourceHash = entries[0].resource?.digest
        library.updateSources([.init(id: "shushan", name: "书山聚合", detail: "private-account-name", url: ShushanClient.defaultHost, loginStatus: .signedIn)])
        let data = try await library.createBackup(), backup = try LibraryBackup.decode(data)
        XCTAssertEqual(backup.documents.count, 2)
        XCTAssertTrue(backup.resources.contains { $0.path.hasPrefix("themes/") })
        XCTAssertTrue(backup.resources.contains { $0.data == fontBytes })
        let missingFont = LibraryBackup(createdAt: backup.createdAt, database: backup.database, documents: backup.documents,
                                        resources: backup.resources.filter { $0.data != fontBytes })
        XCTAssertThrowsError(try missingFont.validate(), "A manifest cannot claim a font whose bytes are missing")
        var manifest = try JSONDecoder().decode(FontLibraryManifest.self, from: XCTUnwrap(backup.resources.first { $0.path == "fonts/fonts.json" }).data)
        manifest.entries.append(try XCTUnwrap(manifest.entries.first))
        let duplicateNames = LibraryBackup(createdAt: backup.createdAt, database: backup.database, documents: backup.documents,
                                           resources: backup.resources.filter { $0.path != "fonts/fonts.json" } + [.init(path: "fonts/fonts.json", data: try JSONEncoder().encode(manifest))])
        XCTAssertThrowsError(try duplicateNames.validate(), "Reject invalid font manifests before switching the active database")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(backup.database), as: UTF8.self).contains("private-account-name"))
        XCTAssertTrue(backup.database.preferences.keys.allSatisfy { !($0.contains("original") || $0.contains("credential")) })
        try await library.permanentlyDeleteBook(id: original.id)
        XCTAssertTrue(library.books.isEmpty)
        try await library.restoreBackup(backup)
        XCTAssertEqual(library.books.map(\.id), [original.id]); XCTAssertEqual(library.settings.fontSize, 27)
        XCTAssertTrue(library.groupNames.contains("空分组")); XCTAssertEqual(library.bookmarks.count, 1)
        XCTAssertEqual(library.progress[original.id]?.chapter, 1); XCTAssertEqual(library.progress[original.id]?.characterOffset, 3)
        XCTAssertEqual(library.sources.first?.loginStatus, .signedOut)
        XCTAssertEqual(try Data(contentsOf: try workspace.fontDirectory().appendingPathComponent(entries[0].filename)), fontBytes)
        let exported = try await library.exportLocalText(id: original.id)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("应恢复的第二章正文。"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("library.sqlite").path), "Original generation survives")
        let reopened = self.library(workspace); await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.progress, library.progress); XCTAssertEqual(reopened.bookmarks, library.bookmarks)
    }
    private struct RejectActivation: AtomicFileWriting {
        func write(_ data: Data, to url: URL) throws {
            if url.lastPathComponent == "active-generation.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }
    func testRestoreFailureBeforePointerCommitPreservesExistingDatabaseAndCanRetry() async throws {
        let workspace = workspace(), library = library(workspace)
        await library.bootstrapProductionIfNeeded()
        let book = try BookImporter.prepare(data: Data("第一章 保留\n已有有效正文不能被失败恢复覆盖。".utf8), name: "有效.txt").book
        _ = try await library.importBookDurably(book)
        let backup = try LibraryBackup.decode(await library.createBackup())
        let failing = self.workspace(writer: RejectActivation())
        do { try await failing.restore(backup); XCTFail("Injected final commit failure") } catch {}
        XCTAssertEqual(try workspace.databaseDirectory().path, workspace.root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("active-generation.json").path))
        let reopened = self.library(workspace); await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.books.map(\.id), [book.id])
        try await workspace.restore(backup)
        XCTAssertNotEqual(try workspace.databaseDirectory().path, workspace.root.path)
    }
    func testUnknownVersionTamperingAndTraversalAreRejectedBeforeActivation() async throws {
        let workspace = workspace(), library = library(workspace); await library.bootstrapProductionIfNeeded()
        let data = try await library.createBackup()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        XCTAssertThrowsError(try LibraryBackup.decode(JSONSerialization.data(withJSONObject: object)))
        object["version"] = 1; object["digest"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try LibraryBackup.decode(JSONSerialization.data(withJSONObject: object)))
        let original = try LibraryBackup.decode(data)
        let unsafe = LibraryBackup(createdAt: Date(), database: original.database, documents: original.documents, resources: [.init(path: "fonts/../../outside", data: Data("bad".utf8))])
        do { try await workspace.restore(unsafe); XCTFail("Traversal") } catch {}
        XCTAssertEqual(try workspace.databaseDirectory().path, workspace.root.path)
    }
    func testMissingThemeResourceRejectsRestoreBeforeActivationAndRenameRetainsLocation() async throws {
        let workspace = workspace(), library = library(workspace)
        let themes = FeatureDemoStore(seedDemoData: false).themeSnapshot
        await library.bootstrapProductionIfNeeded(prepareAppearance: { .init(fallbackThemeLibrary: themes, originalFontManifest: nil, fontHashes: [:]) })
        let book = try BookImporter.prepare(data: Data("第一章 来信\n重命名不能改变这一章的阅读位置。".utf8), name: "原书.txt").book
        _ = try await library.importBookDurably(book); library.record(book, chapter: 0, characterOffset: 4)
        _ = try await library.saveBookmark(book, chapter: 0, paragraph: 0, offset: 4, title: "位置")
        try await library.renameLocalBook(id: book.id, title: "改名")
        let files = try await library.localFiles(); XCTAssertEqual(files.first?.name, "改名"); XCTAssertGreaterThan(files.first?.bytes ?? 0, 0)
        let data = try await library.createBackup(), backup = try LibraryBackup.decode(data)
        let incomplete = LibraryBackup(createdAt: Date(), database: backup.database, documents: backup.documents, resources: [])
        do { try await workspace.restore(incomplete); XCTFail("Required theme resources are missing") } catch {}
        XCTAssertEqual(try workspace.databaseDirectory().path, workspace.root.path)
        let reopened = self.library(workspace); await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.books.first?.title, "改名"); XCTAssertEqual(reopened.progress[book.id]?.characterOffset, 4)
        XCTAssertEqual(reopened.bookmarks.count, 1)
    }
}
