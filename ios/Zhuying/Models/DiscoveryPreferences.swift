import Foundation
import Combine

/// Categories retain the source's request descriptor, including its scripts and
/// request options. The title is presentation only and never used as a route.
struct SourceDiscoveryCategory: Identifiable, Equatable, Sendable {
    let title: String
    let request: String
    var id: String { StableContentID.make(title, request) }
    var isHeader: Bool { request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var readable: Bool { !isHeader }

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
                return .init(title: try string("title"), request: try string("url"))
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
            guard !title.isEmpty, seen.insert(StableContentID.make(title, request)).inserted else { return nil }
            return .init(title: title, request: request)
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
        books = []; categories = []; selected = nil; message = nil; nextPage = nil; partial = false; busy = true
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
