import XCTest
@testable import Yueshan

@MainActor
final class NavigationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        domain = "com.yueshan.navigation-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testDefaultsKeepShelfFootprintsProfileAndIndependentSearch() {
        let store = NavigationStore(defaults: defaults)
        XCTAssertEqual(store.visibleTabs, [.shelf, .footprints, .profile])
        XCTAssertFalse(store.autoCollapse)
        XCTAssertEqual(store.validSelection(.search), .search)
        XCTAssertFalse(store.setVisible(.shelf, false))
        XCTAssertFalse(store.setVisible(.profile, false))
        XCTAssertFalse(store.setVisible(.search, true))
    }
    func testShortcutLimitDuplicateSelectionAndHiddenTabFallback() {
        let store = NavigationStore(defaults: defaults)
        XCTAssertTrue(store.setVisible(.sources, true))
        XCTAssertTrue(store.setVisible(.sources, true))
        XCTAssertFalse(store.setVisible(.tools, true))
        XCTAssertEqual(store.visibleTabs.count, 4)
        XCTAssertTrue(store.setVisible(.footprints, false))
        XCTAssertEqual(store.validSelection(.footprints), .shelf)
        XCTAssertTrue(store.setVisible(.tools, true))
        XCTAssertEqual(store.shortcuts, [.sources, .tools])
    }
    func testOrderingCollapsePreferenceAndResetSurviveRelaunch() {
        let store = NavigationStore(defaults: defaults)
        store.setVisible(.tools, true)
        store.move(.tools, by: -1)
        store.autoCollapse = true
        let restored = NavigationStore(defaults: defaults)
        XCTAssertEqual(restored.visibleTabs, [.shelf, .tools, .footprints, .profile])
        XCTAssertTrue(restored.autoCollapse)
        restored.move(.shelf, by: 1)
        restored.move(.tools, by: -1)
        XCTAssertEqual(restored.shortcuts, [.tools, .footprints])
        restored.reset()
        XCTAssertEqual(NavigationStore(defaults: defaults).visibleTabs, [.shelf, .footprints, .profile])
        XCTAssertFalse(NavigationStore(defaults: defaults).autoCollapse)
    }
    func testPersistedUnknownDuplicateAndPinnedItemsAreSanitized() {
        defaults.set(["shortcuts": ["unknown", "shelf", "tools", "tools", "search", "sources", "discover"], "autoCollapse": true], forKey: NavigationStore.storageKey)
        let store = NavigationStore(defaults: defaults)
        XCTAssertEqual(store.visibleTabs, [.shelf, .tools, .sources, .profile])
        XCTAssertTrue(store.autoCollapse)
        defaults.set("damaged", forKey: NavigationStore.storageKey)
        XCTAssertEqual(NavigationStore(defaults: defaults).shortcuts, [.footprints])
    }
    func testHeatmapUsesCompleteMondayToSundayWeeksWithoutDSTGaps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        let dates = ReadingActivity.heatmapDates(ending: today, calendar: calendar)
        XCTAssertEqual(dates.count, 84)
        XCTAssertEqual(Set(dates).count, 84)
        XCTAssertEqual(calendar.component(.weekday, from: dates[0]), 2)
        XCTAssertEqual(calendar.component(.weekday, from: dates[83]), 1)
        XCTAssertEqual(dates.filter { $0 > today }.count, 4)
        for index in 1..<dates.count {
            XCTAssertEqual(calendar.dateComponents([.day], from: dates[index - 1], to: dates[index]).day, 1)
        }
        XCTAssertTrue(ReadingActivity.heatmapDates(ending: today, weeks: 0).isEmpty)
    }
    func testDemoActivityIsDeterministicAndOnlyReferencesAvailableBooks() throws {
        let books = try Book.load(bundle: Bundle(for: LibraryStore.self))
        let today = Calendar.current.startOfDay(for: Date())
        let activity = ReadingActivity.demo(on: today, today: today, books: books)
        XCTAssertEqual(activity.minutes, 32)
        XCTAssertEqual(activity.bookIDs, [books[0].id])
        XCTAssertTrue(ReadingActivity.demo(on: today, today: today, books: []).bookIDs.isEmpty)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(ReadingActivity.demo(on: tomorrow, today: today, books: books).minutes, 0)
        for date in ReadingActivity.heatmapDates(ending: today) {
            let item = ReadingActivity.demo(on: date, today: today, books: books)
            XCTAssertTrue(item.bookIDs.allSatisfy { id in books.contains { $0.id == id } })
            XCTAssertEqual(item.minutes, ReadingActivity.demo(on: date, today: today, books: books).minutes)
        }
    }
}
