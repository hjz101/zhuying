import XCTest

final class SourceDraftFlowTests: XCTestCase {
    @MainActor private func sources(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10)); app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["profileSources"]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap(); XCTAssertTrue(app.buttons["sourceAdd"].waitForExistence(timeout: 5))
    }
    @MainActor private func newDraft(_ app: XCUIApplication) {
        app.buttons["sourceAdd"].tap(); app.buttons["手动新建"].tap()
        XCTAssertTrue(app.textViews["sourceRulesJSON"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["sourceRulesJSON"].value as? String, "{}")
    }
    @MainActor func testEmptySourceLibraryKeepsNewCancelSaveAndRestartOnOriginalPages() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production"]; app.launch(); sources(app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'source-row-'"))
        XCTAssertEqual(rows.count, 0)
        newDraft(app); app.navigationBars.buttons.element(boundBy: 0).tap(); XCTAssertEqual(rows.count, 0)
        app.terminate(); app.launchArguments += ["--preserve-ui-test-state"]; app.launch(); sources(app)
        XCTAssertEqual(rows.count, 0); newDraft(app)
        let editor = app.textViews["sourceRulesJSON"]; editor.tap(); editor.press(forDuration: 1.2)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select All", "全选"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription); selectAll.tap()
        let fixture = #"{"bookSourceName":"竹影用户原创源","bookSourceUrl":"https://user-draft.fixture"}"#
        editor.typeText(fixture)
        XCTAssertEqual(editor.value as? String, fixture, "人工 JSON 夹具实际输入：\(editor.value as? String ?? "<missing>")")
        let save = app.buttons["sourceRulesSave"]
        for _ in 0..<8 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        let message = app.staticTexts["sourceRulesMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("已保存有效配置"), "\(message.label)；人工 JSON 夹具：\(editor.value as? String ?? "<missing>")")
        app.navigationBars.buttons.element(boundBy: 0).tap(); XCTAssertEqual(rows.count, 1)
        app.terminate(); app.launch(); sources(app)
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows.firstMatch.label.contains("竹影用户原创源"))
    }
}
