import XCTest
@testable import Zhuying

@MainActor final class LegadoHostInteractionTests: XCTestCase {
    private func source() throws -> DemoSource {
        var source = DemoSource(id: "interactive-fixture", name: "竹影原创交互回归", detail: "原创", url: "https://legado-html.fixture")
        source.configuration = try LegadoDevelopmentFixtures.package(scripted: false)
        return source
    }
    private func waitForBrowser() async throws -> LegadoBrowserRequest {
        for _ in 0..<100 {
            if let request = LegadoInteractionCoordinator.shared.request { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LegadoInteractionError.timedOut
    }
    func testBrowserWaitPausesOperationAndScriptBudgetsThenResumesOriginalRule() async throws {
        let adapter = try LegadoBookSource(source: source(), transport: LegadoDevelopmentTransport(), deadline: 0.1)
        let operation = Task { try await adapter.login(action: "var reply=java.startBrowserAwait('https://legado-html.fixture/login','原创等待');java.toast(reply.body())", values: [:]) }
        let request = try await waitForBrowser()
        defer { LegadoInteractionCoordinator.shared.dismiss(id: request.id) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(LegadoInteractionCoordinator.shared.request?.id, request.id)
        LegadoInteractionCoordinator.shared.complete(id: request.id, result: .success(.init(finalURL: request.url, html: "原创返回正文", title: "完成", cookiesByOrigin: [:])))
        let result = try await operation.value
        XCTAssertEqual(result.message, "原创返回正文")
        XCTAssertNil(LegadoInteractionCoordinator.shared.request)
    }
    func testCancellingSourceOperationCancelsPendingBrowserAndAllowsNextRequest() async throws {
        let adapter = try LegadoBookSource(source: source(), transport: LegadoDevelopmentTransport())
        let operation = Task { try await adapter.login(action: "java.startBrowserAwait('https://legado-html.fixture/login','取消回归')", values: [:]) }
        let request = try await waitForBrowser()
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled browser must not return a successful login") } catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 { if LegadoInteractionCoordinator.shared.request == nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(LegadoInteractionCoordinator.shared.request)
        LegadoInteractionCoordinator.shared.dismiss(id: request.id)
        let next = try await adapter.login(action: "java.toast('取消后仍可操作')", values: [:])
        XCTAssertEqual(next.message, "取消后仍可操作")
    }
}
