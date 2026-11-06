import XCTest
@testable import Zhuying

@MainActor final class SourceDraftTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUpWithError() throws {
        domain = "com.zhuying.source-draft.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: domain) }
    private func json(name: String = "用户原创配置", url: String = "https://user-created.fixture", group: String? = nil, type: Int? = nil) throws -> Data {
        var row: [String: Any] = ["bookSourceName": name, "bookSourceUrl": url]
        if let group { row["bookSourceGroup"] = group }; if let type { row["bookSourceType"] = type }
        return try JSONSerialization.data(withJSONObject: row)
    }
    func testFreshProductionHasNoSourcesAndCreatingOrCancellingDraftDoesNotPersist() throws {
        let store = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        var persisted = 0; store.sourcePersistence = { _ in persisted += 1 }
        XCTAssertTrue(store.sources.isEmpty)
        let id = store.createSource(kind: .comic, group: "用户分组")
        XCTAssertTrue(store.hasSourceDraft(id)); XCTAssertEqual(try store.sourceEditorJSON(id), "{}")
        XCTAssertTrue(store.sources.isEmpty); XCTAssertEqual(persisted, 0)
        XCTAssertNil(defaults.data(forKey: "zhuying.production.sources.v1"))
        store.discardSourceDraft(id)
        XCTAssertFalse(store.hasSourceDraft(id)); XCTAssertEqual(persisted, 0)
        XCTAssertTrue(FeatureDemoStore(defaults: defaults, seedDemoData: false).sources.isEmpty)
        XCTAssertThrowsError(try store.saveSourceJSON(json(), sourceID: id))
    }
    func testValidationLeavesDraftUncommittedAndRejectsEmptyInvalidMultipleOrDuplicateSources() throws {
        let store = FeatureDemoStore(defaults: defaults, seedDemoData: false), id = store.createSource()
        var persisted = 0; store.sourcePersistence = { _ in persisted += 1 }
        let valid = try json()
        XCTAssertEqual(try store.validateSourceJSON(valid, sourceID: id).name, "用户原创配置")
        for bytes in [Data("{}".utf8), Data("invalid".utf8), Data("[]".utf8), try JSONSerialization.data(withJSONObject: [JSONSerialization.jsonObject(with: valid), JSONSerialization.jsonObject(with: json(url: "https://second.fixture"))])] {
            XCTAssertThrowsError(try store.saveSourceJSON(bytes, sourceID: id))
        }
        XCTAssertEqual(persisted, 0); XCTAssertTrue(store.sources.isEmpty); XCTAssertTrue(store.hasSourceDraft(id))
        _ = try store.saveSourceJSON(valid, sourceID: id)
        let another = store.createSource()
        XCTAssertThrowsError(try store.saveSourceJSON(valid, sourceID: another))
        XCTAssertEqual(store.sources.count, 1); XCTAssertEqual(persisted, 1)
    }
    func testSavingDraftUsesUserJSONAndSelectedMetadataThenSurvivesRestart() throws {
        let store = FeatureDemoStore(defaults: defaults, seedDemoData: false), id = store.createSource(kind: .comic, group: "用户分组")
        let source = try store.saveSourceJSON(json(), sourceID: id)
        XCTAssertEqual(source.id, id); XCTAssertEqual(source.kind, .comic); XCTAssertEqual(source.group, "用户分组")
        XCTAssertFalse(store.hasSourceDraft(id)); XCTAssertEqual(store.sources, [source])
        let reopened = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        XCTAssertEqual(reopened.sources, [source])
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.configuration)) as? [String: Any])
        XCTAssertEqual(raw["bookSourceType"] as? Int, 2); XCTAssertNil(raw["endpoints"])
        XCTAssertFalse(try reopened.sourceEditorJSON(id).contains("books.example"))
    }
    func testExplicitJSONMetadataOverridesDraftFilterAndExistingEditorUpdatesOneIdentity() throws {
        let store = FeatureDemoStore(defaults: defaults, seedDemoData: false), id = store.createSource(kind: .comic, group: "筛选分组")
        let first = try store.saveSourceJSON(json(group: "JSON分组", type: 0), sourceID: id)
        XCTAssertEqual(first.kind, .novel); XCTAssertEqual(first.group, "JSON分组")
        let updated = try store.saveSourceJSON(json(name: "修改后的用户源", url: "https://updated.fixture"), sourceID: id)
        XCTAssertEqual(updated.id, first.id); XCTAssertEqual(store.sources.count, 1)
        XCTAssertEqual(FeatureDemoStore(defaults: defaults, seedDemoData: false).sources.first?.name, "修改后的用户源")
    }
    func testDraftSavesThroughProductionLibraryAndReopensWithoutDefaultSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false, productionPersistence: try ProductionLibraryPersistence(directory: directory))
        await library.bootstrapProductionIfNeeded()
        let store = FeatureDemoStore(defaults: defaults, seedDemoData: false); store.connectReader(library)
        XCTAssertTrue(store.sources.isEmpty)
        let id = store.createSource(); XCTAssertTrue(library.sources.isEmpty)
        let source = try store.saveSourceJSON(json(), sourceID: id)
        let saved = await library.flushPendingWrites(); XCTAssertTrue(saved)
        let reopened = LibraryStore(books: [], defaults: defaults, seedDemoData: false, productionPersistence: try ProductionLibraryPersistence(directory: directory))
        await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.sources, [source])
    }
    func testMissingCredentialCannotEraseImportedNativeAdapterAddress() throws {
        let store = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: json(url: "https://user-native.fixture")) as? [String: Any]); row["adapter"] = "shushan"
        let preview = try SourcePackages.parse(JSONSerialization.data(withJSONObject: row), existing: [])
        _ = store.confirmSourceImport(preview)
        let original = try XCTUnwrap(store.sources.first)
        store.updateShushanAccount(nil, host: ""); XCTAssertEqual(store.sources.first?.url, original.url)
        store.updateShushanAccount(nil, host: "https://another-user.fixture"); XCTAssertEqual(store.sources.first?.url, original.url)
        XCTAssertEqual(FeatureDemoStore(defaults: defaults, seedDemoData: false).sources.first?.url, original.url)
        let credential = ShushanCredential(host: URL(string: "https://verified-user.fixture")!, apiKey: "fixture-key", nickname: "原创账号")
        store.updateShushanAccount(credential, host: "")
        XCTAssertEqual(store.sources.first?.url, credential.host.absoluteString)
    }
}
