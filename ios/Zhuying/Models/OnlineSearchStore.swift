import Foundation
import Combine

@MainActor final class OnlineSearchStore: ObservableObject {
    @Published private(set) var results: [LibraryBookRecord] = []
    @Published private(set) var query = ""
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var partial = false
    @Published private(set) var nextPage: Int?
    @Published private(set) var sourceReports: [SourceSearchReport] = []
    private var generation = 0
    private var operation: Task<Void, Never>?
    func search(_ text: String, service: OnlineReadingService, debounce: Bool = true) {
        operation?.cancel(); generation += 1
        let revision = generation
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; message = nil; partial = false; nextPage = nil; sourceReports = []; busy = !query.isEmpty
        guard !query.isEmpty else { return }
        let requested = query
        operation = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                let page = try await service.search(query: requested, page: 1)
                try Task.checkCancellation(); guard let self, self.generation == revision else { return }
                self.accept(page, replacing: true); self.busy = false
            } catch {
                guard let self, self.generation == revision, !(error is CancellationError) else { return }
                self.message = error.localizedDescription; self.busy = false
            }
        }
    }
    func more(service: OnlineReadingService) {
        guard !busy, let nextPage else { return }
        busy = true; message = nil
        let revision = generation, requested = query
        operation = Task { [weak self] in
            do {
                let page = try await service.search(query: requested, page: nextPage)
                try Task.checkCancellation(); guard let self, self.generation == revision else { return }
                self.accept(page, replacing: false); self.busy = false
            } catch {
                guard let self, self.generation == revision, !(error is CancellationError) else { return }
                self.message = error.localizedDescription; self.busy = false
            }
        }
    }
    func cancel() { generation += 1; operation?.cancel(); operation = nil; busy = false }
    private func accept(_ page: BookSearchPage, replacing: Bool) {
        var seen = Set(replacing ? [] : results.map(\.id))
        let new = page.books.filter { seen.insert($0.id).inserted }
        if replacing { results = new } else { results.append(contentsOf: new) }
        nextPage = !replacing && new.isEmpty ? nil : page.nextPage
        partial = partial || page.hasPartialFailures
        sourceReports = page.sourceReports
    }
}
