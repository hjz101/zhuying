import XCTest
@testable import Zhuying

@MainActor final class SourceQuickActionsTests: XCTestCase {
    private func source() throws -> DemoSource {
        var source = DemoSource(id: "source-shortcuts", name: "竹影快捷操作测试", detail: "原创 fixture", url: "https://shortcuts.fixture")
        source.configuration = try JSONSerialization.data(withJSONObject: [
            "bookSourceUrl": source.url, "searchUrl": "/search?q={{key}}", "loginUrl": "function test(){java.toast('完成');}",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"],
            "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"],
            "ruleContent": ["content": "$.text"]
        ])
        return source
    }

    func testRefreshRebuildsRulesAndKeepsSourceAndProtectedLoginState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: domain) }
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
            productionPersistence: try ProductionLibraryPersistence(directory: directory))
        await library.bootstrapProductionIfNeeded()
        let source = try source(); library.updateSources([source])
        let state = try library.legadoLoginState(for: source)
        try state.setLoginInfo(["账号": "原创读者"]); try state.setVariable("keep", key: "custom")
        let oldRevision = library.onlineRevision
        _ = try library.configuredBookSource(source)
        try await library.refreshSourceRuntime(sourceID: source.id, credential: nil)
        XCTAssertEqual(library.sources.first?.configuration, source.configuration)
        XCTAssertEqual(try state.getLoginInfoMap()["账号"], "原创读者")
        XCTAssertEqual(try state.getVariable("custom"), "keep")
        XCTAssertEqual(state.authStatus, .unverified)
        XCTAssertGreaterThan(library.onlineRevision, oldRevision)
        do { try await library.refreshSourceRuntime(sourceID: "removed", credential: nil); XCTFail("Removed sources cannot refresh") }
        catch { XCTAssertEqual(error as? ContentFailure, .sourceDisabled) }
    }

    func testCancellationCannotPublishLateSuccessfulRefreshOrRunDemoWork() async throws {
        let model = SourceQuickActions(), source = try source()
        let started = expectation(description: "refresh starts")
        model.refresh(source, demo: false) {
            started.fulfill(); try await Task.sleep(for: .seconds(10))
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(model.refreshingSourceID, source.id)
        model.cancel(); await Task.yield()
        XCTAssertNil(model.refreshingSourceID); XCTAssertNil(model.message)
        model.refresh(source, demo: true) { XCTFail("Demo shortcut must not run real refresh") }
        XCTAssertTrue(model.message?.contains("演示") == true)
    }

    func testBrowserDestinationPreservesSourceAndRejectsOpaqueIdentityAndCredentials() throws {
        let source = try source()
        XCTAssertEqual(SourceBrowserStart.urls(source).first?.host, "shortcuts.fixture")
        var opaque = source; opaque.url = "竹影不透明书源身份"
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.configuration)) as? [String: Any])
        raw["bookSourceUrl"] = opaque.url; raw["searchUrl"] = "https://declared.fixture/search?q={{key}}"
        opaque.configuration = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertEqual(SourceBrowserStart.urls(opaque).first?.host, "declared.fixture")
        var invalid = DemoSource(id: "invalid", name: "无效地址", detail: "", url: "https://reader:secret@source.test")
        XCTAssertTrue(SourceBrowserStart.urls(invalid).isEmpty)
        invalid.url = "file:///private/book"; XCTAssertTrue(SourceBrowserStart.urls(invalid).isEmpty)
    }
}
