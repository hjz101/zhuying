import XCTest
@testable import Zhuying

@MainActor final class LegadoLiveSourceProbeTests: XCTestCase {
    func testExplicitLiveProbeRequiresItsDedicatedProductionEnvironmentAndBoundedInputs() throws {
        let prefix = ["--production", "--live-source-acceptance", "--validate-legado-source", "--legado-probe-source", "original-source", "--legado-probe-query"]
        XCTAssertNil(try LegadoLiveSourceProbe.Input.parse(["--production"]))
        XCTAssertThrowsError(try LegadoLiveSourceProbe.Input.parse(["--validate-legado-source"]))
        XCTAssertThrowsError(try LegadoLiveSourceProbe.Input.parse(prefix + ["原创", "--ui-testing"]))
        XCTAssertThrowsError(try LegadoLiveSourceProbe.Input.parse(prefix + [String(repeating: "字", count: 200)]))
        XCTAssertThrowsError(try LegadoLiveSourceProbe.Input.parse(prefix + ["\n"]))
        let input = try XCTUnwrap(LegadoLiveSourceProbe.Input.parse(prefix + ["原创小说"]))
        XCTAssertEqual(input.sourceID, "original-source"); XCTAssertEqual(input.query, "原创小说")
        XCTAssertFalse(input.fullAcceptance); XCTAssertFalse(input.verifyRestart)
        XCTAssertThrowsError(try LegadoLiveSourceProbe.Input.parse(prefix + ["原创", "--legado-verify-restart"]))
        let acceptance = try XCTUnwrap(LegadoLiveSourceProbe.Input.parse(prefix + ["原创", "--legado-full-acceptance", "--legado-verify-restart"]))
        XCTAssertTrue(acceptance.fullAcceptance); XCTAssertTrue(acceptance.verifyRestart)
    }
    func testAcceptanceContextTracksConfigurationChangesAndLoginGenerations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(books: [], defaults: UserDefaults(suiteName: UUID().uuidString)!, seedDemoData: false,
                                   productionPersistence: try ProductionLibraryPersistence(directory: root))
        await library.bootstrapProductionIfNeeded()
        var source = DemoSource(id: UUID().uuidString, name: "竹影原创上下文", detail: "原创 fixture", url: "https://context.fixture/")
        source.configuration = try JSONSerialization.data(withJSONObject: ["bookSourceUrl": source.url, "searchUrl": "/search", "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"], "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"], "ruleContent": ["content": "$.text"]])
        library.updateSources([source])
        _ = try SourcePackages.legadoDefinition(source)
        let initial = try LegadoLiveSourceProbe.currentScope(library: library, sourceID: source.id)
        let state = try library.legadoLoginState(for: source)
        try state.beginLoginAttempt(["账号": "original-reader"])
        XCTAssertThrowsError(try SourceAcceptanceRunner.requireCurrentContext(initial, LegadoLiveSourceProbe.currentScope(library: library, sourceID: source.id)))
        let loggedIn = try LegadoLiveSourceProbe.currentScope(library: library, sourceID: source.id)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.configuration)) as? [String: Any])
        raw["searchUrl"] = "/revised"; source.configuration = try JSONSerialization.data(withJSONObject: raw)
        library.updateSources([source])
        XCTAssertThrowsError(try SourceAcceptanceRunner.requireCurrentContext(loggedIn, LegadoLiveSourceProbe.currentScope(library: library, sourceID: source.id)))
        source.enabled = false; library.updateSources([source])
        XCTAssertThrowsError(try LegadoLiveSourceProbe.currentScope(library: library, sourceID: source.id))
        let saved = await library.flushPendingWrites(); XCTAssertTrue(saved)
    }

    func testMissingSourceProducesOnlyRedactedConfigurationEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false)
        let input = LegadoLiveSourceProbe.Input(sourceID: "private-source-identity", query: "private-reading-query")
        try await LegadoLiveSourceProbe.run(library: library, input: input, outputDirectory: root)
        let bytes = try Data(contentsOf: root.appendingPathComponent("legado-source-probe.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains(input.sourceID)); XCTAssertFalse(text.contains(input.query))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(report["fullAcceptanceVerified"] as? Bool, false)
        XCTAssertEqual(report["diagnosticOnly"] as? Bool, true)
        let stages = try XCTUnwrap(report["stages"] as? [[String: Any]])
        XCTAssertEqual((stages.first?["issue"] as? [String: Any])?["code"] as? String, "sourceDisabled")
    }
}
