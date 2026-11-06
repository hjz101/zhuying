import XCTest
import SQLite3
import UIKit
@testable import Zhuying

@MainActor final class AppearancePersistenceTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func themes() -> ThemeLibrarySnapshot { FeatureDemoStore().themeSnapshot }
    private func input(_ value: ThemeLibrarySnapshot) -> AppearanceMigrationInput { .init(fallbackThemeLibrary: value, originalFontManifest: Data("original-font-manifest".utf8), fontHashes: [:]) }
    private func sql(_ statement: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database) == SQLITE_OK else { throw ContentFailure.storageFailure }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw ContentFailure.storageFailure }
    }
    func testLegacyThemesAndFontRecordMigrateOnceWithRawInputPreservedAndResourcesReferenced() async throws {
        let original = themes(), bytes = try JSONEncoder().encode(original)
        let backend = try ProductionLibraryPersistence(directory: root)
        let first = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil, legacyThemeData: bytes, appearance: input(original))
        XCTAssertEqual(first.themeLibrary, original)
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let raw = try await records.preference(key: "migration.appearance.original-theme-library")
        let font = try await records.preference(key: "migration.appearance.original-font-manifest")
        XCTAssertEqual(raw, bytes); XCTAssertEqual(font, Data("original-font-manifest".utf8))
        let archiveData = try await records.preference(key: ProductionLibraryPersistence.themeLibraryKey)
        let archive = try XCTUnwrap(archiveData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        let assets = try XCTUnwrap(json["assets"] as? [[String: Any]])
        XCTAssertFalse(assets.isEmpty)
        XCTAssertTrue(assets.allSatisfy { $0["content"] == nil && $0["resource"] != nil })
        let reopened = try ProductionLibraryPersistence(directory: root)
        let restored = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil, legacyThemeData: Data("broken old input".utf8), appearance: input(original))
        XCTAssertEqual(restored.themeLibrary, original)
    }
    func testBrokenLegacyThemePreventsCompletionAndCanRetryWithoutErasingOriginal() async throws {
        let original = themes(), bytes = Data("bad-theme-json".utf8)
        let backend = try ProductionLibraryPersistence(directory: root)
        do { _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil, legacyThemeData: bytes, appearance: input(original)); XCTFail("Must preserve failure") } catch {}
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let marker = try await records.preference(key: ProductionLibraryPersistence.appearanceMigrationKey)
        XCTAssertNil(marker)
        let repaired = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil, legacyThemeData: JSONEncoder().encode(original), appearance: input(original))
        XCTAssertEqual(repaired.themeLibrary, original)
    }
    func testThemeAndReaderPreferencesCommitTogetherAndLateDatabaseFailureKeepsOldState() async throws {
        let original = themes()
        let backend = try ProductionLibraryPersistence(directory: root)
        let initial = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil, appearance: input(original))
        var snapshot = initial.snapshot
        snapshot.settings.fontSize = 28
        let changed = ThemeLibrarySnapshot(themes: original.themes, assets: original.assets, themeID: "night", titleID: "night:title:main", bubbleID: "night:bubble:main")
        try sql("CREATE TRIGGER deny_theme BEFORE UPDATE ON preferences WHEN NEW.key='appearance.theme-library.v1' BEGIN SELECT RAISE(ABORT,'injected'); END")
        do { try await backend.saveState(snapshot, themeLibrary: changed); XCTFail("Atomic failure") } catch {}
        let reopened = try ProductionLibraryPersistence(directory: root)
        let old = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(old.snapshot.settings.fontSize, 20)
        XCTAssertEqual(old.themeLibrary?.themeID, "paper")
        try sql("DROP TRIGGER deny_theme")
        try await backend.saveState(snapshot, themeLibrary: changed)
        let restored = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(restored.snapshot.settings.fontSize, 28)
        XCTAssertEqual(restored.themeLibrary?.themeID, "night")
    }
    func testDamagedThemeResourceKeepsReferenceAndValidReadingStyleUntilRepair() async throws {
        let original = themes()
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil, appearance: input(original))
        let asset = try XCTUnwrap(original.assets.first)
        let data = Data(asset.content.utf8)
        let path = root.appendingPathComponent("resources/themes").appendingPathComponent(FileResourceStore.digest(data) + (asset.kind == .title ? ".css" : ".svg"))
        try Data("damaged resource".utf8).write(to: path)
        let reopened = try ProductionLibraryPersistence(directory: root)
        let loaded = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertFalse(loaded.warnings.isEmpty)
        XCTAssertEqual(loaded.themeLibrary?.assets.first { $0.id == asset.id }?.content, "")
        try await reopened.saveState(loaded.snapshot, themeLibrary: loaded.themeLibrary)
        try data.write(to: path, options: .atomic)
        let repaired = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(repaired.themeLibrary?.assets.first { $0.id == asset.id }?.content, asset.content)
        XCTAssertTrue(repaired.warnings.isEmpty)
    }
    func testInvalidStylesRetainPreviousValidOverridesAndBadFontsFallBack() throws {
        var old = ReadingSettings(fontSize: 24)
        old.preferences.titleCSS = ".chapter-title {font-size: 29px;}"
        old.preferences.customBubbleSVG = "<svg><rect width='20' height='20'/></svg>"
        var broken = old
        broken.fontSize = .nan
        broken.preferences.titleCSS = ".chapter-title {unknown: broken;}"
        broken.preferences.customBubbleSVG = "<svg><script/></svg>"
        let resolved = ReadingStyleResolver.resolve(broken, previous: old)
        XCTAssertEqual(resolved.fontSize, 24)
        XCTAssertEqual(resolved.preferences.titleCSS, old.preferences.titleCSS)
        XCTAssertEqual(resolved.preferences.customBubbleSVG, old.preferences.customBubbleSVG)
        broken.preferences.titleCSS = String(repeating: "x", count: 60_001)
        XCTAssertEqual(ReadingStyleResolver.resolve(broken, previous: old).preferences.titleCSS, old.preferences.titleCSS)
        var system = ReadingSettings(); system.preferences.fontName = "Georgia"; system.preferences.fontResourceHash = String(repeating: "a", count: 64)
        XCTAssertNotEqual(ReaderTypography.font(settings: system).fontName, "Georgia", "A font from another file must not impersonate a missing imported font")
    }
}
