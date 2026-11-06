import XCTest
@testable import Yueshan

private final class ServiceVaultProbe: ServiceKeyVault {
    var values: [String:String] = [:], rejectsSave = false, rejectsDelete = false
    func save(_ key: String,id: String) throws { if rejectsSave { throw ServiceCredentialError.unavailable }; values[id] = key }
    func read(id: String) throws -> String? { values[id] }
    func remove(id: String) throws { if rejectsDelete { throw ServiceCredentialError.unavailable }; values.removeValue(forKey:id) }
    func ids() throws -> [String] { Array(values.keys) }
}
private struct ServiceMetadataFailure: AtomicFileWriting { func write(_ data: Data,to url: URL) throws { throw CocoaError(.fileWriteOutOfSpace) } }
@MainActor final class AudioServiceConfigurationTests: XCTestCase {
    func testCredentialRotationIsolationDeletionAndMetadataNeverContainsKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let vault = ServiceVaultProbe(), store = try AudioServiceStore(directory:root,vault:vault)
        var a = AudioTestFixtures.profile(), b = AudioTestFixtures.profile(); b.baseURL = "https://other.test/v1"
        try store.save(a,key:"synthetic-key-a"); try store.save(b,key:"synthetic-key-b")
        XCTAssertEqual(try store.key(for:a),"synthetic-key-a"); XCTAssertEqual(try store.key(for:b),"synthetic-key-b")
        let oldID = store.profiles.first { $0.id == a.id }?.secretID
        try store.save(a,key:"synthetic-new-key"); XCTAssertNil(vault.values[oldID ?? ""])
        let metadata = try String(contentsOf:root.appendingPathComponent("services.json"),encoding:.utf8)
        XCTAssertFalse(metadata.contains("synthetic-key")); XCTAssertFalse(metadata.contains("synthetic-new-key"))
        a.baseURL = "https://changed.test/v1"; try store.save(a,key:nil); XCTAssertThrowsError(try store.key(for:a))
        try store.remove(b.id); XCTAssertTrue(vault.values.isEmpty)
        let restarted = try AudioServiceStore(directory:root,vault:vault); XCTAssertEqual(restarted.profiles.map(\.id),[a.id])
    }
    func testFailedKeyOrMetadataWriteKeepsExistingConfigurationAndKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let vault = ServiceVaultProbe(), store = try AudioServiceStore(directory:root,vault:vault), profile = AudioTestFixtures.profile()
        try store.save(profile,key:"first-test-key"); let original = try Data(contentsOf:root.appendingPathComponent("services.json"))
        vault.rejectsSave = true; XCTAssertThrowsError(try store.save(profile,key:"rejected-test-key")); vault.rejectsSave = false
        let failing = try AudioServiceStore(directory:root,vault:vault,writer:ServiceMetadataFailure())
        XCTAssertThrowsError(try failing.save(profile,key:"uncommitted-test-key"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("services.json")),original)
        XCTAssertEqual(try store.key(for:profile),"first-test-key"); XCTAssertEqual(vault.values.count,1)
    }
    func testDisablingAuthenticationRemovesKeyAndFailedCleanupRetriesAtRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let vault = ServiceVaultProbe(), store = try AudioServiceStore(directory:root,vault:vault)
        var profile = AudioTestFixtures.profile(); try store.save(profile,key:"test-only-key")
        vault.rejectsDelete = true; profile.usesKey = false; try store.save(profile,key:nil)
        XCTAssertTrue(store.cleanupPending); XCTAssertNil(try store.key(for:profile)); XCTAssertEqual(vault.values.count,1)
        vault.rejectsDelete = false; let reopened = try AudioServiceStore(directory:root,vault:vault)
        XCTAssertFalse(reopened.cleanupPending); XCTAssertTrue(vault.values.isEmpty)
    }
    func testActualKeychainServiceNamespacesDoNotShareSecrets() throws {
        let a = ServiceKeychain(service:"com.yueshan.test-a." + UUID().uuidString), b = ServiceKeychain(service:"com.yueshan.test-b." + UUID().uuidString)
        defer { try? a.remove(id:"test"); try? b.remove(id:"test") }
        try a.save("test-only-a",id:"test"); try b.save("test-only-b",id:"test")
        XCTAssertEqual(try a.read(id:"test"),"test-only-a"); XCTAssertEqual(try b.read(id:"test"),"test-only-b")
        try a.remove(id:"test"); XCTAssertNil(try a.read(id:"test")); XCTAssertNotNil(try b.read(id:"test"))
    }
    func testURLsAndHeaderKeysRejectEmbeddedCredentialsAndInvalidSchemes() throws {
        var profile = AudioTestFixtures.profile()
        for url in ["http://insecure.test/v1","https://user:pass@private.test/v1","https://private.test/v1?token=secret"] { profile.baseURL = url; XCTAssertThrowsError(try profile.validate()) }
        let store = try AudioServiceStore(vault:ServiceVaultProbe()); profile = AudioTestFixtures.profile()
        XCTAssertThrowsError(try store.save(profile,key:"value\r\nInjected: header"))
    }
}
