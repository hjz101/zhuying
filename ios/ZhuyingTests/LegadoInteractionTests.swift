import XCTest
import WebKit
@testable import Zhuying

private final class LoginMemoryVault: LegadoSecretVault {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func save(_ data: Data, id: String) throws { values[id] = data }
    func remove(id: String) throws { values[id] = nil }
}

@MainActor final class LegadoInteractionTests: XCTestCase {
    private func source(ui: Any? = nil) throws -> DemoSource {
        let rows: [[String: Any]] = [
            ["name": "账号", "type": "text"], ["name": "密码", "type": "password"],
            ["name": "登录", "type": "button", "action": "login(true)"]
        ]
        var source = DemoSource(id: "original-login", name: "竹影原创登录回归", detail: "原创登录 fixture", url: "https://source.test/")
        source.configuration = try JSONSerialization.data(withJSONObject: ["loginUi": ui ?? rows])
        return source
    }
    private func state(_ root: URL) throws -> LegadoPersistentState {
        try LegadoPersistentState(sourceID: "original-login", directory: root, vault: LoginMemoryVault())
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Expected state transition did not arrive")
    }
    private func request(timeout: TimeInterval = 300, account: String = "default") -> LegadoBrowserRequest {
        .init(sourceID: "A", accountID: account, url: URL(string: "https://source.test/login")!, timeoutSeconds: timeout)
    }
    private func result(_ request: LegadoBrowserRequest) -> LegadoBrowserResult {
        .init(finalURL: request.url, html: "<html>原创完成页</html>", title: "完成", cookiesByOrigin: [:])
    }

