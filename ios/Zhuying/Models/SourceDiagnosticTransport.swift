import Foundation

/// A fresh recorder belongs to one diagnostic provider. No request addresses,
/// headers, payloads or response text are retained in the exported evidence.
actor SourceDiagnosticHTTPTransport: HTTPTransport {
    let base: any HTTPTransport
    private var evidence = SourceDiagnosticNetworkEvidence()
    private var failure: [String: String]?
    func failureSnapshot() -> [String: String]? { failure }
    func recordFailure(_ error: Error, operation: String) {
        var tags = ["operation": operation]
        if let wrapped = error as? LegadoRuleExecutionError {
            tags["field"] = wrapped.field.rawValue
            if let input = wrapped.inputSummary {
                tags["serializedInputType"] = input.root.rawValue; tags["abstractType"] = input.abstract.rawValue
                tags["dataType"] = input.data.rawValue; tags["hasCode"] = input.hasCode ? "true" : "false"
            }
        }
        if let summary = SourceDiagnosticJavaScriptSummary.from(error) {
            tags["jsKind"] = summary.kind.rawValue; tags["reason"] = summary.reason.rawValue
            tags["missingGlobal"] = summary.missingGlobal
        }
        let error = LegadoRuleExecutionError.unwrapped(error)
        let category: String
        if let error = error as? LegadoRequestError {
            switch error { case .limit: category = "requestLimit"; case .searchResultLimit: category = "searchResultLimit"; case .scriptEvaluationLimit: category = "scriptEvaluationLimit"; case .invalid: category = "requestInvalid"; case .unsupported: category = "requestUnsupported" }
        } else if let error = error as? LegadoCompatibilityError {
            switch error { case .limit: category = "ruleLimit"; case .invalid: category = "ruleInvalid"; case .unsupported: category = "ruleUnsupported" }
        } else if let error = error as? QuickJSScriptError {
            switch error { case .javascript: category = "javascript"; case .memoryLimit: category = "memoryLimit"; case .bridgeLimit: category = "bridgeLimit"; case .timedOut, .memoryBudgetTimedOut: category = "timedOut"; default: category = "scriptUnavailable" }
        } else if error is ContentFailure { category = "contentFailure" }
        else if error is CancellationError { category = "cancelled" }
        else { category = "unclassified" }
        tags["category"] = category
        failure = tags
    }
    init(base: any HTTPTransport) { self.base = base }
    func snapshot() -> SourceDiagnosticNetworkEvidence { evidence }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await base.send(request)
            try Task.checkCancellation()
            if (200..<300).contains(response.statusCode) { evidence.successfulFetches += 1 }
            else { evidence.failedFetches += 1 }
            evidence.bytes += bytes.count
            return (bytes, response)
        } catch {
            evidence.failedFetches += 1
            throw error
        }
    }
}

struct SourceDiagnosticBookSource: SourceDiagnosticEvidenceProvider {
    let base: any BookSource
    let recorder: SourceDiagnosticHTTPTransport
    var sourceID: String { base.sourceID }
    func diagnosticNetworkEvidence() async -> SourceDiagnosticNetworkEvidence { await recorder.snapshot() }
    func search(query: String, page: Int) async throws -> BookSearchPage {
        do { return try await base.search(query: query, page: page) }
        catch { await recorder.recordFailure(error, operation: "search"); throw error }
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord {
        do { return try await base.details(for: book) }
        catch { await recorder.recordFailure(error, operation: "details"); throw error }
    }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] {
        do { return try await base.chapters(for: book) }
        catch { await recorder.recordFailure(error, operation: "catalog"); throw error }
    }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        do { return try await base.document(for: chapter, book: book) }
        catch { await recorder.recordFailure(error, operation: "content"); throw error }
    }
}
