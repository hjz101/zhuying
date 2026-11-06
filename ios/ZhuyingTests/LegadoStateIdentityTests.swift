import XCTest
import CryptoKit
@testable import Zhuying

private final class IdentityTestVault: LegadoSecretVault {
    private var values: [String:Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func save(_ data: Data,id: String) throws { values[id] = data }
    func remove(id: String) throws { values[id] = nil }
}
private enum IdentityTestFailure: Error { case write }
private struct IdentityFailingWriter: AtomicFileWriting {
    func write(_ data: Data, to url: URL) throws { throw IdentityTestFailure.write }
}

final class LegadoStateIdentityTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingStateIdentity-" + UUID().uuidString) }

    func testProfileIdentitySurvivesContainerRelocationAndKeepsLibrariesSeparate() throws {
        let first = root(), moved = root(), other = root()
        defer { for url in [first,moved,other] { try? FileManager.default.removeItem(at:url) } }
        let profile = try LegadoLibraryProfileIdentity.load(directory:first,namespace:"production")
        XCTAssertEqual(try LegadoLibraryProfileIdentity.load(directory:first,namespace:"production"),profile)
        try FileManager.default.copyItem(at:first,to:moved)
        let copied = try LegadoLibraryProfileIdentity.load(directory:moved,namespace:"production")
        XCTAssertEqual(copied.libraryProfile,profile.libraryProfile)
        XCTAssertFalse(copied.libraryProfile.contains(first.path))
        XCTAssertNotEqual(try LegadoLibraryProfileIdentity.load(directory:other,namespace:"production").libraryProfile,profile.libraryProfile)
        XCTAssertThrowsError(try LegadoLibraryProfileIdentity.load(directory:moved,namespace:"demo"))
        let vault = IdentityTestVault(), sessions = first.appendingPathComponent("sessions")
        let state = try LegadoPersistentState(sourceID:"source",libraryProfile:profile.libraryProfile,directory:sessions,vault:vault)
        try state.setLoginInfo(["user":"synthetic"])
        try FileManager.default.copyItem(at:sessions,to:moved.appendingPathComponent("sessions"))
        let restored = try LegadoPersistentState(sourceID:"source",libraryProfile:copied.libraryProfile,directory:moved.appendingPathComponent("sessions"),vault:vault)
        XCTAssertEqual(try restored.getLoginInfoMap(),["user":"synthetic"])
        XCTAssertEqual(restored.authStatus,.unverified)
        XCTAssertEqual(restored.scope,state.scope)
    }