    func testOriginalLoginUIDefinitionAcceptsJSONTextAndPreservesSecureFieldAndActionOrder() throws {
        let original = try source(), first = try LegadoLoginDefinition.parse(original)
        let rows = try XCTUnwrap((JSONSerialization.jsonObject(with: XCTUnwrap(original.configuration)) as? [String: Any])?["loginUi"])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        let second = try LegadoLoginDefinition.parse(source(ui: text))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.items.map(\.kind), [.text, .password, .button])
        XCTAssertEqual(first.items.last?.action, "login(true)")
        XCTAssertThrowsError(try LegadoLoginDefinition.parse(source(ui: [["name": "自定义", "type": "webview"]])))
        XCTAssertThrowsError(try LegadoLoginDefinition.parse(source(ui: [["name": "重复", "type": "text"], ["name": "重复", "type": "password"]])))
    }

    func testLoginActionPersistsInputsAndHiddenValuesWithoutClaimingVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try state(root), source = try source()
        try state.setLoginInfo(["hidden-token": "original-private-value"])
        let model = try LegadoLoginFormModel(source: source, state: state) { action, values in
            XCTAssertEqual(action, "login(true)"); XCTAssertEqual(values["账号"], "reader")
            return .init()
        }
        model.values["账号"] = "reader"; model.values["密码"] = "private-password"
        model.perform(try XCTUnwrap(model.definition.items.last))
        try await waitUntil { !model.busy }
        XCTAssertEqual(state.authStatus, .unverified)
        XCTAssertEqual(try state.getLoginInfoMap()["hidden-token"], "original-private-value")
        let reopened = try LegadoLoginFormModel(source: source, state: state) { _, _ in .init() }
        XCTAssertEqual(reopened.values["账号"], "reader"); XCTAssertEqual(reopened.values["密码"], "private-password")
        XCTAssertTrue(model.message?.contains("尚未验证") == true)
        model.logout()
        XCTAssertEqual(state.authStatus, .signedOut); XCTAssertTrue(try state.getLoginInfoMap().isEmpty)
    }

    func testExpiredAccountCancelsInFlightLoginAndRetainsAnExplicitExpiredStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try state(root), model = try LegadoLoginFormModel(source: source(), state: state) { _, _ in
            try await Task.sleep(for: .seconds(20)); return .init(authentication: .verified)
        }
        model.perform(try XCTUnwrap(model.definition.items.last))
        try await waitUntil { model.busy }
        try state.expire(); model.refreshStatus()
        XCTAssertFalse(model.busy); XCTAssertEqual(model.status, .expired)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.authStatus, .expired, "A cancelled operation cannot later mark an expired account verified")
    }

    func testBrowserAwaitsExplicitCompletionAndRejectsConcurrentOrForeignResults() async throws {
        let coordinator = LegadoInteractionCoordinator(), input = request()
        let operation = Task { try await coordinator.requestBrowser(input) }
        try await waitUntil { coordinator.request != nil }
        do { _ = try await coordinator.requestBrowser(request()); XCTFail("Only one interaction can be visible") }
        catch { XCTAssertEqual(error as? LegadoInteractionError, .busy) }
        XCTAssertNotNil(coordinator.request)
        coordinator.complete(id: input.id, result: .success(result(input)))
        let value = try await operation.value
        XCTAssertEqual(value.finalURL, input.url); XCTAssertNil(coordinator.request)

        let next = request(), second = Task { try await coordinator.requestBrowser(next) }
        try await waitUntil { coordinator.request != nil }
        coordinator.complete(id: input.id, result: .success(result(input)))
        XCTAssertEqual(coordinator.request?.id, next.id)
        coordinator.complete(id: next.id, result: .success(.init(finalURL: URL(string: "https://unrelated.test/")!, html: "", title: "", cookiesByOrigin: [:])))
        do { _ = try await second.value; XCTFail("Foreign completion cannot be accepted") }
        catch { XCTAssertEqual(error as? LegadoInteractionError, .invalidRequest) }
    }

    func testBrowserCancellationExpiryClosureAndUserDeadlineHaveDistinctResults() async throws {
        let coordinator = LegadoInteractionCoordinator(), input = request(account: "reader-one")
        let first = Task { try await coordinator.requestBrowser(input) }
        try await waitUntil { coordinator.request != nil }
        coordinator.cancel(sourceID: "A", accountID: "reader-two", reason: .expired)
        XCTAssertEqual(coordinator.request?.id, input.id)
        coordinator.cancel(sourceID: "A", accountID: "reader-one", reason: .expired)
        do { _ = try await first.value; XCTFail() } catch { XCTAssertEqual(error as? LegadoInteractionError, .expired) }
        let closed = request(), second = Task { try await coordinator.requestBrowser(closed) }
        try await waitUntil { coordinator.request != nil }; coordinator.dismiss(id: closed.id)
        do { _ = try await second.value; XCTFail() } catch { XCTAssertEqual(error as? LegadoInteractionError, .closed) }
        let third = Task { try await coordinator.requestBrowser(request()) }
        try await waitUntil { coordinator.request != nil }; third.cancel()
        do { _ = try await third.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await coordinator.requestBrowser(request(timeout: 0.03)); XCTFail() }
        catch { XCTAssertEqual(error as? LegadoInteractionError, .timedOut) }
    }

    func testOfflineHTMLHasNoInventedOriginOrCookiesAndOnlyDeclaredNavigationIsRequested() async throws {
        let coordinator = LegadoInteractionCoordinator()
        let input = LegadoBrowserRequest(sourceID: "A", url: URL(string: "about:blank")!, html: "<html>原创说明页</html>", javaScript: "document.title='说明'")
        try input.validate()
        XCTAssertThrowsError(try LegadoBrowserRequest(sourceID: "A", url: URL(string: "about:blank")!).validate())
        XCTAssertThrowsError(try LegadoBrowserRequest(sourceID: "A", url: URL(string: "https://source.test/")!, javaScript: "window.java = java;").validate())
        let operation = Task { try await coordinator.requestBrowser(input) }
        try await waitUntil { coordinator.request != nil }
        coordinator.complete(id: input.id, result: .success(result(input)))
        let value = try await operation.value
        XCTAssertEqual(value.finalURL.absoluteString, "about:blank"); XCTAssertTrue(value.cookiesByOrigin.isEmpty)
        XCTAssertEqual(SourceBrowserSessions.accountScope(sourceID: "A"), "A")
        XCTAssertNotEqual(SourceBrowserSessions.accountScope(sourceID: "A", accountID: "one"), SourceBrowserSessions.accountScope(sourceID: "A", accountID: "two"))
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let sessions = SourceBrowserSessions(defaults: defaults), browser = NativeSourceBrowser(), allowed = URL(string: "https://source.test/")!
        browser.configure(sourceID: "A", origin: nil, sessions: sessions, javascript: true, allowedOrigins: [allowed], restrictToDeclaredOrigins: true)
        browser.open("https://source.test/login"); XCTAssertEqual(browser.requestedOriginURL?.host, "source.test")
        browser.open("https://unrelated.test/"); XCTAssertEqual(browser.external?.host, "unrelated.test")
        browser.close()
    }

    func testAllowedNetworkOriginsSupportOpaqueIdentityAndRejectInsecureAdditionsAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try state(root)
        var source = try source(); source.url = "原创不透明书源身份"
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: LegadoDevelopmentFixtures.package(scripted: false)) as? [String: Any])
        raw["bookSourceUrl"] = source.url
        raw["searchUrl"] = "https://source.test/search?key={{key}}"
        source.configuration = try JSONSerialization.data(withJSONObject: raw)
        let origins = try LegadoNetworkOrigins.all(source: source, state: state)
        XCTAssertTrue(origins.contains { $0.host == "source.test" })
        XCTAssertEqual(try LegadoNetworkOrigins.allow("https://additional.test/books", source: source, state: state).absoluteString, "https://additional.test/")
        let saved = try state.allowedOrigins()
        XCTAssertThrowsError(try LegadoNetworkOrigins.allow("http://unsafe.test/", source: source, state: state))
        XCTAssertEqual(try state.allowedOrigins(), saved)
    }

    func testBrowserSeedingReplacesStaleCookiesAndLogoutClearsOnlyTheMatchingAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let state = try state(root), library = LibraryStore(books: [], defaults: defaults)
        var source = try source(); source.configuration = try LegadoDevelopmentFixtures.package(scripted: false)
        let origin = URL(string: "https://legado-html.fixture/")!, url = origin.appendingPathComponent("login")
        func cookie(_ value: String) throws -> HTTPCookie { try XCTUnwrap(HTTPCookie(properties: [.domain: "legado-html.fixture", .path: "/", .name: "sid", .value: value, .secure: "TRUE"])) }
        let first = library.browserSessions.store(sourceID: source.id, origin: origin)
        let otherScope = SourceBrowserSessions.accountScope(sourceID: source.id, accountID: "other")
        let other = library.browserSessions.store(sourceID: otherScope, origin: origin)
        await first.httpCookieStore.setCookie(try cookie("stale")); await other.httpCookieStore.setCookie(try cookie("unrelated"))
        try state.setCookies([cookie("fresh")], for: url)
        try await library.seedLegadoBrowserCookies(source: source, state: state, url: url)
        let seeded = await first.httpCookieStore.allCookies()
        XCTAssertEqual(seeded.first { $0.name == "sid" }?.value, "fresh")
        try state.logout(); try await library.clearLegadoBrowserSessions(source: source, state: state)
        let removed = await first.httpCookieStore.allCookies(), retained = await other.httpCookieStore.allCookies()
        XCTAssertTrue(removed.isEmpty); XCTAssertEqual(retained.first { $0.name == "sid" }?.value, "unrelated")
        await library.browserSessions.clear(sourceID: otherScope, origin: origin)
    }
}
