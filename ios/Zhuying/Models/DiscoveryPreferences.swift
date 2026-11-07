import Foundation
import Combine

struct SourceDiscoveryFilter: Equatable, Sendable {
    let choices: [String]
    let selectedValue: String
    let action: String
}

struct SourceDiscoveryFilterResult: Sendable {
    let categories: [SourceDiscoveryCategory]
    var feedback: String? = nil
}

/// Categories retain the source's request descriptor, including its scripts and
/// request options. The title is presentation only and never used as a route.
struct SourceDiscoveryCategory: Identifiable, Equatable, Sendable {
    let title: String
    let request: String
    var filter: SourceDiscoveryFilter? = nil
    var id: String { StableContentID.make(title, request, filter?.action ?? "") }
    var isFilter: Bool { filter != nil }
    var isHeader: Bool { filter == nil && request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var readable: Bool { filter == nil && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func parse(_ text: String) throws -> [Self] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 512 * 1024 else { throw LegadoCompatibilityError.limit }
        guard !value.isEmpty else { return [] }
        let rows: [Self]
        if value.hasPrefix("[") {
            guard let array = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]], array.count <= 512 else { throw LegadoCompatibilityError.invalid("exploreUrl 分类列表") }
            rows = try array.map { row in
                // Original ExploreKind permits a missing/null URL for a group
                // heading. A heading is display text, never an inferred route.
                func string(_ key: String) throws -> String {
                    guard let field = row[key], !(field is NSNull) else { return "" }
                    guard let text = field as? String else { throw LegadoCompatibilityError.invalid("exploreUrl 分类名称或地址") }
                    return text
                }
                let title = try string("title"), request = try string("url")
                var filter: SourceDiscoveryFilter?
                if try string("type").lowercased() == "select" {
                    guard let raw = row["chars"] ?? row["choices"], let values = raw as? [String],
                          values.count <= 512,
                          values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 }),
                          values.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024 else {
                        throw LegadoCompatibilityError.invalid("exploreUrl 筛选选项")
                    }
                    let action = try string("action")
                    guard !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action.utf8.count <= 64 * 1024 else {
                        throw LegadoCompatibilityError.invalid("exploreUrl 筛选操作")
                    }
                    let initial = try string("default")
                    var seen = Set<String>()
                    let choices = values.filter { seen.insert($0).inserted }
                    filter = .init(choices: choices, selectedValue: initial.isEmpty ? choices.first ?? "" : initial, action: action)
                }
                return .init(title: title, request: request, filter: filter)
            }
        } else {
            let parts = value.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: "&&") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard parts.count <= 512 else { throw LegadoCompatibilityError.limit }
            rows = parts.map { part in
                // Retain the existing direct HTTP(S) endpoint shorthand while
                // leaving ordinary title-only lines as inert headings.
                if ["http://", "https://"].contains(where: { part.lowercased().hasPrefix($0) }), let url = URL(string: part),
                   url.host?.isEmpty == false, url.user == nil, url.password == nil {
                    return .init(title: "全部", request: part)
                }
                guard let separator = part.range(of: "::") else { return .init(title: part, request: "") }
                return .init(title: String(part[..<separator.lowerBound]), request: String(part[separator.upperBound...]))
            }
        }
        var seen = Set<String>()
        return try rows.compactMap { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines), request = row.request.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.utf8.count <= 2048, request.utf8.count <= 64 * 1024 else { throw LegadoCompatibilityError.limit }
            guard !title.isEmpty, seen.insert(StableContentID.make(title, request, row.filter?.action ?? "")).inserted else { return nil }
            return .init(title: title, request: request, filter: row.filter)
        }
    }
}

enum BookSearchMatching {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }
    static func exact(_ query: String, title: String, author: String) -> Bool {
        let key = normalized(query)
        return !key.isEmpty && (normalized(title) == key || normalized(author) == key)
    }
}

