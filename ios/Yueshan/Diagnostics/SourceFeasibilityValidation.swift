import Foundation

struct SourceValidationReport: Codable {
    struct Chapter: Codable {
        let id: String
        let title: String
        let order: Int
        let paragraphCount: Int
        let utf16Count: Int
        let contentHash: String
    }
    struct Work: Codable {
        let id: String
        let title: String
        let provider: String
        let catalogCount: Int
        let volumeCount: Int
        let restrictedCount: Int
        let chapters: [Chapter]
    }
    struct Event: Codable {
        let stage: String
        let query: String?
        let result: String
        let count: Int?
    }
    struct Request: Codable {
        let endpoint: String
        let method: String
        let httpStatus: Int?
        let responseBytes: Int
        let milliseconds: Double
        let shape: String
    }
    var schemaVersion = 1
    var startedAt = Date()
    var sourceID: String
    var host: String?
    var status = "running"
    var works: [Work] = []
    var events: [Event] = []
    var requests: [Request] = []
}

/// Records response structure and timing, never headers, request bodies, URL
/// queries, response values, account details or prose.
actor SourceValidationTransport: HTTPTransport {
    let base: any HTTPTransport
    private(set) var records: [SourceValidationReport.Request] = []
    init(base: any HTTPTransport = SourceHTTPTransport()) { self.base = base }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let started = ProcessInfo.processInfo.systemUptime
        let known = ["search", "details", "catalog", "content"]
        let endpoint = request.url?.lastPathComponent ?? ""
        let safeEndpoint = known.contains(endpoint) ? endpoint : "other"
        do {
            let (data, response) = try await base.send(request)
            let object = try? JSONSerialization.jsonObject(with: data)
            let shape = Self.shape(object)
            records.append(.init(endpoint: safeEndpoint, method: request.httpMethod ?? "GET", httpStatus: response.statusCode,
                                 responseBytes: data.count, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, shape: shape))
            return (data, response)
        } catch {
            records.append(.init(endpoint: safeEndpoint, method: request.httpMethod ?? "GET", httpStatus: nil,
                                 responseBytes: 0, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, shape: "transport-error"))
            throw error
        }
    }
    private static func shape(_ value: Any?, depth: Int = 0) -> String {
        guard depth < 3 else { return "…" }
        if let object = value as? [String: Any] {
            return "{" + object.keys.sorted().prefix(24).map { key in
                // Only schema keys are retained; values are represented by type.
                let known = ["code", "data", "error", "has_more", "title", "author", "source", "book_url", "bookid", "desc", "cover", "tab", "name", "isVolume", "cid", "url", "isPay", "isVip", "content", "encoding", "message", "success", "user", "api_key"]
                return (known.contains(key) ? key : "other") + ":" + shape(object[key], depth: depth + 1)
            }.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] { return "[\(array.count):" + shape(array.first, depth: depth + 1) + "]" }
        if value is String { return "string" }
        if value is NSNumber { return "number/bool" }
        return "null/other"
    }
}

