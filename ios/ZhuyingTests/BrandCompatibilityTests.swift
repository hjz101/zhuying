import XCTest
import UIKit
@testable import Zhuying

@MainActor final class BrandCompatibilityTests: XCTestCase {
    func testBuiltApplicationUsesZhuyingNameAndBothImportSchemes() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "竹影")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "Zhuying")
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        XCTAssertEqual(types?.first?["CFBundleURLSchemes"] as? [String], ["zhuying", "yueshan"])
    }

    func testDefaultsMigrationPreservesPreferencesAndDoesNotResurrectDeletedValues() {
        let domain = "com.zhuying.brand-tests.\(UUID().uuidString)", oldDomain = BrandCompatibility.legacy(domain)!
        let old = UserDefaults(suiteName: oldDomain)!, current = UserDefaults(suiteName: domain)!
        defer { current.removePersistentDomain(forName: domain); old.removePersistentDomain(forName: oldDomain) }
        old.set("legacy-host", forKey: "yueshan.shushan.host")
        old.set("unchanged", forKey: "other-setting")
        current.set("current-host", forKey: "zhuying.shushan.host")
        let migrated = BrandCompatibility.defaults(domain: domain)
        XCTAssertEqual(migrated.string(forKey: "zhuying.shushan.host"), "current-host")
        XCTAssertEqual(migrated.string(forKey: "other-setting"), "unchanged")
        migrated.removeObject(forKey: "other-setting")
        XCTAssertNil(BrandCompatibility.defaults(domain: domain).object(forKey: "other-setting"))
        current.set(["reading"], forKey: "yueshan.toolbox.v1")
        BrandCompatibility.migrateKeys(current)
        XCTAssertEqual(current.stringArray(forKey: "zhuying.toolbox.v1"), ["reading"])
        XCTAssertNil(current.object(forKey: "yueshan.toolbox.v1"))
    }

    func testLegacySourceAndPurificationPackagesRemainReadableWithNewExports() throws {
        let source = DemoSource(id: "original", name: "原有书源", detail: "", url: "https://reader.test")
        let exported = try SourcePackages.export([source])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "zhuying-sources")
        object["format"] = "yueshan-sources"
        XCTAssertEqual(try SourcePackages.parse(JSONSerialization.data(withJSONObject: object), existing: []).sources.first?.name, source.name)
        object["format"] = "unrelated-sources"
        XCTAssertThrowsError(try SourcePackages.parse(JSONSerialization.data(withJSONObject: object), existing: []))
        let rules = [ContentProcessingRule(name: "原有净化", pattern: "广告")]
        let data = try ContentProcessingStore.encode(rules)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("zhuying-purification"))
        let legacy = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "zhuying-purification", with: "yueshan-purification").utf8)
        XCTAssertEqual(try ContentProcessingStore.decode(legacy), rules)
    }

    func testLegacyBackupKeepsPayloadAndChecksumValidation() throws {
        let database = LibraryDatabaseArchive(books: [], chapters: [], progress: [], bookmarks: [], favorites: [], groups: [:], preferences: [ProductionLibraryPersistence.migrationKey: Data("1".utf8)])
        let backup = LibraryBackup(createdAt: Date(), database: database, documents: [], resources: [])
        let data = try backup.encoded()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["format"] as? String, "zhuying-native-backup")
        envelope["format"] = "yueshan-native-backup"
        XCTAssertEqual(try LibraryBackup.decode(JSONSerialization.data(withJSONObject: envelope)).createdAt, backup.createdAt)
        envelope["digest"] = "changed"
        XCTAssertThrowsError(try LibraryBackup.decode(JSONSerialization.data(withJSONObject: envelope)))
    }

    func testLegacyInlineImagesAndLinksRetainMeaning() throws {
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in UIColor.green.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 2, height: 2)).fill() }.pngData())
        let token = try ReaderInlineImage.token(bytes)
        XCTAssertTrue(token.hasPrefix("zhuying-inline-image-v1:"))
        let old = token.replacingOccurrences(of: "zhuying-", with: "yueshan-")
        XCTAssertEqual(ReaderInlineImage.data(old), bytes)
        XCTAssertEqual(ReaderInlineImage.plainText(old), "［插图］")
        XCTAssertNotNil(ReaderInlineImage.image(old))
        for scheme in ["zhuying", "yueshan"] {
            let url = URL(string: "\(scheme)://import?kind=source&url=https://reader.test/source.json")!
            XCTAssertEqual(try ShareImportRequest.parse(url).kind, .source)
        }
    }

    func testServiceKeychainMigratesCredentialsAndDeletionCannotRestoreOldKeys() throws {
        let service = "com.zhuying.brand-tests.\(UUID().uuidString)"
        let old = ServiceKeychain(service: BrandCompatibility.legacy(service)!), current = ServiceKeychain(service: service)
        defer { try? current.remove(id: "synthetic") }
        try old.save("synthetic-test-key", id: "synthetic")
        XCTAssertEqual(try current.ids(), ["synthetic"])
        XCTAssertEqual(try current.read(id: "synthetic"), "synthetic-test-key")
        XCTAssertNil(try old.read(id: "synthetic"))
        try old.save("older-key", id: "synthetic")
        try current.remove(id: "synthetic")
        XCTAssertNil(try current.read(id: "synthetic"))
    }

    func testShushanKeychainMigratesLoginAndLogoutRemovesLegacyLogin() throws {
        let service = "com.zhuying.brand-account.\(UUID().uuidString)"
        let old = ShushanKeychain(service: BrandCompatibility.legacy(service)!), current = ShushanKeychain(service: service)
        let host = URL(string: "https://reader.test")!
        defer { try? current.remove(host: host) }
        let credential = ShushanCredential(host: host, apiKey: "synthetic-test-key", nickname: "测试", deviceID: "synthetic-device")
        try old.save(credential)
        XCTAssertEqual(try current.load(host: host), credential)
        XCTAssertNil(try old.load(host: host))
        try old.save(credential)
        try current.remove(host: host)
        XCTAssertNil(try current.load(host: host))
    }
}
