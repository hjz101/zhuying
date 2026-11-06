import Foundation
import Combine

enum AppTab: String, CaseIterable, Identifiable {
    case shelf, footprints, discover, sources, tools, profile, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: "书架"; case .footprints: "足迹"; case .discover: "发现"
        case .sources: "书源"; case .tools: "工具"; case .profile: "我的"; case .search: "搜索"
        }
    }
    var icon: String {
        switch self {
        case .shelf: "books.vertical"; case .footprints: "calendar"; case .discover: "safari"
        case .sources: "externaldrive"; case .tools: "square.grid.2x2"; case .profile: "person.crop.circle"; case .search: "magnifyingglass"
        }
    }
    static let optional: [AppTab] = [.footprints, .discover, .sources, .tools]
}

@MainActor
final class NavigationStore: ObservableObject {
    static let storageKey = "yueshan.navigation.v1"
    @Published private(set) var shortcuts: [AppTab]
    @Published var autoCollapse: Bool { didSet { persist() } }
    private let defaults: UserDefaults
    var visibleTabs: [AppTab] { [.shelf] + shortcuts + [.profile] }
    var canAddShortcut: Bool { shortcuts.count < 2 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let snapshot = defaults.dictionary(forKey: Self.storageKey), let values = snapshot["shortcuts"] as? [String] {
            var seen = Set<AppTab>()
            shortcuts = Array(values.compactMap(AppTab.init(rawValue:)).filter {
                AppTab.optional.contains($0) && seen.insert($0).inserted
            }.prefix(2))
            autoCollapse = snapshot["autoCollapse"] as? Bool ?? false
        } else {
            shortcuts = [.footprints]
            autoCollapse = false
        }
    }
    @discardableResult
    func setVisible(_ tab: AppTab, _ visible: Bool) -> Bool {
        guard AppTab.optional.contains(tab) else { return false }
        if visible {
            guard !shortcuts.contains(tab) else { return true }
            guard canAddShortcut else { return false }
            shortcuts.append(tab)
        } else { shortcuts.removeAll { $0 == tab } }
        persist()
        return true
    }
    func move(_ tab: AppTab, by distance: Int) {
        guard let index = shortcuts.firstIndex(of: tab), shortcuts.indices.contains(index + distance) else { return }
        shortcuts.swapAt(index, index + distance)
        persist()
    }
    func validSelection(_ selected: AppTab) -> AppTab {
        selected == .search || visibleTabs.contains(selected) ? selected : .shelf
    }
    func reset() { shortcuts = [.footprints]; autoCollapse = false; persist() }
    private func persist() {
        defaults.set(["shortcuts": shortcuts.map(\.rawValue), "autoCollapse": autoCollapse], forKey: Self.storageKey)
    }
}

struct ReadingActivity {
    let date: Date
    let minutes: Int
    let bookIDs: [String]

    static func demo(on date: Date, today: Date, books: [Book], calendar: Calendar = .current) -> ReadingActivity {
        let day = calendar.startOfDay(for: date)
        let distance = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: today)).day ?? 0
        guard distance >= 0 else { return .init(date: day, minutes: 0, bookIDs: []) }
        let pattern = [32, 24, 18, 42, 0, 12, 56, 28, 0, 35, 15, 0, 47, 20]
        let minutes = pattern[distance % pattern.count]
        return .init(date: day, minutes: minutes, bookIDs: minutes > 0 && !books.isEmpty ? [books[distance % books.count].id] : [])
    }
    static func heatmapDates(ending today: Date, weeks: Int = 12, calendar: Calendar = .current) -> [Date] {
        guard weeks > 0 else { return [] }
        let today = calendar.startOfDay(for: today)
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let start = calendar.date(byAdding: .day, value: -weekday - (weeks - 1) * 7, to: today) else { return [] }
        return (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

// Demo sessions are separate from actual reader progress and never represent tracked usage.
enum ActivityPeriod: String, CaseIterable {
    case day, week, month, year
    var title: String { switch self { case .day: "日"; case .week: "周"; case .month: "月"; case .year: "年" } }
    var comparison: String { switch self { case .day: "较昨天同时刻"; case .week: "较上周同期"; case .month: "较上月同期"; case .year: "较去年同期" } }
    var component: Calendar.Component { switch self { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year } }
    func start(containing date: Date, calendar: Calendar) -> Date {
        if self == .week {
            let offset = (calendar.component(.weekday, from: date) + 5) % 7
            return calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: date))!
        }
        return calendar.dateInterval(of: component, for: date)!.start
    }
    func previousCutoff(for date: Date, calendar: Calendar) -> Date {
        // Calendar addition clamps month ends and February 29, preserving local wall time.
        calendar.date(byAdding: component, value: -1, to: date)!
    }
}

struct ActivitySession: Codable, Equatable, Sendable {
    let bookID: String
    let start: Date
    let seconds: TimeInterval
    var kind: ReadingActivityKind? = nil
    var end: Date { start.addingTimeInterval(seconds) }
    func duration(in interval: DateInterval) -> TimeInterval {
        max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }
    static func demo(books: [Book], now: Date, calendar: Calendar) -> [ActivitySession] {
        guard !books.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        let yearStart = ActivityPeriod.year.start(containing: now, calendar: calendar)
        let start = calendar.date(byAdding: .year, value: -1, to: yearStart)!
        var result: [ActivitySession] = []
        var day = start
        while day <= today {
            let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
            if ordinal % 6 != 0 {
                for (index, hour) in [8, 13, 20].enumerated() {
                    let minutes = 5 + (ordinal + index * 11) % 24
                    let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
                    result.append(.init(bookID: books[(ordinal + index) % books.count].id, start: time, seconds: Double(minutes * 60)))
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }
}

struct ActivityBookTotal: Identifiable {
    let id: String
    let seconds: TimeInterval
}

struct ActivityReport {
    let sessions: [ActivitySession]
    let now: Date
    let period: ActivityPeriod
    var calendar: Calendar = .current
    var interval: DateInterval { .init(start: period.start(containing: now, calendar: calendar), end: now) }
    var previousInterval: DateInterval {
        let cutoff = period.previousCutoff(for: now, calendar: calendar)
        return .init(start: period.start(containing: cutoff, calendar: calendar), end: cutoff)
    }
    func total(in interval: DateInterval, bookID: String? = nil) -> TimeInterval {
        sessions.lazy.filter { bookID == nil || $0.bookID == bookID }.reduce(0) { $0 + $1.duration(in: interval) }
    }
    var seconds: TimeInterval { total(in: interval) }
    var previousSeconds: TimeInterval { total(in: previousInterval) }
    var changePercent: Int? {
        guard previousSeconds > 0 else { return nil }
        return Int(((seconds - previousSeconds) / previousSeconds * 100).rounded())
    }
    func ranking(in range: DateInterval? = nil) -> [ActivityBookTotal] {
        let range = range ?? interval
        return Set(sessions.map(\.bookID)).compactMap { id in
            let seconds = total(in: range, bookID: id)
            return seconds > 0 ? ActivityBookTotal(id: id, seconds: seconds) : nil
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }
    func dayInterval(_ date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = min(calendar.date(byAdding: .day, value: 1, to: start)!, now)
        return .init(start: min(start, end), end: end)
    }
    var elapsedDays: Int { max(1, (calendar.dateComponents([.day], from: interval.start, to: now).day ?? 0) + 1) }
    var readingDays: Int {
        (0..<elapsedDays).filter { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: interval.start)!
            return total(in: dayInterval(date)) > 0
        }.count
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if seconds > 0 && minutes == 0 { return "不足 1 分钟" }
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
}