enum SourceFeasibilityValidation {
    static func run(source: any BookSource, queries: [String]) async -> SourceValidationReport {
        var report = SourceValidationReport(sourceID: source.sourceID)
        var titles = Set<String>()
        do {
            for query in queries {
                try Task.checkCancellation()
                let page = try await source.search(query: query, page: 1)
                report.events.append(.init(stage: "search", query: query, result: "page-1", count: page.books.count))
                guard let book = page.books.first(where: { !titles.contains($0.title) }) else { throw ContentFailure.unavailable }
                let details = try await source.details(for: book)
                guard details.id == book.id else { throw ContentFailure.invalidResponse }
                let catalog = try await source.chapters(for: details)
                guard catalog.allSatisfy({ $0.bookID == details.id }), Set(catalog.map(\.id)).count == catalog.count else { throw ContentFailure.invalidResponse }
                let entries = catalog.filter { $0.access != .volume }
                guard entries.count >= 3, let start = (0...(entries.count - 3)).first(where: {
                    entries[$0..<$0 + 3].allSatisfy { $0.access == .readable }
                }) else { throw ContentFailure.restricted }
                var chapters: [SourceValidationReport.Chapter] = []
                for chapter in entries[start..<start + 3] {
                    let document = try await source.document(for: chapter, book: details)
                    guard document.chapterID == chapter.id, !document.paragraphs.isEmpty,
                          document.paragraphs.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ContentFailure.invalidResponse }
                    chapters.append(.init(id: chapter.id, title: chapter.title, order: chapter.order,
                                          paragraphCount: document.paragraphs.count,
                                          utf16Count: document.paragraphs.reduce(0) { $0 + $1.text.utf16.count }, contentHash: document.version))
                }
                guard Set(chapters.map(\.contentHash)).count == 3 else { throw ContentFailure.invalidResponse }
                report.works.append(.init(id: details.id, title: details.title, provider: details.source?.provider ?? source.sourceID,
                                          catalogCount: catalog.count, volumeCount: catalog.filter { $0.access == .volume }.count,
                                          restrictedCount: catalog.filter { $0.access == .restricted }.count, chapters: chapters))
                titles.insert(details.title)
                // Probe page 2 explicitly; do not infer support from a nonempty page 1.
                let second = try await source.search(query: query, page: 2)
                let repeated = Set(second.books.map(\.id)).intersection(Set(page.books.map(\.id))).count
                let policy = second.books.isEmpty ? "page-2-empty" : repeated == second.books.count ? "page-2-repeats" : "page-2-has-new-results"
                report.events.append(.init(stage: "pagination", query: query, result: policy, count: second.books.count))
            }
            guard report.works.count >= 2, Set(report.works.map(\.id)).count == report.works.count,
                  Set(report.works.map(\.title)).count == report.works.count else { throw ContentFailure.invalidResponse }
            report.status = "passed"
        } catch {
            report.status = error is CancellationError ? "cancelled" : "failed"
            report.events.append(.init(stage: "failure", query: nil, result: failureCode(error), count: nil))
        }
        return report
    }
    static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? ContentFailure {
            switch failure {
            case .authenticationRequired: return "authentication-required"
            case .unavailable: return "unavailable"
            case .restricted: return "restricted"
            case .missingChapter: return "missing-chapter"
            case .invalidResponse: return "invalid-response"
            case .storageFailure: return "storage-failure"
            }
        }
        return "transport-or-decoding-error"
    }

    #if DEBUG
    /// Invoked only by an explicit development launch argument. Uses the app's
    /// existing in-memory account; no credential leaves its normal HTTP path.
    @MainActor static func runDevelopmentProbe(credential: ShushanCredential?) async throws {
        let recorder = SourceValidationTransport()
        var report: SourceValidationReport
        if let credential {
            report = await run(source: ShushanBookSource(credential: credential, transport: recorder), queries: ["西游记", "红楼梦"])
            report.host = try? ShushanClient.host(credential.host.absoluteString).absoluteString
            let unauthenticated = ShushanBookSource(credential: .init(host: credential.host, apiKey: "", nickname: ""), transport: recorder)
            do {
                _ = try await unauthenticated.search(query: "西游记", page: 1)
                report.events.append(.init(stage: "authentication-probe", query: nil, result: "search-allows-no-credential", count: nil))
            } catch {
                let code = failureCode(error)
                report.events.append(.init(stage: "authentication-probe", query: nil, result: code, count: nil))
                if code != "authentication-required" { report.status = "failed" }
            }
        } else {
            report = SourceValidationReport(sourceID: "shushan")
            report.status = "authentication-required"
        }
        report.requests = await recorder.records
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DevelopmentValidation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("source-feasibility.json"), options: .atomic)
    }
    #endif
}
