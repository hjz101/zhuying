import Foundation
import Combine

@MainActor final class SourceQuickActions: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var refreshingSourceID: String?
    private var operation: Task<Void, Never>?
    private var revision = UUID()

    func refresh(_ source: DemoSource, demo: Bool, perform: @escaping @MainActor () async throws -> Void) {
        cancel(); message = nil
        if demo { message = "已刷新演示书源，未发送网络请求。"; return }
        let token = UUID(); revision = token; refreshingSourceID = source.id
        operation = Task {
            defer { if revision == token { refreshingSourceID = nil; operation = nil } }
            do {
                try await perform(); try Task.checkCancellation()
                if revision == token { message = "已刷新“\(source.name)”的规则与运行状态。" }
            } catch { if revision == token, !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    func cancel() { operation?.cancel(); operation = nil; revision = UUID(); refreshingSourceID = nil }
}

/// Source identities may be opaque. Only actual declared addresses are usable
/// as browser destinations; never treat the identity string as a URL.
enum SourceBrowserStart {
    static func urls(_ source: DemoSource) -> [URL] {
        var values: [URL] = []
        if let url = URL(string: source.url), (try? LegadoSourcePolicy.canonicalOrigin(url)) != nil { values.append(url) }
        if let definition = try? SourcePackages.legadoDefinition(source) {
            if let base = definition.baseURL { values.append(base) }
            values += definition.policy.allowedOrigins
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.absoluteString).inserted }
    }
}
