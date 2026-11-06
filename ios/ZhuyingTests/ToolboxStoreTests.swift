import XCTest
@testable import Zhuying

@MainActor
final class ToolboxStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        domain = "zhuying.toolbox.tests.\(UUID().uuidString)"; defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testDefaultLimitDuplicateReplacementAndPersistence() {
        let store = ToolboxStore(defaults: defaults)
        XCTAssertEqual(store.pinnedIDs, ["import", "fulltext", "themes", "sources"])
        XCTAssertFalse(store.add("cache"))
        XCTAssertFalse(store.replace("import", with: "themes"))
        XCTAssertFalse(store.replace("missing", with: "cache"))
        XCTAssertTrue(store.replace("import", with: "cache"))
        XCTAssertTrue(store.add("cache"))
        XCTAssertFalse(store.add("missing"))
        XCTAssertEqual(ToolboxStore(defaults: defaults).pinnedIDs, ["cache", "fulltext", "themes", "sources"])
        store.remove("sources"); XCTAssertTrue(store.canAdd)
        XCTAssertTrue(store.add("sourceLogin"))
        XCTAssertEqual(ToolboxStore(defaults: defaults).pinnedIDs.last, "sourceLogin")
    }
    func testOrderingFromEditorAndContextMenu() {
        let store = ToolboxStore(defaults: defaults)
        store.move(from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(store.pinnedIDs, ["fulltext", "themes", "sources", "import"])
        store.move(from: IndexSet([1, 2]), to: 0)
        XCTAssertEqual(store.pinnedIDs, ["themes", "sources", "fulltext", "import"])
        store.shift("import", by: -1)
        XCTAssertEqual(store.pinnedIDs, ["themes", "sources", "import", "fulltext"])
        let before = store.pinnedIDs
        store.move(from: IndexSet(integer: 99), to: 0)
        store.shift("themes", by: -1)
        XCTAssertEqual(store.pinnedIDs, before)
        XCTAssertEqual(ToolboxStore(defaults: defaults).pinnedIDs, before)
    }
    func testExplicitEmptyAndDamagedPreferences() {
        let store = ToolboxStore(defaults: defaults)
        for id in store.pinnedIDs { store.remove(id) }
        XCTAssertTrue(ToolboxStore(defaults: defaults).pinnedIDs.isEmpty)
        defaults.set(["missing", "import", "import", "fulltext", "themes", "sources", "cache"], forKey: ToolboxStore.storageKey)
        XCTAssertEqual(ToolboxStore(defaults: defaults).pinnedIDs, FeatureCatalog.commonToolIDs)
        defaults.set(["missing"], forKey: ToolboxStore.storageKey)
        XCTAssertEqual(ToolboxStore(defaults: defaults).pinnedIDs, FeatureCatalog.commonToolIDs)
        defaults.set("bad", forKey: ToolboxStore.storageKey)
        XCTAssertEqual(ToolboxStore(defaults: defaults).pinnedIDs, FeatureCatalog.commonToolIDs)
    }
    func testCapabilitiesDistinguishLiveImportFromFormatAndServiceDemos() {
        XCTAssertNil(FeatureCatalog.feature("import").capabilityBadge)
        XCTAssertNil(FeatureCatalog.feature("fulltext").capabilityBadge)
        for id in ["epub", "pdf", "txt", "archive", "systemTTS", "onlineTTS", "icloud", "statistics"] {
            XCTAssertEqual(FeatureCatalog.feature(id).capabilityBadge, "演示")
        }
        XCTAssertEqual(FeatureCatalog.feature("sources").capabilityBadge, "部分演示")
        XCTAssertEqual(FeatureCatalog.feature("comments").capabilityBadge, "部分演示")
        for id in ["pageStyle", "typography", "highlight", "fonts", "titleDesign", "themes"] {
            XCTAssertNil(FeatureCatalog.feature(id).capabilityBadge, "Native reading preference route must not be labelled as a demo: \(id)")
        }
    }
    func testNativeReadingMetadataDescribesOnlyImplementedControls() {
        let typography = FeatureCatalog.feature("typography")
        XCTAssertTrue(typography.summary.contains("行距／段距"))
        XCTAssertTrue(typography.summary.contains("独立四边留白"))
        XCTAssertFalse(typography.summary.contains("对齐"))
        XCTAssertFalse(FeatureCatalog.search("两端对齐").contains { $0.id == "typography" })
        let title = FeatureCatalog.feature("titleDesign")
        XCTAssertTrue(title.summary.contains("CSS 子集导入"))
        for unsupported in ["图层", "撤销", "导出", "画布拖动"] { XCTAssertFalse(title.summary.contains(unsupported)) }
        XCTAssertTrue(FeatureCatalog.feature("highlight").summary.contains("正文样式规则"))
        XCTAssertTrue(FeatureCatalog.feature("comments").summary.contains("示例"))
        for id in ["pageStyle", "typography", "highlight", "fonts", "titleDesign", "themes"] {
            XCTAssertTrue(FeatureCatalog.feature(id).fields.isEmpty, "Native settings own their form instead of exposing stale demo fields")
            XCTAssertTrue(FeatureCatalog.feature(id).actions.isEmpty, "Native settings own their actions")
        }
    }

}
