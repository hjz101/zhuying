import Foundation

struct SourceDiagnosticResult: Codable, Identifiable, Sendable {
    var id: String { sourceID + step }
    let sourceID: String
    let step: String
    let status: String
    let milliseconds: Int
    let count: Int
}
enum SourceDiagnostics {
    enum Step: String, CaseIterable, Sendable { case search = "搜索", details = "详情", catalog = "目录", content = "正文" }
    static func run(source: any BookSource, query: String, through target: Step, timeout: Double = 15) async throws -> [SourceDiagnosticResult] {
        try await execute(source:source,query:query,through:target,timeout:max(1,min(60,timeout)))
    }
    private static func execute(source: any BookSource, query: String, through target: Step,timeout: Double) async throws -> [SourceDiagnosticResult] {
        var result: [SourceDiagnosticResult] = [], current = Step.search
        var start = ProcessInfo.processInfo.systemUptime
        func record(_ count: Int) {
            result.append(.init(sourceID:source.sourceID,step:current.rawValue,status:"成功",milliseconds:Int((ProcessInfo.processInfo.systemUptime - start) * 1000),count:count))
        }
        do {
            let page = try await AsyncOperationDeadline.run(seconds:timeout) { try await source.search(query:query,page:1) }; record(page.books.count)
            if target == .search { return result }
            guard let book = page.books.first else { throw ContentFailure.invalidResponse }
            current = .details; start = ProcessInfo.processInfo.systemUptime
            let details = try await AsyncOperationDeadline.run(seconds:timeout) { try await source.details(for:book) }; record(1)
            if target == .details { return result }
            current = .catalog; start = ProcessInfo.processInfo.systemUptime
            let chapters = try await AsyncOperationDeadline.run(seconds:timeout) { try await source.chapters(for:details) }; record(chapters.count)
            if target == .catalog { return result }
            guard let chapter = chapters.first(where: { $0.access == .readable }) else { throw ContentFailure.restricted }
            current = .content; start = ProcessInfo.processInfo.systemUptime
            let document = try await AsyncOperationDeadline.run(seconds:timeout) { try await source.document(for:chapter,book:details) }; try Task.checkCancellation()
            record(document.paragraphs.reduce(0) { $0 + $1.text.utf16.count }); return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.append(.init(sourceID:source.sourceID,step:current.rawValue,status:error as? ContentFailure == .timedOut ? "超时" : "失败",milliseconds:Int((ProcessInfo.processInfo.systemUptime - start) * 1000),count:0))
            return result
        }
    }
    static func batch(sources: [any BookSource], query: String, concurrency: Int, timeout: Double) async throws -> [SourceDiagnosticResult] {
        var all: [SourceDiagnosticResult] = []
        try await withThrowingTaskGroup(of:[SourceDiagnosticResult].self) { group in
            var cursor = 0
            func enqueue() {
                guard cursor < sources.count else { return }; let source = sources[cursor]; cursor += 1
                group.addTask {
                    do { return try await run(source:source,query:query,through:.content,timeout:timeout) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return [.init(sourceID:source.sourceID,step:"超时保护",status:"超时",milliseconds:Int(timeout * 1000),count:0)] }
                }
            }
            for _ in 0..<min(max(1,min(10,concurrency)),sources.count) { enqueue() }
            while let result = try await group.next() { try Task.checkCancellation(); all += result; enqueue() }
        }
        return all
    }
}
