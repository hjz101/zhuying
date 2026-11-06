import XCTest
@testable import Zhuying

private final class LegadoMemoryVault: LegadoSecretVault {
    var values: [String: Data] = [:]
    var fails = false
    func read(id: String) throws -> Data? { if fails { throw LegadoStateError.vaultUnavailable }; return values[id] }
    func save(_ data: Data, id: String) throws { if fails { throw LegadoStateError.vaultUnavailable }; values[id] = data }
    func remove(id: String) throws { if fails { throw LegadoStateError.vaultUnavailable }; values[id] = nil }
}
private final class LegadoStateWriter: AtomicFileWriting, @unchecked Sendable {
    var fails = false
    func write(_ data: Data, to url: URL) throws { if fails { throw CocoaError(.fileWriteOutOfSpace) }; try data.write(to: url, options: .atomic) }
}
final class LegadoPersistentStateTests: XCTestCase {
    private var directory: URL!
    private var vault: LegadoMemoryVault!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingState-" + UUID().uuidString)
        vault = LegadoMemoryVault()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func state(source: String = "source", account: String = "reader", profile: String = "production", writer: any AtomicFileWriting = AtomicFileWriter(), now: @escaping () -> Date = Date.init) throws -> LegadoPersistentState {
        try .init(sourceID: source, accountID: account, libraryProfile: profile, directory: directory, vault: vault, writer: writer, now: now)
    }
    func testScriptVariablesHiddenTokensAndLoginInformationNeverEnterPlaintextFilesAndReopen() throws {
        let first = try state()
        try first.setVariable("hidden-token-under-config", key: "config")
        try first.setLoginInfo(["邮箱": "reader@example.test", "密码": "password-fixture"])
        try first.cachePut("cache-hidden-secret", key: "ordinary-key", ttl: 300)
        try first.setAllowedOrigins([URL(string: "https://custom.fixture.test/")!])
        let reopened = try state()
        XCTAssertEqual(try reopened.getVariable("config"), "hidden-token-under-config")
        XCTAssertEqual(try reopened.getLoginInfoMap()["密码"], "password-fixture")
        XCTAssertEqual(try reopened.cacheGet("ordinary-key"), "cache-hidden-secret")
        XCTAssertEqual(try reopened.allowedOrigins().first?.host, "custom.fixture.test")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            for marker in ["hidden-token", "password-fixture", "cache-hidden-secret", "reader@example.test", "custom.fixture.test"] { XCTAssertFalse(text.contains(marker)) }
        }
        XCTAssertEqual(try state(account: "other").getVariable("config"), "")
        XCTAssertEqual(try state(source: "other").getLoginInfo(), "")
        XCTAssertEqual(try state(profile: "demo").getLoginInfo(), "")
    }
    func testPersistentTTLMemoryCacheAndSessionGenerationHaveSeparateLifetimes() throws {
        var date = Date(timeIntervalSince1970: 1000)
        let first = try state(now: { date })
        let session = first.sessionRevision
        try first.setVariable("小说", key: "tab")
        try first.cachePut("persistent", key: "p", ttl: 10)
        try first.cachePut("memory", key: "m", memory: true)
        XCTAssertEqual(first.sessionRevision, session)
        XCTAssertEqual(try first.cacheGet("m", memory: true), "memory")
        let reopened = try state(now: { date })
        XCTAssertNil(try reopened.cacheGet("m", memory: true)); XCTAssertEqual(try reopened.cacheGet("p"), "persistent")
        date.addTimeInterval(11); XCTAssertNil(try reopened.cacheGet("p"))
        try first.setLoginInfo(["邮箱": "reader"]); XCTAssertGreaterThan(first.sessionRevision, session)
        let changed = first.sessionRevision
        try first.markVerified(); XCTAssertEqual(first.sessionRevision, changed)
    }
    func testCookiePersistenceIsIsolatedBySourceAccountOriginAndPath() throws {
        let first = try state(), origin = URL(string: "https://v5.fixture.test/private/chapter")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: "cookie-fixture", .domain: ".fixture.test", .path: "/private", .secure: "TRUE"]))
        try first.setCookies([cookie], for: origin)
        let reopened = try state()
        XCTAssertEqual(try reopened.cookies(for: origin).first?.value, "cookie-fixture")
        XCTAssertTrue(try reopened.cookies(for: URL(string: "https://v4.fixture.test/private/chapter")!).isEmpty)
        XCTAssertTrue(try reopened.cookies(for: URL(string: "https://v5.fixture.test/other")!).isEmpty)
        XCTAssertTrue(try state(account: "other").cookies(for: origin).isEmpty)
        XCTAssertEqual(first.authStatus, .unverified)
    }
    func testLogoutKeepsPortableReferenceIdentityAndDeviceButInvalidatesOldAuthenticationTickets() throws {
        let first = try state(), device = try first.deviceIdentifier()
        try first.setLoginInfo(["邮箱": "reader", "密码": "original"]); try first.markVerified()
        let payload = try LegadoReferenceTests.inline(type: "qingtian3", chapter: "one")
        let key = try first.registerReference(payload, role: "chapter")
        let HTTP = try LegadoReference.parse(#"https://fixture.test/chapter?id=one,{"headers":{"Authorization":"Bearer original"}}"#)
        let HTTPKey = try first.registerReference(HTTP, role: "chapter")
        try first.logout()
        XCTAssertEqual(first.authStatus, .signedOut); XCTAssertEqual(try first.getLoginInfo(), "")
        XCTAssertThrowsError(try first.resolveReference(key)); XCTAssertEqual(try first.deviceIdentifier(), device)
        try first.setLoginInfo(["邮箱": "reader", "密码": "refreshed"]); try first.markVerified()
        XCTAssertEqual(try first.resolveReference(key).inlineData, payload.inlineData)
        XCTAssertThrowsError(try first.resolveReference(HTTPKey)) { XCTAssertEqual($0 as? LegadoStateError, .referenceNeedsRefresh) }
        let refreshed = try LegadoReference.parse(HTTP.descriptor.replacingOccurrences(of: "Bearer original", with: "Bearer refreshed"))
        XCTAssertEqual(try first.registerReference(refreshed, role: "chapter"), HTTPKey)
        XCTAssertTrue(try first.resolveReference(HTTPKey).descriptor.contains("Bearer refreshed"))
        XCTAssertEqual(try first.registerReference(payload, role: "chapter"), key)
        try first.reset(); XCTAssertEqual(try first.deviceIdentifier(), device)
    }
    func testFailedFileCommitRollsBackNewVaultSnapshotAndPreservesLastCommittedState() throws {
        let writer = LegadoStateWriter(), first = try state(writer: writer)
        try first.setLoginInfo(["密码": "committed"])
        let slots = Set(vault.values.keys), generation = first.sessionRevision
        writer.fails = true
        XCTAssertThrowsError(try first.setLoginInfo(["密码": "not-committed"]))
        XCTAssertEqual(Set(vault.values.keys), slots); XCTAssertEqual(first.sessionRevision, generation)
        XCTAssertEqual(try first.getLoginInfoMap()["密码"], "committed")
        XCTAssertEqual(try state().getLoginInfoMap()["密码"], "committed")
    }
    func testExplicitSameCredentialRetryLeavesExpiredStatusWithoutClaimingVerifiedLogin() throws {
        let first = try state(), values = ["邮箱": "reader", "密码": "original"]
        try first.setLoginInfo(values); try first.markVerified(); try first.expire()
        let expiredEpoch = first.sessionRevision
        // A script merely re-saving the same data does not constitute a retry.
        try first.setLoginInfo(values)
        XCTAssertEqual(first.authStatus, .expired); XCTAssertEqual(first.sessionRevision, expiredEpoch)
        try first.beginLoginAttempt(values)
        XCTAssertEqual(first.authStatus, .unverified); XCTAssertEqual(first.sessionRevision, expiredEpoch + 1)
        XCTAssertEqual(try first.getLoginInfoMap(), values)
        let reopened = try state()
        XCTAssertEqual(reopened.authStatus, .unverified); XCTAssertEqual(reopened.sessionRevision, first.sessionRevision)
    }
    func testSameCredentialAttemptInvalidatesOldResponsesButRetainsAccountConfiguration() throws {
        let first = try state(), values = ["邮箱": "reader", "密码": "original"], origin = URL(string: "https://fixture.test/")!
        try first.setLoginInfo(values); try first.markVerified()
        try first.setVariable("saved-configuration", key: "config"); try first.cachePut("saved", key: "cache")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: "existing", .domain: "fixture.test", .path: "/"]))
        try first.setCookies([cookie], for: origin)
        let worker = try state(), oldEpoch = worker.sessionRevision
        try first.beginLoginAttempt(values)
        XCTAssertEqual(worker.authStatus, .unverified); XCTAssertEqual(worker.sessionRevision, oldEpoch + 1)
        XCTAssertEqual(try worker.getVariable("config"), "saved-configuration"); XCTAssertEqual(try worker.cacheGet("cache"), "saved")
        XCTAssertEqual(try worker.cookies(for: origin).first?.value, "existing")
        XCTAssertThrowsError(try worker.setCookies([cookie], for: origin, expectedSessionRevision: oldEpoch)) { XCTAssertTrue($0 is CancellationError) }
        var called = false
        XCTAssertThrowsError(try worker.withSessionMutation(expectedSessionRevision: oldEpoch) { called = true }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(called)
    }
    func testChangedCredentialAttemptAdvancesOneEpochAndClearsOnlyItsOwnOldTokens() throws {
        let first = try state(), other = try state(account: "independent")
        try first.setLoginInfo(["邮箱": "first"]); try first.setVariable("old-token", key: "config"); try first.cachePut("old-token", key: "cache")
        try other.setVariable("independent-value", key: "config")
        let epoch = first.sessionRevision
        try first.beginLoginAttempt(["邮箱": "second"])
        XCTAssertEqual(first.sessionRevision, epoch + 1); XCTAssertEqual(first.authStatus, .unverified)
        XCTAssertEqual(try first.getVariable("config"), ""); XCTAssertNil(try first.cacheGet("cache"))
        XCTAssertEqual(try first.getLoginInfoMap()["邮箱"], "second")
        XCTAssertEqual(try other.getVariable("config"), "independent-value")
    }
    func testFailedExplicitAttemptPreservesExpiredStateEpochAndVaultSnapshot() throws {
        let writer = LegadoStateWriter(), first = try state(writer: writer), values = ["邮箱": "reader", "密码": "committed"]
        try first.setLoginInfo(values); try first.expire()
        let epoch = first.sessionRevision, revision = first.revision, slots = Set(vault.values.keys)
        writer.fails = true
        XCTAssertThrowsError(try first.beginLoginAttempt(values))
        XCTAssertEqual(first.authStatus, .expired); XCTAssertEqual(first.sessionRevision, epoch); XCTAssertEqual(first.revision, revision)
        XCTAssertEqual(Set(vault.values.keys), slots); XCTAssertEqual(try first.getLoginInfoMap(), values)
        XCTAssertEqual(try state().sessionRevision, epoch)
    }
    func testTwoProviderInstancesDoNotOverwriteMoreRecentUIChanges() throws {
        let worker = try state(), UI = try state()
        try UI.setVariable("from-UI", key: "server")
        try worker.setVariable("from-worker", key: "tab")
        let reopened = try state()
        XCTAssertEqual(try reopened.getVariable("server"), "from-UI")
        XCTAssertEqual(try reopened.getVariable("tab"), "from-worker")
        try UI.expire(); XCTAssertEqual(worker.authStatus, .expired)
    }
    func testChangingAccountCredentialsInvalidatesCachedTokensAndOtherInstancesMemory() throws {
        let worker = try state(), UI = try state()
        try worker.setLoginInfo(["邮箱": "first", "密码": "one"]); try worker.markVerified()
        try worker.setVariable("opaque-old-token", key: "config")
        try worker.cachePut("opaque-old-token", key: "memory", memory: true)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: "old", .domain: "fixture.test", .path: "/"]))
        try worker.setCookies([cookie], for: URL(string: "https://fixture.test")!)
        try UI.setLoginInfo(["邮箱": "second", "密码": "two"])
        XCTAssertEqual(worker.authStatus, .unverified)
        XCTAssertEqual(try worker.getVariable("config"), "")
        XCTAssertNil(try worker.cacheGet("memory", memory: true))
        XCTAssertTrue(try worker.cookies(for: URL(string: "https://fixture.test")!).isEmpty)
    }
    func testPublicSessionCookiesAndUnverifiedLoginDoNotInventAuthenticationRequirements() throws {
        let first = try state(), origin = URL(string: "https://fixture.test/")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "anonymous-session", .value: "public", .domain: "fixture.test", .path: "/"]))
        try first.setCookies([cookie], for: origin)
        XCTAssertEqual(first.authStatus, .unverified)
        let HTTP = try LegadoReference.parse("https://fixture.test/book?id=public")
        let key = try first.registerReference(HTTP, role: "book")
        XCTAssertEqual(try first.resolveReference(key).requestURL, HTTP.requestURL)
        let payload = try LegadoReferenceTests.inline()
        try first.setLoginInfo(["邮箱": "reader"]); try first.markVerified()
        let verifiedKey = try first.registerReference(payload, role: "book")
        try first.logout(); XCTAssertThrowsError(try first.resolveReference(verifiedKey))
        try first.setLoginInfo(["邮箱": "reader"])
        XCTAssertEqual(first.authStatus, .unverified)
        XCTAssertNoThrow(try first.resolveReference(verifiedKey), "Unverified is allowed to reach the service for real authentication checks")
        XCTAssertNotEqual(first.authStatus, .verified)
    }
    func testReplacingCompleteBrowserJarRemovesDeletedCookiesWithoutTouchingAnotherOrigin() throws {
        let first = try state(), A = URL(string: "https://a.fixture.test/")!, B = URL(string: "https://b.fixture.test/")!
        let a = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: "A", .domain: "a.fixture.test", .path: "/"]))
        let b = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: "B", .domain: "b.fixture.test", .path: "/"]))
        try first.setCookies([a], for: A); try first.setCookies([b], for: B)
        try first.replaceCookies([], for: A)
        let reopened = try state()
        XCTAssertTrue(try reopened.cookies(for: A).isEmpty)
        XCTAssertEqual(try reopened.cookies(for: B).first?.value, "B")
        let revision = reopened.revision
        try reopened.setCookies([], for: A)
        XCTAssertEqual(reopened.revision, revision, "A response with no Set-Cookie must not resurrect or rewrite the jar")
    }
    func testLateHTTPAndBrowserCookiesCannotRestoreSessionAfterConcurrentLogout() throws {
        let worker = try state(), UI = try state(), origin = URL(string: "https://fixture.test/")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: "old-session", .domain: "fixture.test", .path: "/"]))
        try worker.setLoginInfo(["邮箱": "reader"]); try worker.markVerified()
        let inFlightSession = worker.sessionRevision
        try worker.setCookies([cookie], for: origin, expectedSessionRevision: inFlightSession)
        try UI.logout()
        let loggedOutRevision = UI.revision
        XCTAssertThrowsError(try worker.setCookies([cookie], for: origin, expectedSessionRevision: inFlightSession)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try worker.replaceCookies([cookie], for: origin, expectedSessionRevision: inFlightSession)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(worker.authStatus, .signedOut); XCTAssertEqual(worker.revision, loggedOutRevision)
        XCTAssertTrue(try worker.cookies(for: origin).isEmpty)
        XCTAssertTrue(try state().cookies(for: origin).isEmpty)
        try UI.setLoginInfo(["邮箱": "reader", "密码": "new-session"])
        let newSession = UI.sessionRevision
        XCTAssertThrowsError(try worker.setCookies([cookie], for: origin, expectedSessionRevision: inFlightSession)) { XCTAssertTrue($0 is CancellationError) }
        try worker.replaceCookies([cookie], for: origin, expectedSessionRevision: newSession)
        XCTAssertEqual(try worker.cookies(for: origin).first?.value, "old-session", "A response explicitly associated with the current session may commit")
    }
    func testSessionMutationRejectsStaleEpochBeforeBodyAndReturnsItsOwnChangedEpoch() throws {
        let worker = try state(), UI = try state(), startingEpoch = worker.sessionRevision
        let (result, changedEpoch) = try worker.withSessionMutation(expectedSessionRevision: startingEpoch) {
            try worker.setLoginInfo(["邮箱": "reader"])
            return "saved"
        }
        XCTAssertEqual(result, "saved"); XCTAssertEqual(changedEpoch, worker.sessionRevision)
        XCTAssertGreaterThan(changedEpoch, startingEpoch)
        try UI.logout()
        var called = false
        XCTAssertThrowsError(try worker.withSessionMutation(expectedSessionRevision: changedEpoch) {
            called = true
            try worker.setLoginInfo(["邮箱": "must-not-return"])
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(called); XCTAssertEqual(worker.authStatus, .signedOut)
        XCTAssertEqual(try worker.getLoginInfo(), "")
    }
    func testTamperedEncryptedStateAndMissingVaultCannotSilentlyResetSession() throws {
        let first = try state(); try first.setVariable("original", key: "server")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: file); bytes[bytes.count / 2] ^= 1; try bytes.write(to: file)
        XCTAssertThrowsError(try state())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        vault.fails = true; XCTAssertThrowsError(try first.setLoginInfo(["邮箱": "unavailable"]))
    }
}
