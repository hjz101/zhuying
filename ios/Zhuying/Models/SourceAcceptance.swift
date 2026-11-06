import Foundation

struct SourceDiagnosticScope: Sendable {
    let sourceID: String
    var accountID = "default"
    var libraryProfile = "production"
    var configurationHash = StableContentID.make("unconfigured")
    var sessionEpoch: UInt64 = 0
    var id: String { StableContentID.make("source-diagnostic-v1", sourceID, accountID, libraryProfile) }
}
enum SourceDiagnosticProcess { static let id = UUID() }
enum SourceDiagnosticEvidenceKind: String, Codable, Sendable { case nativeNetwork, controlledFixture }

struct SourceAcceptanceChapter: Codable, Equatable, Sendable {
    let identityHash: String
    let versionHash: String
    let characters: Int
}
struct SourceAcceptanceBook: Codable, Equatable, Sendable {
    let identityHash: String
    let workHash: String
    let chapters: [SourceAcceptanceChapter]
}
struct SourceAcceptanceStep: Codable, Sendable {
    let step: SourceDiagnostics.Step
    let bookIndex: Int?
    let chapterIndex: Int?
    let milliseconds: Int
    let count: Int
    let network: SourceDiagnosticNetworkEvidence?
    let issue: SourceDiagnosticIssue?
    init(_ report: SourceDiagnosticResult, step: SourceDiagnostics.Step) {
        self.step = step; bookIndex = report.bookIndex; chapterIndex = report.chapterIndex; milliseconds = report.milliseconds
        count = report.count; network = report.network; issue = report.issue
    }
    func result(sourceID: String) -> SourceDiagnosticResult {
        .init(sourceID: sourceID, step: step.rawValue, status: issue == nil ? "成功" : issue?.code == .timedOut ? "超时" : "失败",
              milliseconds: milliseconds, count: count, issue: issue, network: network, bookIndex: bookIndex, chapterIndex: chapterIndex)
    }
}
struct SourceAcceptanceReport: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case failed, awaitingRestart, verificationFailed, restartVerified }
    var version = 1
    let id: UUID
    let scopeHash: String
    let initialProcessID: UUID
    let createdAt: Date
    let evidenceKind: SourceDiagnosticEvidenceKind
    let configurationHash: String
    let sessionHash: String
    let engineVersion: String
    var status: Status = .failed
    var books: [SourceAcceptanceBook] = []
    var initialSteps: [SourceAcceptanceStep] = []
    var verificationProcessID: UUID?
    var verifiedAt: Date?
    var verificationSteps: [SourceAcceptanceStep] = []
    var issue: SourceDiagnosticIssue?
    var canVerifyRestart: Bool { status != .failed && books.count == 2 && books.allSatisfy { $0.chapters.count == 3 } }
}

actor SourceAcceptanceStore {
    let directory: URL
    private let writer: any AtomicFileWriting
    init(directory: URL, writer: any AtomicFileWriting = AtomicFileWriter()) { self.directory = directory; self.writer = writer }
    func load(scope: SourceDiagnosticScope) throws -> SourceAcceptanceReport? {
        let url = directory.appendingPathComponent(scope.id + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true, (metadata.fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
            data = try Data(contentsOf: url)
        }
        catch { throw SourceDiagnosticFailure(issue: .init(code: .stateUnavailable)) }
        guard data.count <= 2 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
        let report = try JSONDecoder().decode(SourceAcceptanceReport.self, from: data)
        try validate(report, scope: scope); return report
    }
    func save(_ report: SourceAcceptanceReport, scope: SourceDiagnosticScope) throws {
        try validate(report, scope: scope)
        let data = try JSONEncoder().encode(report)
        guard data.count <= 2 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writer.write(data, to: directory.appendingPathComponent(scope.id + ".json"))
        } catch { throw SourceDiagnosticFailure(issue: .init(code: .stateUnavailable)) }
    }
    private func validate(_ report: SourceAcceptanceReport, scope: SourceDiagnosticScope) throws {
        func digest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        let allSteps = report.initialSteps + report.verificationSteps
        guard report.version == 1, report.scopeHash == scope.id, digest(report.configurationHash), digest(report.sessionHash), report.engineVersion == SourceAcceptanceRunner.engineVersion,
              report.books.count <= 2,
              report.initialSteps.count <= 16, report.verificationSteps.count <= 16,
              allSteps.allSatisfy({ $0.milliseconds >= 0 && $0.count >= 0 && ($0.network.map { $0.successfulFetches >= 0 && $0.failedFetches >= 0 && $0.bytes >= 0 } ?? true) }),
              report.books.allSatisfy({ digest($0.identityHash) && digest($0.workHash) && $0.chapters.count <= 3 && $0.chapters.allSatisfy { digest($0.identityHash) && digest($0.versionHash) && $0.characters > 0 } }) else { throw ContentFailure.invalidResponse }
        func complete(_ steps: [SourceAcceptanceStep]) -> Bool {
            guard steps.count == 11, steps.allSatisfy({ $0.issue == nil && $0.count > 0 }),
                  steps.filter({ $0.step == .search && $0.bookIndex == nil && $0.chapterIndex == nil && ($0.network?.successfulFetches ?? 0) > 0 }).count == 1 else { return false }
            return (0..<2).allSatisfy { book in
                steps.filter { $0.step == .details && $0.bookIndex == book && $0.chapterIndex == nil }.count == 1 &&
                steps.filter { $0.step == .catalog && $0.bookIndex == book && $0.chapterIndex == nil }.count == 1 &&
                (0..<3).allSatisfy { chapter in steps.filter { $0.step == .content && $0.bookIndex == book && $0.chapterIndex == chapter && ($0.network?.successfulFetches ?? 0) > 0 }.count == 1 }
            }
        }
        if report.status != .failed {
            guard report.books.count == 2, Set(report.books.map(\.workHash)).count == 2, Set(report.books.map(\.identityHash)).count == 2,
                  report.books.allSatisfy({ $0.chapters.count == 3 && Set($0.chapters.map(\.identityHash)).count == 3 }), complete(report.initialSteps) else { throw ContentFailure.invalidResponse }
        }
        if report.status == .restartVerified {
            guard let process = report.verificationProcessID, process != report.initialProcessID, report.verifiedAt != nil, report.issue == nil, complete(report.verificationSteps) else { throw ContentFailure.invalidResponse }
        }
    }
}

