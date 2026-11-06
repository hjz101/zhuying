import XCTest
@testable import Zhuying

@MainActor
final class NavigationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        domain = "com.zhuying.navigation-tests.\(UUID().uuidString)"
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

final class ActivityStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ year: Int = 2026, _ month: Int = 11, _ day: Int = 5, _ hour: Int = 14, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    func testPartialSessionsAndSameTimeYesterdayComparison() {
        let now = date()
        let sessions: [ActivitySession] = [
            .init(bookID: "a", start: date(2026, 11, 5, 13, 50), seconds: 1200),
            .init(bookID: "b", start: date(2026, 11, 5, 20), seconds: 3600),
            .init(bookID: "a", start: date(2026, 11, 4, 13, 55), seconds: 1200),
            .init(bookID: "b", start: date(2026, 11, 4, 20), seconds: 3600)
        ]
        let report = ActivityReport(sessions: sessions, now: now, period: .day, calendar: calendar)
        XCTAssertEqual(report.seconds, 600)
        XCTAssertEqual(report.previousSeconds, 300)
        XCTAssertEqual(report.changePercent, 100)
        XCTAssertEqual(report.ranking().map(\.id), ["a"])
        XCTAssertEqual(report.ranking().reduce(0) { $0 + $1.seconds }, report.seconds)
    }
    func testWeekMonthYearBoundariesAndLeapDayClamp() {
        for (period, start) in [(ActivityPeriod.week, date(2026, 11, 2, 0)), (.month, date(2026, 11, 1, 0)), (.year, date(2026, 1, 1, 0))] {
            let report = ActivityReport(sessions: [], now: date(), period: period, calendar: calendar)
            XCTAssertEqual(report.interval.start, start)
            XCTAssertEqual(calendar.component(.hour, from: report.previousInterval.end), 14)
            XCTAssertNil(report.changePercent)
        }
        XCTAssertEqual(ActivityPeriod.month.previousCutoff(for: date(2026, 3, 31), calendar: calendar), date(2026, 2, 28))
        XCTAssertEqual(ActivityPeriod.year.previousCutoff(for: date(2024, 2, 29), calendar: calendar), date(2023, 2, 28))
        XCTAssertEqual(ActivityPeriod.week.start(containing: date(2027, 1, 1), calendar: calendar), date(2026, 12, 28, 0))
    }
    func testRankingRetainsAllBookIDsAndCountsCrossMidnightSessions() {
        let sessions: [ActivitySession] = [
            .init(bookID: "removed", start: date(2026, 11, 4, 23, 50), seconds: 1200),
            .init(bookID: "b", start: date(2026, 11, 5, 8), seconds: 600),
            .init(bookID: "a", start: date(2026, 11, 5, 9), seconds: 600)
        ]
        let report = ActivityReport(sessions: sessions, now: date(), period: .day, calendar: calendar)
        XCTAssertEqual(report.seconds, 1800)
        XCTAssertEqual(report.ranking().map(\.id), ["a", "b", "removed"])
        XCTAssertEqual(report.readingDays, 1)
        XCTAssertEqual(report.total(in: report.dayInterval(date(2026, 11, 6))), 0)
        XCTAssertEqual(ActivityReport.duration(30), "不足 1 分钟")
    }
    func testCalendarDaysAcrossDSTAndStableDemoHistory() throws {
        var la = calendar
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = la.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let report = ActivityReport(sessions: [], now: now, period: .month, calendar: la)
        XCTAssertEqual(report.dayInterval(la.date(byAdding: .day, value: -1, to: now)!).duration, 25 * 3600)
        let books = try Book.load(bundle: Bundle(for: LibraryStore.self))
        let sessions = ActivitySession.demo(books: books, now: date(), calendar: calendar)
        let tomorrow = ActivitySession.demo(books: books, now: date(2026, 11, 6), calendar: calendar)
        let range = DateInterval(start: date(2026, 10, 1, 0), end: date(2026, 11, 1, 0))
        let original = ActivityReport(sessions: sessions, now: date(), period: .year, calendar: calendar)
        let next = ActivityReport(sessions: tomorrow, now: date(2026, 11, 6), period: .year, calendar: calendar)
        XCTAssertEqual(original.total(in: range), next.total(in: range))
        XCTAssertTrue(ActivitySession.demo(books: [], now: date(), calendar: calendar).isEmpty)
        XCTAssertEqual(original.ranking().reduce(0) { $0 + $1.seconds }, original.seconds)
    }
}