    func testCorruptProfileMetadataDoesNotSilentlyCreateAnotherNamespace() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        _ = try LegadoLibraryProfileIdentity.load(directory:directory,namespace:"production")
        let file = directory.appendingPathComponent("legado-library-profile-v1.json"), bytes = Data("invalid identity".utf8)
        try bytes.write(to:file)
        XCTAssertThrowsError(try LegadoLibraryProfileIdentity.load(directory:directory,namespace:"production"))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }

    private func rewriteManifest(directory: URL, scope: LegadoStateScope, vault: IdentityTestVault,
                                 _ mutation: (inout [String:Any]) -> Void) throws {
        let file = directory.appendingPathComponent(scope.id + ".sealed")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        let data = try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(envelope["sealed"] as? String)))
        let key = SymmetricKey(data:try XCTUnwrap(vault.read(id:"file-key." + scope.id)))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:AES.GCM.open(.init(combined:data),using:key,authenticating:Data(scope.id.utf8))) as? [String:Any])
        mutation(&manifest)
        let sealed = try XCTUnwrap(AES.GCM.seal(JSONSerialization.data(withJSONObject:manifest),using:key,authenticating:Data(scope.id.utf8)).combined)
        envelope["sealed"] = sealed.base64EncodedString()
        try JSONSerialization.data(withJSONObject:envelope).write(to:file,options:.atomic)
    }

    func testExactKnownLegacyNamespaceMigratesSessionReferencesAndDeviceWithoutChangingAuthentication() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let vault = IdentityTestVault(), legacy = LegadoStateScope(sourceID:"source",accountID:"account",libraryProfile:"production:/old/container/Library/Database")
        let target = LegadoStateScope(sourceID:"source",accountID:"account",libraryProfile:"production:permanent-library-identity")
        let old = try LegadoPersistentState(sourceID:legacy.sourceID,accountID:legacy.accountID,libraryProfile:legacy.libraryProfile,directory:directory,vault:vault)
        try old.setLoginInfo(["user":"synthetic"]); try old.setVariable("value",key:"saved")
        let ref = try LegadoReference.parse("https://example.test/book/1"), key = try old.registerReference(ref,role:"book")
        let device = try old.deviceIdentifier(), epoch = old.sessionRevision
        // Simulate the pre-identity schema while retaining its authenticated
        // exact scope hash. Absence of a tuple is compatible, not a discovery hint.
        try rewriteManifest(directory:directory,scope:legacy,vault:vault) { $0.removeValue(forKey:"scopeIdentity") }
        XCTAssertTrue(try LegadoPersistentState.migrateLegacyScope(from:legacy,to:target,directory:directory,vault:vault))
        let restored = try LegadoPersistentState(sourceID:target.sourceID,accountID:target.accountID,libraryProfile:target.libraryProfile,directory:directory,vault:vault)
        XCTAssertEqual(restored.authStatus,.unverified)
        XCTAssertEqual(restored.sessionRevision,epoch)
        XCTAssertEqual(try restored.getLoginInfoMap(),["user":"synthetic"])
        XCTAssertEqual(try restored.getVariable("saved"),"value")
        XCTAssertEqual(try restored.resolveReference(key).resolvedDescriptor,ref.resolvedDescriptor)
        XCTAssertEqual(try restored.deviceIdentifier(),device)
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent(legacy.id + ".sealed").path))
        let bytes = try Data(contentsOf:directory.appendingPathComponent(target.id + ".sealed"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertNil(envelope["scopeIdentity"],"The identity tuple must remain inside authenticated ciphertext")
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("permanent-library-identity"))
    }

    func testUnknownNamespaceCannotClaimFilesAndExistingTargetOrDifferentAccountIsTypedConflict() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let vault = IdentityTestVault(), legacy = LegadoStateScope(sourceID:"source",libraryProfile:"production:/known/old/path"), target = LegadoStateScope(sourceID:"source",libraryProfile:"production:stable")
        let old = try LegadoPersistentState(sourceID:"source",libraryProfile:legacy.libraryProfile,directory:directory,vault:vault)
        try old.setLoginInfo(["user":"legacy-synthetic"])
        let original = try Data(contentsOf:directory.appendingPathComponent(legacy.id + ".sealed"))
        let unknown = LegadoStateScope(sourceID:"source",libraryProfile:"production:/unknown/path")
        XCTAssertFalse(try LegadoPersistentState.migrateLegacyScope(from:unknown,to:target,directory:directory,vault:vault))
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent(legacy.id + ".sealed")),original)
        let destination = try LegadoPersistentState(sourceID:"source",libraryProfile:target.libraryProfile,directory:directory,vault:vault)
        try destination.setLoginInfo(["user":"target-synthetic"])
        for source in [legacy,LegadoStateScope(sourceID:"other",libraryProfile:legacy.libraryProfile),LegadoStateScope(sourceID:"source",accountID:"other",libraryProfile:legacy.libraryProfile)] {
            XCTAssertThrowsError(try LegadoPersistentState.migrateLegacyScope(from:source,to:target,directory:directory,vault:vault)) { XCTAssertEqual($0 as? LegadoStateError,.migrationConflict) }
        }
        XCTAssertEqual(try destination.getLoginInfoMap(),["user":"target-synthetic"])
        XCTAssertEqual(try old.getLoginInfoMap(),["user":"legacy-synthetic"])
    }

    func testAuthenticatedTupleMismatchFailsClosedRatherThanReassigningAccount() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let vault = IdentityTestVault(), state = try LegadoPersistentState(sourceID:"source",libraryProfile:"production:stable",directory:directory,vault:vault)
        try state.setVariable("synthetic",key:"value")
        try rewriteManifest(directory:directory,scope:state.scope,vault:vault) {
            $0["scopeIdentity"] = ["sourceID":"different-source","accountID":"default","libraryProfile":"production:stable"]
        }
        XCTAssertThrowsError(try LegadoPersistentState(sourceID:"source",libraryProfile:"production:stable",directory:directory,vault:vault)) { XCTAssertEqual($0 as? LegadoStateError,.corrupt) }
    }

    func testFailedMigrationPreservesLegacyDataAndDoesNotPublishTargetSessionOrDevice() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let vault = IdentityTestVault(), legacy = LegadoStateScope(sourceID:"source",libraryProfile:"production:/old/known/path"), target = LegadoStateScope(sourceID:"source",libraryProfile:"production:stable")
        let state = try LegadoPersistentState(sourceID:"source",libraryProfile:legacy.libraryProfile,directory:directory,vault:vault)
        try state.setLoginInfo(["user":"synthetic"])
        let device = try state.deviceIdentifier(), oldFile = directory.appendingPathComponent(legacy.id + ".sealed")
        let original = try Data(contentsOf:oldFile)
        XCTAssertThrowsError(try LegadoPersistentState.migrateLegacyScope(from:legacy,to:target,directory:directory,vault:vault,writer:IdentityFailingWriter()))
        XCTAssertEqual(try Data(contentsOf:oldFile),original)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(target.id + ".sealed").path))
        XCTAssertNil(try vault.read(id:"installation." + target.id))
        XCTAssertEqual(try state.deviceIdentifier(),device)
        XCTAssertEqual(try state.getLoginInfoMap(),["user":"synthetic"])
        XCTAssertTrue(try LegadoPersistentState.migrateLegacyScope(from:legacy,to:target,directory:directory,vault:vault))
    }
}
