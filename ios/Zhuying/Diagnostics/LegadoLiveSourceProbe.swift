#if DEBUG
import Foundation

/// Explicit development launch only. Uses the existing app account through its
/// normal source adapter; credentials never enter arguments or report files.
@MainActor enum LegadoLiveSourceProbe {
    struct Input: Equatable {
        let sourceID: String
        let query: String
        static func parse(_ arguments: [String]) throws -> Input? {
            guard arguments.contains("--validate-legado-source") else { return nil }
            guard AppEnvironment(arguments: arguments).isLiveValidation else { throw ContentFailure.sourceDisabled }
            func argument(_ name: String) throws -> String {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { throw ContentFailure.invalidResponse }
                return arguments[index + 1]
            }
            let id = try argument("--legado-probe-source"), query = try argument("--legado-probe-query")
            guard !id.isEmpty, id.utf8.count <= 512, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf8.count <= 256, !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ContentFailure.invalidResponse }
            return .init(sourceID: id, query: query)
        }
    }

    static func run(library: LibraryStore, input: Input, outputDirectory: URL) async throws {
        var reports: [SourceDiagnosticResult] = []
        var before: LegadoAuthStatus?, after: LegadoAuthStatus?
        var nativeFailure: [String: String]?
        let start = ProcessInfo.processInfo.systemUptime
        do {
            guard let source = library.sources.first(where: { $0.id == input.sourceID && $0.enabled }),
                  (try? SourcePackages.legadoDefinition(source)) != nil else { throw ContentFailure.sourceDisabled }
            let state = try library.legadoLoginState(for: source); before = state.authStatus
            let provider = try library.configuredDiagnosticBookSource(source)
            reports = try await SourceDiagnostics.run(source: provider, query: input.query, through: .content, timeout: 30, authStatus: before)
            after = state.authStatus
            if let recorded = provider as? SourceDiagnosticBookSource { nativeFailure = await recorded.recorder.failureSnapshot() }
        } catch is CancellationError { throw CancellationError() }
        catch { reports = [SourceDiagnostics.result(sourceID: input.sourceID, step: "配置", start: start, issue: .classify(error, authStatus: before))] }
        let rows = try JSONSerialization.jsonObject(with: SourceDiagnostics.export(reports))
        let report: [String: Any] = [
            "format": "zhuying-legado-live-probe", "version": 1,
            "diagnosticOnly": true, "fullAcceptanceVerified": false,
            "processID": SourceDiagnosticProcess.id.uuidString, "stages": rows,
            "authStatusBefore": before?.rawValue ?? "unavailable", "authStatusAfter": after?.rawValue ?? "unavailable",
            "nativeFailure": nativeFailure ?? [:]
        ]
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("legado-source-probe.json"), options: .atomic)
    }
}
#endif
