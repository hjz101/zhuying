import XCTest

final class ExtensionToolsFlowTests: XCTestCase {
    @MainActor private func open(_ id: String,title: String,fixtures: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing","--production"] + fixtures; app.launch()
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
    @MainActor func testPurificationPersistsAndReaderReanchorsWithoutChangingOriginal() {
        let app = open("purify",title:"正文净化",fixtures:["--legacy-library-fixtures"])
        app.buttons["purifyAdd"].tap()
        let pattern = app.textViews["purifyPattern"]; XCTAssertTrue(pattern.waitForExistence(timeout:5)); pattern.tap(); pattern.typeText("真实")
        let replacement = app.textFields["purifyReplacement"]
        for _ in 0..<5 { if replacement.isHittable { break }; app.swipeUp() }; replacement.tap(); replacement.typeText("处理")
        let enabled = app.switches["purifyEnabled"]; for _ in 0..<5 { if enabled.isHittable { break }; app.swipeUp() }; enabled.tap()
        let save = app.buttons["purifySave"]; for _ in 0..<7 { if save.isHittable { break }; app.swipeUp() }; save.tap()
        XCTAssertTrue(app.staticTexts["purifyMessage"].waitForExistence(timeout:10))
        app.navigationBars.buttons.element(boundBy:0).tap(); app.navigationBars.buttons.element(boundBy:0).tap(); app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout:10)); app.buttons["continueReading"].tap()
        if app.buttons["从本章开头打开"].waitForExistence(timeout:3) { app.buttons["从本章开头打开"].tap() }
        if app.buttons["dismissGestureGuide"].waitForExistence(timeout:2) { app.buttons["dismissGestureGuide"].tap() }
        let rendered = expectation(for:NSPredicate(format:"value CONTAINS '处理段落'"),evaluatedWith:app.textViews["continuousText"]); wait(for:[rendered],timeout:10)
        app.buttons["返回书架"].tap(); app.terminate(); app.launchArguments = ["--ui-testing","--production","--preserve-ui-test-state"]; app.launch(); app.buttons["continueReading"].tap()
        let restored = expectation(for:NSPredicate(format:"value CONTAINS '处理段落'"),evaluatedWith:app.textViews["continuousText"]); wait(for:[restored],timeout:10)
    }
}