@MainActor final class OnlineDiscoveryStore: ObservableObject {
    @Published private(set) var categories: [SourceDiscoveryCategory] = []
    @Published private(set) var selected: SourceDiscoveryCategory?
    @Published private(set) var books: [LibraryBookRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var nextPage: Int?
    @Published private(set) var partial = false
    @Published private(set) var feedback: String?
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var sourceID = ""

    func open(sourceID: String, service: OnlineReadingService) {
        let previous = self.sourceID == sourceID ? selected : nil
        cancel(); self.sourceID = sourceID
        let revision = generation
        books = []; categories = []; selected = nil; message = nil; nextPage = nil; partial = false; feedback = nil; busy = true
        operation = Task { [weak self] in
            do {
                let categories = try await service.discoveryCategories(sourceID: sourceID)
                try Task.checkCancellation(); guard let self, self.generation == revision else { return }
                self.categories = categories; self.busy = false
                if let first = categories.first(where: { $0 == previous && $0.readable }) ?? categories.first(where: \.readable) { self.select(first, service: service) }
                else { self.message = categories.isEmpty ? "此书源暂未返回发现分类，请登录后刷新。" : "此书源仅提供分类说明，暂未提供可打开的分类。" }
            } catch {
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                self.message = error.localizedDescription; self.busy = false
            }
        }
    }
    func select(_ category: SourceDiscoveryCategory, service: OnlineReadingService) {
        guard category.readable else { return }
        cancel(); selected = category; books = []; nextPage = nil; partial = false
        load(page: 1, category: category, service: service)
    }
    /// Called only after the user confirms a choice. Existing books remain
    /// visible until the action, regenerated categories and new page succeed.
    func applyFilter(_ category: SourceDiscoveryCategory, value: String, service: OnlineReadingService) {
        guard !busy, let filter = category.filter, filter.choices.contains(value),
              categories.contains(where: { $0.id == category.id }) else { return }
        cancel()
        let revision = generation, sourceID = sourceID, previous = selected
        busy = true; message = nil; feedback = nil
        operation = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await service.applyDiscoveryFilter(sourceID: sourceID, category: category, value: value)
                try Task.checkCancellation(); guard let self, self.generation == revision else { return }
                let refreshed = result.categories
                let next = refreshed.first(where: { $0.readable && $0.title == previous?.title })
                    ?? refreshed.first(where: { $0.readable && $0.id == previous?.id })
                    ?? refreshed.first(where: \.readable)
                let page: BookSearchPage?
                if let next { page = try await service.discover(category: next.request, page: 1, subscribed: [sourceID]) }
                else { page = nil }
                try Task.checkCancellation(); guard self.generation == revision else { return }
                self.categories = refreshed; self.selected = next
                if let page {
                    var seen = Set<String>()
                    self.books = page.books.filter { seen.insert($0.id).inserted }
                    self.nextPage = page.nextPage; self.partial = page.hasPartialFailures
                } else { self.books = []; self.nextPage = nil; self.partial = false }
                self.feedback = page?.feedback ?? result.feedback; self.busy = false
            } catch {
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                self.message = error.localizedDescription; self.busy = false
            }
        }
    }
    func more(service: OnlineReadingService) {
        guard !busy, let nextPage, let selected else { return }
        load(page: nextPage, category: selected, service: service)
    }
    func refresh(service: OnlineReadingService) {
        if let selected { select(selected, service: service) } else { open(sourceID: sourceID, service: service) }
    }
    func cancel() { generation += 1; operation?.cancel(); operation = nil; busy = false }
    private func load(page: Int, category: SourceDiscoveryCategory, service: OnlineReadingService) {
        let revision = generation, sourceID = sourceID
        busy = true; message = nil; feedback = nil
        operation = Task { [weak self] in
            do {
                let result = try await service.discover(category: category.request, page: page, subscribed: [sourceID])
                try Task.checkCancellation(); guard let self, self.generation == revision else { return }
                var seen = Set(self.books.map(\.id))
                let additions = result.books.filter { seen.insert($0.id).inserted }
                self.books += additions; self.nextPage = page > 1 && additions.isEmpty ? nil : result.nextPage
                self.partial = result.hasPartialFailures; self.feedback = result.feedback; self.busy = false
            } catch {
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                self.message = error.localizedDescription; self.busy = false
            }
        }
    }
}
