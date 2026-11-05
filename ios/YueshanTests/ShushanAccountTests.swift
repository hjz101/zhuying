import XCTest
import Security
@testable import Yueshan

private struct LoginFixtureTransport: HTTPTransport {
    var status = 200
    var body = "{\"code\":200,\"data\":{\"user\":{\"api_key\":\"test-only-key\",\"nickname\":\"测试用户\"}}}"
    var inspect: @Sendable (URLRequest) -> Void = { _ in }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        inspect(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class MemoryShushanVault: ShushanCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [URL: ShushanCredential] = [:]
    var rejectsSave = false
    func load(host: URL) throws -> ShushanCredential? { lock.lock(); defer { lock.unlock() }; return credentials[host] }
    func save(_ credential: ShushanCredential) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectsSave { throw ShushanAccountError.keychain(errSecInteractionNotAllowed) }
        credentials[credential.host] = credential
    }
    func remove(host: URL) throws { lock.lock(); defer { lock.unlock() }; credentials.removeValue(forKey: host) }
}

private actor SuspendedLoginTransport: HTTPTransport {
    var started = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var request: URLRequest?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func resume() {
        guard let request else { return }
        let result = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        continuation?.resume(returning: (Data("{\"code\":200,\"data\":{\"user\":{\"api_key\":\"late-key\"}}}".utf8), result))
        continuation = nil
    }
}

@MainActor
final class ShushanAccountTests: XCTestCase {
    func testHostValidationRejectsCredentialsPathsAndPlaintext() throws {
        XCTAssertEqual(try ShushanClient.host(" HTTPS://V1.VOSSC.COM/ ").absoluteString, "https://v1.vossc.com")
        for input in ["http://example.test", "https://user:pass@example.test", "https://example.test/login", "https://example.test?key=secret", "https://example.test/#token", "invalid"] {
            XCTAssertThrowsError(try ShushanClient.host(input))
        }
    }
    func testRealLoginContractEncodesFormAndUsesReturnedKey() async throws {
        let transport = LoginFixtureTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/login")
            let body = String(data: request.httpBody!, encoding: .utf8)!
            let form = URLComponents(string: "https://test.invalid/?" + body)!
            XCTAssertEqual(form.queryItems?.first { $0.name == "email" }?.value, "reader+test@example.test")
            XCTAssertEqual(form.queryItems?.first { $0.name == "password" }?.value, "p+a&= 密码")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        let credential = try await ShushanClient(transport: transport).login(host: ShushanClient.host(ShushanClient.defaultHost), email: " reader+test@example.test ", password: "p+a&= 密码")
        XCTAssertEqual(credential.apiKey, "test-only-key")
        XCTAssertEqual(credential.nickname, "测试用户")
        XCTAssertEqual(String(data: Data(base64Encoded: credential.authenticationHeader)!, encoding: .utf8), "test-only-key")
    }
    func testHTTP200ErrorAndIncompleteResponseNeverCountAsLoginSuccess() async throws {
        for body in ["{\"error\":\"缺少登录凭证\"}", "{\"code\":403,\"data\":{}}", "{\"code\":200,\"data\":{\"user\":{\"api_key\":\"\"}}}"] {
            do {
                _ = try await ShushanClient(transport: LoginFixtureTransport(body: body)).login(host: ShushanClient.host(ShushanClient.defaultHost), email: "test@example.test", password: "test")
                XCTFail("Must reject business failure")
            } catch { XCTAssertEqual(error as? ShushanAccountError, .rejected) }
        }
    }
    func testKeychainCredentialIsScopedToHostAndCanBeUpdatedAndRemoved() throws {
        let vault = ShushanKeychain(service: "com.yueshan.tests.keychain.\(UUID().uuidString)")
        let host = try ShushanClient.host(ShushanClient.defaultHost)
        defer { try? vault.remove(host: host) }
        let credential = ShushanCredential(host: host, apiKey: "test-key", nickname: "test")
        try vault.save(credential)
        XCTAssertEqual(try vault.load(host: host), credential)
        XCTAssertNil(try vault.load(host: ShushanClient.host("https://other.example.test")))
        let changed = ShushanCredential(host: host, apiKey: "updated-test-key", nickname: "updated")
        try vault.save(changed)
        XCTAssertEqual(try vault.load(host: host), changed)
        try vault.remove(host: host)
        XCTAssertNil(try vault.load(host: host))
    }
    func testAccountRestoreLogoutAndStorageFailurePreserveTruthfulState() async throws {
        let domain = "com.yueshan.shushan.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let vault = MemoryShushanVault()
        let account = ShushanAccountStore(defaults: defaults, client: .init(transport: LoginFixtureTransport()), vault: vault)
        await account.login(email: "test@example.test", password: "test")
        XCTAssertNotNil(account.credential)
        XCTAssertFalse(account.busy)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("test-only-key") })
        let restored = ShushanAccountStore(defaults: defaults, vault: vault)
        XCTAssertEqual(restored.credential, account.credential)
        restored.logout()
        XCTAssertNil(restored.credential)
        XCTAssertNil(try vault.load(host: ShushanClient.host(ShushanClient.defaultHost)))
        vault.rejectsSave = true
        await restored.login(email: "test@example.test", password: "test")
        XCTAssertNil(restored.credential)
        XCTAssertNotNil(restored.message)
    }
    func testLateLoginResponseCannotUndoLogout() async throws {
        let domain = "com.yueshan.shushan.late.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let transport = SuspendedLoginTransport()
        let vault = MemoryShushanVault()
        let account = ShushanAccountStore(defaults: defaults, client: .init(transport: transport), vault: vault)
        let task = Task { await account.login(email: "test@example.test", password: "test") }
        while !(await transport.started) { await Task.yield() }
        account.logout()
        await transport.resume()
        await task.value
        XCTAssertNil(account.credential)
        XCTAssertFalse(account.busy)
        XCTAssertNil(try vault.load(host: ShushanClient.host(ShushanClient.defaultHost)))
    }
    func testLegacyCredentialRestoresWithStableInstallationIdentityAndLoginUsesSameHeader() async throws {
        let domain = "com.yueshan.shushan.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let old = Data("{\"host\":\"https://v1.vossc.com\",\"apiKey\":\"fixture-key\",\"nickname\":\"测试\"}".utf8)
        let credential = try JSONDecoder().decode(ShushanCredential.self, from: old)
        XCTAssertNil(credential.deviceID)
        let vault = MemoryShushanVault(); try vault.save(credential)
        let account = ShushanAccountStore(defaults: defaults, vault: vault)
        let restored = ShushanAccountStore(defaults: defaults, vault: vault)
        XCTAssertEqual(account.deviceID, restored.deviceID)
        XCTAssertNotNil(UUID(uuidString: account.deviceID))
        XCTAssertEqual(account.credentialForRequests?.deviceID, account.deviceID)
        XCTAssertEqual(account.credentialForRequests?.apiKey, "fixture-key")
        let expectedID = account.deviceID
        let client = ShushanClient(transport: LoginFixtureTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), expectedID)
        })
        let result = try await client.login(host: credential.host, email: "test@example.test", password: "fixture", deviceID: expectedID)
        XCTAssertEqual(result.deviceID, expectedID)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("fixture-key") })
    }
}
