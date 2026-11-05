import XCTest
@testable import Yueshan

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testNamespacesPreserveDemoPathsAndIsolateProduction() {
        let demo = AppEnvironment(arguments: ["--demo"])
        let production = AppEnvironment(arguments: ["--production"])
        XCTAssertTrue(demo.isDemo)
        XCTAssertNil(demo.defaultsDomain)
        XCTAssertEqual(demo.importsComponent, "ImportedBooks")
        XCTAssertEqual(demo.fontsComponent, "ReadingFonts")
        XCTAssertFalse(production.isDemo)
        XCTAssertNotEqual(demo.defaultsDomain, production.defaultsDomain)
        XCTAssertNotEqual(demo.importsComponent, production.importsComponent)
        XCTAssertNotEqual(demo.fontsComponent, production.fontsComponent)
        XCTAssertNotEqual(demo.databaseComponent, production.databaseComponent)
    }
    func testUITestsAreDeterministicAndIsolated() {
        let demo = AppEnvironment(arguments: ["--ui-testing"])
        let production = AppEnvironment(arguments: ["--ui-testing", "--production"])
        let preserved = AppEnvironment(arguments: ["--ui-testing", "--production", "--preserve-ui-test-state"])
        XCTAssertTrue(demo.isDemo)
        XCTAssertTrue(demo.resetsTestState)
        XCTAssertFalse(production.isDemo)
        XCTAssertTrue(production.resetsTestState)
        XCTAssertFalse(preserved.resetsTestState)
        XCTAssertEqual(production.defaultsDomain, preserved.defaultsDomain)
        XCTAssertNotEqual(demo.defaultsDomain, production.defaultsDomain)
        XCTAssertNotEqual(demo.importsComponent, production.importsComponent)
        XCTAssertNotEqual(demo.fontsComponent, production.fontsComponent)
    }
    func testProductionStartsEmptyAndPersistsPreferencesWithoutSimulatedHistory() {
        let domain = "com.yueshan.environment.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = LibraryStore(books: [], defaults: defaults, seedDemoData: false)
        XCTAssertFalse(store.isDemo)
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(store.progress.isEmpty)
        XCTAssertTrue(store.updatedBooks.isEmpty)
        store.settings.fontSize = 24
        let restored = LibraryStore(books: [], defaults: defaults, seedDemoData: false)
        XCTAssertTrue(restored.shelf.isEmpty)
        XCTAssertEqual(restored.settings.fontSize, 24)
    }
    func testUnreadableProductionSnapshotIsRetainedWithoutDemoRecords() {
        let domain = "com.yueshan.environment.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let damaged = Data("broken".utf8)
        defaults.set(damaged, forKey: LibraryStore.storageKey)
        let store = LibraryStore(books: [], defaults: defaults, seedDemoData: false)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(store.progress.isEmpty)
        XCTAssertNotNil(store.storageMessage)
        XCTAssertEqual(defaults.data(forKey: LibraryStore.storageKey), damaged)
    }

    func testProductionSourcesUseSharedDemoModelWithoutSeedingSimulatedResults() {
        let domain = "com.yueshan.sources.production.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let production = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        XCTAssertFalse(production.isDemo)
        XCTAssertEqual(production.sources.map(\.id), ["shushan"])
        XCTAssertTrue(production.bookGroups.isEmpty)
        XCTAssertTrue(production.bookmarks.isEmpty)
        XCTAssertTrue(production.files.isEmpty)
        XCTAssertTrue(production.backups.isEmpty)
        XCTAssertTrue(production.cacheMB.values.allSatisfy { $0 == 0 })
        production.setSourcesEnabled(["shushan"], enabled: false)
        production.moveSources(["shushan"], group: "个人收藏")
        production.toggleSourcePin("shushan")
        let restored = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        XCTAssertEqual(restored.sources, production.sources)
        let demo = FeatureDemoStore()
        XCTAssertTrue(demo.isDemo)
        XCTAssertEqual(demo.sources.count, 3)
        XCTAssertFalse(demo.bookmarks.isEmpty)
    }

    func testProductionCannotGenerateSimulatedUpdates() throws {
        let domain = "com.yueshan.production.updates.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let books = try Book.load(bundle: Bundle(for: LibraryStore.self))
        let production = LibraryStore(books: books, defaults: defaults, seedDemoData: false)
        production.simulateUpdates()
        XCTAssertTrue(production.updates.isEmpty)
        XCTAssertTrue(production.progress.isEmpty)
    }
}
