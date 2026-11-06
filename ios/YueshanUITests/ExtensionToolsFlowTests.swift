import XCTest

final class ExtensionToolsFlowTests: XCTestCase {
    @MainActor private func open(_ id: String,title: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing","--production"]; app.launch()
        app.tabBars.buttons["我的"].tap()
        let tools = app.buttons["allTools"]
        for _ in 0..<8 { if tools.isHittable { break }; app.swipeUp() }
        tools.tap(); let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText(title)
        let entry = app.buttons["feature-" + id]; XCTAssertTrue(entry.waitForExistence(timeout:5)); entry.tap(); return app
    }
    @MainActor func testUnsignedCloudExplainsMissingEntitlementAndKeepsLocalBackupAvailable() {
        let app = open("icloud",title:"iCloud")
        XCTAssertTrue(app.staticTexts["cloudMessage"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["cloudMessage"].label.contains("尚未启用 iCloud 权限"))
        XCTAssertFalse(app.buttons["cloudSave"].isEnabled)
        app.buttons["本地备份与恢复"].tap()
        XCTAssertTrue(app.navigationBars["本地备份"].waitForExistence(timeout:5))
    }
    @MainActor func testCoverSearchEmptyLibraryRequiresExplicitBookAndQuery() {
        let app = open("covers",title:"封面搜索")
        XCTAssertTrue(app.buttons["coverSearch"].waitForExistence(timeout:5)); XCTAssertFalse(app.buttons["coverSearch"].isEnabled)
        XCTAssertFalse(app.images["coverPreview"].exists); XCTAssertFalse(app.buttons["coverSave"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS 'Open Library'")).firstMatch.exists)
    }
    @MainActor func testVersionedRuleToolParsesUserInputWithoutNetwork() {
        let app = open("sourceDebug",title:"书源调试")
        XCTAssertTrue(app.buttons["sourceRuleTester"].waitForExistence(timeout:5)); app.buttons["sourceRuleTester"].tap()
        let input = app.textViews["ruleInput"]; XCTAssertTrue(input.waitForExistence(timeout:5)); input.tap(); input.typeText("<p>Original story</p><p>Mountain</p>")
        app.swipeUp(); app.buttons["ruleParse"].tap()
        XCTAssertTrue(app.staticTexts["ruleOutput"].waitForExistence(timeout:5)); XCTAssertEqual(app.staticTexts["ruleOutput"].label,"Original story\nMountain")
    }
    @MainActor func testRecordSyncStaysOffWithoutCloudEntitlement() {
        let app = open("icloud",title:"iCloud")
        let entry = app.buttons["cloudRecordSync"]
        for _ in 0..<5 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap(); let toggle = app.switches["recordSyncEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout:5)); XCTAssertEqual(toggle.value as? String,"0"); toggle.tap()
        XCTAssertTrue(app.staticTexts["recordSyncMessage"].waitForExistence(timeout:5)); XCTAssertTrue(app.staticTexts["recordSyncMessage"].label.contains("尚未启用 iCloud 权限"))
        XCTAssertEqual(toggle.value as? String,"0"); XCTAssertFalse(app.buttons["recordSyncNow"].isEnabled)
    }
    @MainActor func testScriptHostRunsActualUserProgramWithNetworkOff() {
        let app = open("engine",title:"书源兼容引擎")
        XCTAssertTrue(app.buttons["openScriptHost"].waitForExistence(timeout:5)); app.buttons["openScriptHost"].tap()
        XCTAssertEqual(app.switches["scriptNetwork"].value as? String,"0")
        let program = app.textViews["scriptProgram"]; XCTAssertTrue(program.waitForExistence(timeout:5)); program.tap(); program.typeText("return 1 + 2;")
        let run = app.buttons["scriptRun"]; for _ in 0..<5 { if run.isHittable { break }; app.swipeUp() }; run.tap()
        XCTAssertTrue(app.staticTexts["scriptOutput"].waitForExistence(timeout:10)); XCTAssertEqual(app.staticTexts["scriptOutput"].label,"3")
    }
}
