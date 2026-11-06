import XCTest
@testable import Zhuying

private final class InvalidationMemoryVault: LegadoSecretVault {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ data: Data, id: String) throws { lock.lock(); values[id] = data; lock.unlock() }
    func remove(id: String) throws { lock.lock(); values[id] = nil; lock.unlock() }
}

private actor OpaqueBoundaryTransport: HTTPTransport {
    let options: Bool
    private(set) var requests: [URLRequest] = []
    init(options: Bool) { self.options = options }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try XCTUnwrap(request.url), object: [String: Any]
        switch url.path {
        case "/search": object = ["books": [["name": "原创边界回归", "url": "/book"]]]
        case "/book": object = ["name": "原创边界回归", "toc": "/toc"]
        case "/toc":
            func chapter(_ value: String) -> String {
                options ? "/chapter/" + value + #",{"headers":{"X-Chapter":"original"}}"# : "/chapter/" + value + "?ticket=fixture"
            }
            object = ["chapters": [["name": "第一章", "url": chapter("one")], ["name": "第二章", "url": chapter("two")]]]
        case "/chapter/one":
            // A page rule yields the actual address, without the catalog's
            // opaque metadata key or its request headers.
            object = ["text": "第一章的独立原创正文。", "next": "https://invalidation.fixture/chapter/two" + (options ? "" : "?ticket=fixture")]
        case "/chapter/two": object = ["text": "第二章绝不能并入第一章。", "next": ""]
        default: throw ContentFailure.invalidResponse
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                                   headerFields: ["Content-Type": "application/json; charset=utf-8"])!)
    }
}

private actor ResetWaitingTransport: HTTPTransport {
    private(set) var started = false
    private(set) var cancelled = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        do { try await Task.sleep(for: .seconds(10)) }
        catch { cancelled = true; throw error }
        throw ContentFailure.unavailable
    }
}

/// Intentionally ignores task cancellation until released, simulating a native
/// transport whose response was already in flight when the account logged out.
private actor LogoutDelayedCookieTransport: HTTPTransport {
    private(set) var started = false
    private(set) var returned = false
    private var continuation: CheckedContinuation<Void, Never>?
    func release() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        await withCheckedContinuation { continuation = $0 }
        returned = true
        let body = #"{"books":[{"name":"过期响应","url":"/book"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json", "Set-Cookie": "sid=old-account-response; Path=/; Secure; HttpOnly"])!)
    }
}