enum SourceAcceptanceRunner {
    static let engineVersion = "zhuying-source-acceptance-3.1"
    static func workIdentity(_ book: LibraryBookRecord) -> String {
        func normalize(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        return StableContentID.make(normalize(book.title), normalize(book.author))
    }
    typealias Progress = @Sendable ([SourceDiagnosticResult]) async -> Void
    static func run(source: any BookSource, query: String, scope: SourceDiagnosticScope, evidenceKind: SourceDiagnosticEvidenceKind,
                    timeout: Double = 15, authStatus: LegadoAuthStatus? = nil, processID: UUID = SourceDiagnosticProcess.id,
                    baseline: SourceAcceptanceReport? = nil, progress: Progress = { _ in }) async throws -> SourceAcceptanceReport {
        if let baseline {
            guard baseline.scopeHash == scope.id, baseline.canVerifyRestart, baseline.evidenceKind == evidenceKind,
                  baseline.configurationHash == scope.configurationHash, baseline.sessionHash == StableContentID.make(String(scope.sessionEpoch)), baseline.engineVersion == engineVersion,
                  baseline.initialProcessID != processID else { throw SourceDiagnosticFailure(issue: .init(code: .incompleteAcceptance)) }
        }
        var report = baseline ?? .init(id: UUID(), scopeHash: scope.id, initialProcessID: processID, createdAt: Date(), evidenceKind: evidenceKind,
                                     configurationHash: scope.configurationHash, sessionHash: StableContentID.make(String(scope.sessionEpoch)), engineVersion: engineVersion)
        let verifying = baseline != nil
        if verifying { report.verificationProcessID = processID; report.verificationSteps = []; report.verifiedAt = nil; report.issue = nil; report.status = .verificationFailed }
        var results: [SourceDiagnosticResult] = [], current = SourceDiagnostics.Step.search
        var currentBook: Int?, currentChapter: Int?, before: SourceDiagnosticNetworkEvidence?
        var start = ProcessInfo.processInfo.systemUptime
        let timeout = max(1, min(60, timeout))
        func require(_ value: Bool, _ issue: SourceDiagnosticIssue.Code) throws { if !value { throw SourceDiagnosticFailure(issue: .init(code: issue)) } }
        func begin(_ step: SourceDiagnostics.Step, book: Int? = nil, chapter: Int? = nil) async {
            current = step; currentBook = book; currentChapter = chapter; start = ProcessInfo.processInfo.systemUptime; before = await SourceDiagnostics.networkSnapshot(source)
        }
        func append(_ count: Int, network: SourceDiagnosticNetworkEvidence?, issue: SourceDiagnosticIssue? = nil) async {
            let row = SourceDiagnostics.result(sourceID: scope.sourceID, step: current.rawValue, start: start, count: count, issue: issue, network: network, book: currentBook, chapter: currentChapter)
            results.append(row)
            if verifying { report.verificationSteps.append(.init(row, step: current)) } else { report.initialSteps.append(.init(row, step: current)) }
            await progress(results)
        }
        do {
            try require(source.sourceID == scope.sourceID && source is any SourceDiagnosticEvidenceProvider, .incompleteAcceptance)
            await begin(.search)
            let page = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.search(query: query, page: 1) }
            try require(!page.books.isEmpty, .noSearchResults)
            let searchNetwork = await SourceDiagnostics.networkDelta(source, since: before)
            try require((searchNetwork?.failedFetches ?? 0) == 0 || (searchNetwork?.successfulFetches ?? 0) > 0, .unavailable)
            try require((searchNetwork?.successfulFetches ?? 0) > 0, .incompleteAcceptance)
            var unique = Set<String>(), works = Set<String>()
            let candidates = page.books.filter { unique.insert($0.id).inserted && works.insert(workIdentity($0)).inserted }
            let selected: [LibraryBookRecord]
            if let baseline {
                selected = baseline.books.compactMap { expected in candidates.first { StableContentID.make($0.id) == expected.identityHash && workIdentity($0) == expected.workHash } }
            } else { selected = Array(candidates.prefix(2)) }
            try require(selected.count == 2, .incompleteAcceptance)
            await append(page.books.count, network: searchNetwork)
            var checked: [SourceAcceptanceBook] = []
            for (bookIndex, candidate) in selected.enumerated() {
                await begin(.details, book: bookIndex)
                let details = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.details(for: candidate) }
                try require(details.id == candidate.id, .invalidResponse)
                let detailsNetwork = await SourceDiagnostics.networkDelta(source, since: before)
                try require((detailsNetwork?.failedFetches ?? 0) == 0 || (detailsNetwork?.successfulFetches ?? 0) > 0, .unavailable)
                await append(1, network: detailsNetwork)
                await begin(.catalog, book: bookIndex)
                let catalog = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.chapters(for: details) }
                let catalogNetwork = await SourceDiagnostics.networkDelta(source, since: before)
                try require((catalogNetwork?.failedFetches ?? 0) == 0 || (catalogNetwork?.successfulFetches ?? 0) > 0, .unavailable)
                let readable = catalog.filter { $0.access == .readable }
                try require(!readable.isEmpty, .emptyCatalog)
                let chapters: [ChapterRecord]
                if let baseline {
                    chapters = baseline.books[bookIndex].chapters.compactMap { expected in readable.first { StableContentID.make($0.id) == expected.identityHash } }
                } else { chapters = Array(readable.prefix(3)) }
                try require(chapters.count == 3 && Set(chapters.map(\.id)).count == 3, .incompleteAcceptance)
                await append(catalog.count, network: catalogNetwork)
                var chapterEvidence: [SourceAcceptanceChapter] = []
                for (chapterIndex, chapter) in chapters.enumerated() {
                    await begin(.content, book: bookIndex, chapter: chapterIndex)
                    let content = try await AsyncOperationDeadline.run(seconds: timeout) { try await source.document(for: chapter, book: details) }
                    try Task.checkCancellation()
                    let count = content.paragraphs.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }
                    try require(content.chapterID == chapter.id && count > 0, .emptyContent)
                    let network = await SourceDiagnostics.networkDelta(source, since: before)
                    try require((network?.failedFetches ?? 0) == 0 || (network?.successfulFetches ?? 0) > 0, .unavailable)
                    // A network catalog alone cannot prove that an inline or
                    // cached chapter belongs to that exact response. Until the
                    // adapter supplies that association, require every chapter
                    // to produce its own native fetch evidence.
                    try require((network?.successfulFetches ?? 0) > 0, .incompleteAcceptance)
                    let evidence = SourceAcceptanceChapter(identityHash: StableContentID.make(chapter.id), versionHash: StableContentID.make(content.version), characters: count)
                    if let baseline { try require(evidence == baseline.books[bookIndex].chapters[chapterIndex], .incompleteAcceptance) }
                    chapterEvidence.append(evidence)
                    await append(count, network: network)
                }
                checked.append(.init(identityHash: StableContentID.make(details.id), workHash: workIdentity(candidate), chapters: chapterEvidence))
            }
            report.issue = nil
            if verifying { report.status = .restartVerified; report.verifiedAt = Date() }
            else { report.books = checked; report.status = .awaitingRestart }
            return report
        } catch is CancellationError { throw CancellationError() }
        catch {
            let issue: SourceDiagnosticIssue
            if current == .catalog, error as? ContentFailure == .missingChapter { issue = .init(code: .emptyCatalog) }
            else { issue = .classify(error, authStatus: authStatus) }
            await append(0, network: await SourceDiagnostics.networkDelta(source, since: before), issue: issue)
            report.issue = issue; report.status = verifying ? .verificationFailed : .failed
            return report
        }
    }
    static func export(_ report: SourceAcceptanceReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(report)
    }
}
