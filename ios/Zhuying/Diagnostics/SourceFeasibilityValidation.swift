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
        let businessResult: String
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
    let minimumInterval: Double
    private var lastRequestTime: Double?
    private(set) var records: [SourceValidationReport.Request] = []
    init(base: any HTTPTransport = SourceHTTPTransport(), minimumInterval: Double = 0) { self.base = base; self.minimumInterval = minimumInterval }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let lastRequestTime {
            let remaining = minimumInterval - (ProcessInfo.processInfo.systemUptime - lastRequestTime)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        }
        lastRequestTime = ProcessInfo.processInfo.systemUptime
        let started = ProcessInfo.processInfo.systemUptime
        let known = ["search", "details", "catalog", "content"]
        let endpoint = request.url?.lastPathComponent ?? ""
        let safeEndpoint = known.contains(endpoint) ? endpoint : "other"
        do {
            let (data, response) = try await base.send(request)
            let object = try? JSONSerialization.jsonObject(with: data)
            var shape = Self.shape(object)
            let payload = object as? [String: Any]
            if let status = payload?["status"] as? Int { shape += ";status=\(status)" }
            if let content = (payload?["data"] as? [String: Any])?["content"] as? String {
                let words = ["登录", "认证", "凭证", "会员", "设备", "授权", "错误", "失败", "限流", "更新", "版本", "参数", "余额", "次数", "目录", "章节", "频繁", "权限", "过期", "不存在", "未找到", "缺少", "数据", "为空", "None", "index", "item", "decode", "null", "request"]
                shape += ";content-length=\(content.utf16.count);message-flags=" + words.filter { content.contains($0) }.joined(separator: ",")
            }
            if endpoint == "catalog", let rows = payload?["data"] as? [[String: Any]], let row = rows.first(where: { $0["isVolume"] as? Bool != true }) {
                shape += ";cid-format=" + Self.identifierFormat(row["cid"])
            }
            if endpoint == "content", let body = request.httpBody, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let keys = ["book_id", "item_id", "cid", "bookid", "chapterid", "url", "version"]
                shape += ";parameter-formats=" + keys.filter { fields[$0] != nil }.map { $0 + ":" + Self.identifierFormat(fields[$0]) }.joined(separator: ",")
            }
            let error = (payload?["error"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let business = error.isEmpty ? "no-error" : error.contains("登录") || error.contains("凭证") ? "authentication-error" : (payload?["data"] as? [Any])?.isEmpty == false ? "partial-error-with-data" : "business-error"
            records.append(.init(endpoint: safeEndpoint, method: request.httpMethod ?? "GET", httpStatus: response.statusCode,
                                 responseBytes: data.count, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, shape: shape, businessResult: business))
            return (data, response)
        } catch {
            records.append(.init(endpoint: safeEndpoint, method: request.httpMethod ?? "GET", httpStatus: nil,
                                 responseBytes: 0, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, shape: "transport-error", businessResult: "not-received"))
            throw error
        }
    }
    private static func identifierFormat(_ value: Any?) -> String {
        guard let value else { return "missing" }
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        if text.isEmpty { return "empty-or-other" }
        if text.allSatisfy(\.isNumber) { return "digits-\(text.count)" }
        if text.hasPrefix("https://") || text.hasPrefix("http://") { return "url" }
        return "opaque-\(text.count)"
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
    static func queries(arguments: [String]) throws -> [String] {
        guard let index = arguments.firstIndex(of: "--source-validation-queries") else { return ["西游记", "红楼梦"] }
        guard arguments.indices.contains(index + 1) else { throw ContentFailure.invalidResponse }
        let values = arguments[index + 1].components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.count == 2, Set(values).count == 2, values.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else { throw ContentFailure.invalidResponse }
        return values
    }
    static func run(source: any BookSource, queries: [String]) async -> SourceValidationReport {
        var report = SourceValidationReport(sourceID: source.sourceID)
        var titles = Set<String>()
        do {
            for query in queries {
                try Task.checkCancellation()
                let page = try await source.search(query: query, page: 1)
                report.events.append(.init(stage: "search", query: query, result: page.hasPartialFailures ? "page-1-partial" : "page-1", count: page.books.count))
                let preferred = ["全本", "新笔趣阁", "爱下电子书", "番茄小说", "七猫小说", "QQ阅读"]
                let eligible = page.books.filter { !titles.contains($0.title) }.sorted {
                    let a = $0.title == query ? 0 : 1, b = $1.title == query ? 0 : 1
                    if a != b { return a < b }
                    return (preferred.firstIndex(of: $0.source?.provider ?? "") ?? 99) < (preferred.firstIndex(of: $1.source?.provider ?? "") ?? 99)
                }
                let available = Set(eligible.compactMap { $0.source?.provider }).sorted()
                report.events.append(.init(stage: "available-providers", query: query, result: available.joined(separator: ","), count: available.count))
                var providers = Set<String>()
                let diverse = eligible.filter { providers.insert($0.source?.provider ?? source.sourceID).inserted }
                let firstIDs = Set(diverse.map(\.id))
                let candidates = (diverse + eligible.filter { !firstIDs.contains($0.id) }).prefix(6)
                var validated: SourceValidationReport.Work?
                for candidate in candidates {
                    do {
                        let work = try await validate(candidate, source: source, events: &report.events)
                        guard !report.works.contains(where: { $0.chapters.map(\.contentHash) == work.chapters.map(\.contentHash) }) else { throw ContentFailure.invalidResponse }
                        validated = work; break
                    }
                    catch {
                        if error is CancellationError || error as? ContentFailure == .authenticationRequired { throw error }
                        report.events.append(.init(stage: "candidate-failure", query: query, result: (candidate.source?.provider ?? source.sourceID) + ":" + failureCode(error), count: nil))
                    }
                }
                guard let work = validated else {
                    report.events.append(.init(stage: "work-unavailable", query: query, result: "no-validated-three-chapter-run", count: candidates.count))
                    continue
                }
                report.works.append(work); titles.insert(work.title)
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
    private static func validate(_ book: LibraryBookRecord, source: any BookSource, events: inout [SourceValidationReport.Event]) async throws -> SourceValidationReport.Work {
        let details = try await source.details(for: book)
        guard details.id == book.id else { throw ContentFailure.invalidResponse }
        let catalog = try await source.chapters(for: details)
        events.append(.init(stage: "catalog", query: book.title,
                            result: "\(details.source?.provider ?? source.sourceID):readable=\(catalog.filter { $0.access == .readable }.count),restricted=\(catalog.filter { $0.access == .restricted }.count),volumes=\(catalog.filter { $0.access == .volume }.count)", count: catalog.count))
        guard catalog.allSatisfy({ $0.bookID == details.id }), Set(catalog.map(\.id)).count == catalog.count else { throw ContentFailure.invalidResponse }
        let entries = Array(catalog.filter { $0.access != .volume }.prefix(9))
        guard entries.count >= 3 else { throw ContentFailure.missingChapter }
        let starts = (0...(entries.count - 3)).filter { entries[$0..<$0 + 3].allSatisfy { $0.access == .readable } }
        guard !starts.isEmpty else { throw ContentFailure.restricted }
        var loaded: [String: ChapterDocument] = [:]
        for start in starts {
            var chapters: [SourceValidationReport.Chapter] = []
            for chapter in entries[start..<start + 3] {
                let document: ChapterDocument
                if let previous = loaded[chapter.id] { document = previous }
                else { document = try await source.document(for: chapter, book: details); loaded[chapter.id] = document }
                guard document.chapterID == chapter.id, !document.paragraphs.isEmpty,
                      document.paragraphs.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ContentFailure.invalidResponse }
                let length = document.paragraphs.reduce(0) { $0 + $1.text.utf16.count }
                if length < 200 { break } // A short preface may precede three full chapters.
                chapters.append(.init(id: chapter.id, title: chapter.title, order: chapter.order, paragraphCount: document.paragraphs.count,
                                      utf16Count: length, contentHash: document.version))
            }
            if chapters.count == 3 && Set(chapters.map(\.contentHash)).count == 3 {
                return .init(id: details.id, title: details.title, provider: details.source?.provider ?? source.sourceID,
                             catalogCount: catalog.count, volumeCount: catalog.filter { $0.access == .volume }.count,
                             restrictedCount: catalog.filter { $0.access == .restricted }.count, chapters: chapters)
            }
        }
        throw ContentFailure.invalidResponse
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
            case .offline: return "offline"
            case .timedOut: return "timed-out"
            case .rateLimited: return "rate-limited"
            case .sourceDisabled: return "source-disabled"
            case .cacheMiss: return "cache-miss"
            }
        }
        return "transport-or-decoding-error"
    }

    #if DEBUG
    /// Invoked only by an explicit development launch argument. Uses the app's
    /// existing in-memory account; no credential leaves its normal HTTP path.
    @MainActor static func runDevelopmentProbe(credential: ShushanCredential?, arguments: [String] = ProcessInfo.processInfo.arguments) async throws {
        let recorder = SourceValidationTransport(minimumInterval: 1)
        var report: SourceValidationReport
        if let credential {
            report = await run(source: ShushanBookSource(credential: credential, transport: recorder), queries: try queries(arguments: arguments))
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