@MainActor final class LegadoSessionInvalidationTests: XCTestCase {
    private func source(id: String = "invalidation-original") throws -> DemoSource {
        let row: [String: Any] = [
            "bookSourceName": "竹影原创会话回归", "bookSourceUrl": "https://invalidation.fixture/", "searchUrl": "/search",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"],
            "ruleBookInfo": ["name": "$.name", "tocUrl": "$.toc"],
            "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"],
            "ruleContent": ["content": "$.text", "nextContentUrl": "$.next"]
        ]
        var source = DemoSource(id: id, name: "竹影原创会话回归", detail: "原创离线fixture", url: "https://invalidation.fixture/")
        source.configuration = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return source
    }
    private func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LegadoInteractionError.timedOut
    }

    func testQueryAndRequestOptionChapterReferencesStopBeforeTheNextChapterIncludingAfterRestart() async throws {
        for options in [false,true] {
            for persistent in [false,true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingBoundary-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let vault = InvalidationMemoryVault(), configured = try source()
                let state = persistent ? try LegadoPersistentState(sourceID: configured.id, directory: directory, vault: vault) : nil
                let transport = OpaqueBoundaryTransport(options: options), adapter = try LegadoBookSource(source: configured, transport: transport, state: state)
                let results = try await adapter.search(query: "原创", page: 1)
                let book = try await adapter.details(for: XCTUnwrap(results.books.first))
                let chapters = try await adapter.chapters(for: book)
                XCTAssertEqual(chapters.count, 2)
                let chapter = try XCTUnwrap(chapters.first)
                XCTAssertTrue(chapter.nativeChapterID.hasPrefix("legado-ref:"))
                let document = try await adapter.document(for: chapter, book: book)
                XCTAssertEqual(document.paragraphs.map(\.text), ["第一章的独立原创正文。"])
                if persistent {
                    let reopened = try LegadoPersistentState(sourceID: configured.id, directory: directory, vault: vault)
                    let recreated = try LegadoBookSource(source: configured, transport: transport, state: reopened)
                    let restored = try await recreated.document(for: chapter, book: book)
                    XCTAssertEqual(restored, document)
                }
                let requests = await transport.requests
                XCTAssertFalse(requests.contains { $0.url?.path == "/chapter/two" }, "nextContentUrl crossed a real chapter boundary; options=\(options), persistent=\(persistent)")
            }
        }
    }

    func testResetRuntimeCancelsAnActiveHTTPWaitAndKeepsTheAdapterUsable() async throws {
        let transport = ResetWaitingTransport(), adapter = try LegadoBookSource(source: source(), transport: transport)
        let operation = Task { try await adapter.search(query: "等待", page: 1) }
        defer { operation.cancel() }
        try await waitFor { await transport.started }
        adapter.resetRuntime()
        try await waitFor { await transport.cancelled }
        do { _ = try await operation.value; XCTFail("Invalidating the runtime must cancel its HTTP operation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await adapter.login(action: "java.toast('重置后仍可执行')", values: [:])
        XCTAssertEqual(next.message, "重置后仍可执行")
    }

    func testResetRuntimeCancelsPendingBrowserWithoutWaitingForUserCompletion() async throws {
        let adapter = try LegadoBookSource(source: source(), transport: OpaqueBoundaryTransport(options: false))
        let operation = Task { try await adapter.login(action: "java.startBrowserAwait('https://invalidation.fixture/login','重置回归')", values: [:]) }
        defer { operation.cancel() }
        try await waitFor { LegadoInteractionCoordinator.shared.request?.sourceID == adapter.sourceID }
        let request = try XCTUnwrap(LegadoInteractionCoordinator.shared.request)
        defer { LegadoInteractionCoordinator.shared.dismiss(id: request.id) }
        adapter.resetRuntime()
        try await waitFor { LegadoInteractionCoordinator.shared.request == nil }
        do { _ = try await operation.value; XCTFail("Reset must not leave a browser operation pending") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await adapter.login(action: "java.toast('网页重置后仍可执行')", values: [:])
        XCTAssertEqual(next.message, "网页重置后仍可执行")
    }

    func testLogoutPreventsAnAlreadyRunningHTTPResponseFromRestoringCookies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingLogout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = InvalidationMemoryVault(), configured = try source()
        let state = try LegadoPersistentState(sourceID: configured.id, directory: directory, vault: vault)
        try state.setLoginInfo(["账号": "old-reader"]); try state.markVerified()
        let transport = LogoutDelayedCookieTransport(), adapter = try LegadoBookSource(source: configured, transport: transport, state: state)
        let operation = Task { try await adapter.search(query: "退出中", page: 1) }
        defer { operation.cancel(); Task { await transport.release() } }
        try await waitFor { await transport.started }
        try state.logout()
        await transport.release()
        do { _ = try await operation.value; XCTFail("An old account's response must not complete after logout") }
        catch { /* Cancellation or an explicit session-revision error is valid. */ }
        try await waitFor { await transport.returned }
        let origin = URL(string: "https://invalidation.fixture/")!
        XCTAssertEqual(state.authStatus, .signedOut)
        XCTAssertTrue(try state.cookies(for: origin).isEmpty)
        let reopened = try LegadoPersistentState(sourceID: configured.id, directory: directory, vault: vault)
        XCTAssertEqual(reopened.authStatus, .signedOut)
        XCTAssertTrue(try reopened.cookies(for: origin).isEmpty)
    }
}
