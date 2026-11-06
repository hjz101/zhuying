#if DEBUG
import Foundation

/// Explicit development launch only. Uses the existing app account through its
/// normal source adapter; credentials never enter arguments or report files.
@MainActor enum LegadoLiveSourceProbe {
    struct Input: Equatable {
        let sourceID: String
        let query: String
        var fullAcceptance = false
        var verifyRestart = false
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
            let full = arguments.contains("--legado-full-acceptance"), restart = arguments.contains("--legado-verify-restart")
            guard !restart || full else { throw ContentFailure.invalidResponse }
            return .init(sourceID: id, query: query, fullAcceptance: full, verifyRestart: restart)
        }
    }

    static func run(library: LibraryStore, input: Input, outputDirectory: URL) async throws {
        var reports: [SourceDiagnosticResult] = []
        var before: LegadoAuthStatus?, after: LegadoAuthStatus?
        var nativeFailure: [String: String]?
        var acceptance: SourceAcceptanceReport?
        let start = ProcessInfo.processInfo.systemUptime
        do {
            guard let source = library.sources.first(where: { $0.id == input.sourceID && $0.enabled }),
                  (try? SourcePackages.legadoDefinition(source)) != nil else { throw ContentFailure.sourceDisabled }
            let state = try library.legadoLoginState(for: source); before = state.authStatus
            let provider = try library.configuredDiagnosticBookSource(source)
            if input.fullAcceptance {
                var scope = SourceDiagnosticScope(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile)
                scope.sessionEpoch = state.sessionRevision
                scope.configurationHash = StableContentID.make(source.configuration?.base64EncodedString() ?? "", source.url)
                let store = SourceAcceptanceStore(directory: library.sourceDiagnosticsDirectory)
                let baseline: SourceAcceptanceReport?
                if input.verifyRestart {
                    guard let saved = try await store.load(scope: scope) else { throw SourceDiagnosticFailure(issue: .init(code: .incompleteAcceptance)) }
                    baseline = saved
                } else { baseline = nil }
                var kind = SourceDiagnosticEvidenceKind.nativeNetwork
                if LegadoDevelopmentFixtures.isEnabled(source) || SourceDiagnosticDevelopmentFixtures.isEnabled(source) { kind = .controlledFixture }
                let result = try await SourceAcceptanceRunner.run(source: provider, query: input.query, scope: scope, evidenceKind: kind, timeout: 30, authStatus: before, baseline: baseline)
                try await store.save(result, scope: scope); acceptance = result
                reports = (input.verifyRestart ? result.verificationSteps : result.initialSteps).map { $0.result(sourceID: source.id) }
            } else {
                reports = try await SourceDiagnostics.run(source: provider, query: input.query, through: .content, timeout: 30, authStatus: before)
            }
            after = state.authStatus
            if let recorded = provider as? SourceDiagnosticBookSource { nativeFailure = await recorded.recorder.failureSnapshot() }
        } catch is CancellationError { throw CancellationError() }
        catch { reports = [SourceDiagnostics.result(sourceID: input.sourceID, step: "配置", start: start, issue: .classify(error, authStatus: before))] }
        let rows = try JSONSerialization.jsonObject(with: SourceDiagnostics.export(reports))
        var report: [String: Any] = [
            "format": "zhuying-legado-live-probe", "version": 1,
            "diagnosticOnly": !input.fullAcceptance, "fullAcceptanceVerified": acceptance?.status == .restartVerified,
            "processID": SourceDiagnosticProcess.id.uuidString, "stages": rows,
            "authStatusBefore": before?.rawValue ?? "unavailable", "authStatusAfter": after?.rawValue ?? "unavailable",
            "nativeFailure": nativeFailure ?? [:]
        ]
        if let acceptance {
            report["acceptance"] = try JSONSerialization.jsonObject(with: SourceAcceptanceRunner.export(acceptance))
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("legado-source-probe.json"), options: .atomic)
    }
}
#endif
