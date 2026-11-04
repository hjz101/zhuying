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
