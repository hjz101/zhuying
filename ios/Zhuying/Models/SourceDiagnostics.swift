import Foundation

struct SourceDiagnosticResult: Codable, Identifiable, Sendable {
    var id: String { StableContentID.make(sourceID, step, String(bookIndex ?? -1), String(chapterIndex ?? -1)) }
    let sourceID: String
    let step: String
    let status: String
    let milliseconds: Int
    let count: Int
    var issue: SourceDiagnosticIssue? = nil
    var network: SourceDiagnosticNetworkEvidence? = nil
    var bookIndex: Int? = nil
    var chapterIndex: Int? = nil
}

enum SourceDiagnostics {
    enum Step: String, CaseIterable, Codable, Sendable { case search = "搜索", details = "详情", catalog = "目录", content = "正文" }
    static func networkSnapshot(_ source: any BookSource) async -> SourceDiagnosticNetworkEvidence? {
        await (source as? any SourceDiagnosticEvidenceProvider)?.diagnosticNetworkEvidence()
    }
    static func networkDelta(_ source: any BookSource, since before: SourceDiagnosticNetworkEvidence?) async -> SourceDiagnosticNetworkEvidence? {
        guard let before, let after = await networkSnapshot(source) else { return nil }
        return after.delta(since: before)
    }
    static func result(sourceID: String, step: String, start: TimeInterval, count: Int = 0, issue: SourceDiagnosticIssue? = nil,
                       network: SourceDiagnosticNetworkEvidence? = nil, book: Int? = nil, chapter: Int? = nil) -> SourceDiagnosticResult {
        let status = issue.map { $0.code == .timedOut ? "超时" : $0.code == .cancelled ? "取消" : "失败" } ?? "成功"
        return .init(sourceID: sourceID, step: step, status: status, milliseconds: max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000)), count: count,
                     issue: issue, network: network, bookIndex: book, chapterIndex: chapter)
    }
    static func run(source: any BookSource, query: String, through target: Step, timeout: Double = 15, authStatus: LegadoAuthStatus? = nil) async throws -> [SourceDiagnosticResult] {
        let timeout = max(1, min(60, timeout))
        var results: [SourceDiagnosticResult] = [], current = Step.search
        var start = ProcessInfo.processInfo.systemUptime, before = await networkSnapshot(source)
        func check(_ value: Bool, issue: SourceDiagnosticIssue.Code) throws { if !value { throw SourceDiagnosticFailure(issue: .init(code: issue)) } }
        func usableNetwork() async throws -> SourceDiagnosticNetworkEvidence? {
            let network = await networkDelta(source, since: before)
            try check((network?.failedFetches ?? 0) == 0 || (network?.successfulFetches ?? 0) > 0, issue: .unavailable)
            return network
        }
        do {
            let page = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.search(query: query, page: 1) }
            try check(!page.books.isEmpty, issue: .noSearchResults)
            results.append(result(sourceID: source.sourceID, step: current.rawValue, start: start, count: page.books.count, network: try await usableNetwork()))
            if target == .search { return results }
            guard let book = page.books.first else { return results }
            current = .details; start = ProcessInfo.processInfo.systemUptime; before = await networkSnapshot(source)
            let details = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.details(for: book) }
            results.append(result(sourceID: source.sourceID, step: current.rawValue, start: start, count: 1, network: try await usableNetwork()))
            if target == .details { return results }
            current = .catalog; start = ProcessInfo.processInfo.systemUptime; before = await networkSnapshot(source)
            let chapters = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.chapters(for: details) }
            try check(chapters.contains { $0.access == .readable }, issue: .emptyCatalog)
            results.append(result(sourceID: source.sourceID, step: current.rawValue, start: start, count: chapters.count, network: try await usableNetwork()))
            if target == .catalog { return results }
            guard let chapter = chapters.first(where: { $0.access == .readable }) else { return results }
            current = .content; start = ProcessInfo.processInfo.systemUptime; before = await networkSnapshot(source)
            let document = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.document(for: chapter, book: details) }
            try Task.checkCancellation()
            try check(document.chapterID == chapter.id && document.paragraphs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, issue: .emptyContent)
            results.append(result(sourceID: source.sourceID, step: current.rawValue, start: start, count: document.paragraphs.reduce(0) { $0 + $1.text.utf16.count }, network: try await usableNetwork()))
            return results
        } catch is CancellationError { throw CancellationError() }
        catch {
            let issue: SourceDiagnosticIssue
            if current == .catalog, error as? ContentFailure == .missingChapter { issue = .init(code: .emptyCatalog) }
            else { issue = .classify(error, authStatus: authStatus) }
            results.append(result(sourceID: source.sourceID, step: current.rawValue, start: start, issue: issue, network: await networkDelta(source, since: before)))
            return results
        }
    }
    static func batch(sources: [any BookSource], query: String, concurrency: Int, timeout: Double) async throws -> [SourceDiagnosticResult] {
        var all: [SourceDiagnosticResult] = []
        try await withThrowingTaskGroup(of: [SourceDiagnosticResult].self) { group in
            var cursor = 0
            func enqueue() {
                guard cursor < sources.count else { return }; let source = sources[cursor]; cursor += 1
                group.addTask { try await run(source: source, query: query, through: .content, timeout: timeout) }
            }
            for _ in 0..<min(max(1, min(10, concurrency)), sources.count) { enqueue() }
            while let result = try await group.next() { try Task.checkCancellation(); all += result; enqueue() }
        }
        return all
    }
    /// Query, URLs, content and opaque provider IDs are absent from exports.
    static func export(_ reports: [SourceDiagnosticResult]) throws -> Data {
        struct Row: Encodable {
            let sourceHash: String; let step: String; let status: String; let milliseconds: Int; let count: Int
            let issue: SourceDiagnosticIssue?; let network: SourceDiagnosticNetworkEvidence?
            let bookIndex: Int?; let chapterIndex: Int?
        }
        let rows = reports.map { Row(sourceHash: StableContentID.make($0.sourceID), step: safeStep($0.step), status: ["成功", "失败", "取消", "超时"].contains($0.status) ? $0.status : "失败",
                                     milliseconds: $0.milliseconds, count: $0.count, issue: $0.issue, network: $0.network, bookIndex: $0.bookIndex, chapterIndex: $0.chapterIndex) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }
    static func safeStep(_ step: String) -> String { Step.allCases.map(\.rawValue).contains(step) || ["配置", "完整验收", "重启复核"].contains(step) ? step : "调试" }
}
