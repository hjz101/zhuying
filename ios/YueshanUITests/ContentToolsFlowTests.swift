import XCTest

final class ContentToolsFlowTests: XCTestCase {
    @MainActor func testRealLocalSearchHitAndReadingActivitySurviveRestart() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--legacy-library-fixtures"]; app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["allTools"]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        app.buttons["tool-shortcut-fulltext"].tap()
        let query = app.textFields["fulltextQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("保留\n")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fulltext-hit-'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10)); hit.tap()
        let text = app.textViews["continuousText"]
        let rendered = expectation(for: NSPredicate(format: "value CONTAINS '保留的第一章正文'"), evaluatedWith: text)
        wait(for: [rendered], timeout: 10)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 旧信")
        app.buttons["返回书架"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["足迹"].tap()
        XCTAssertTrue(app.staticTexts["activityTotal"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["activityTotal"].label, "0 分钟")
        app.terminate(); app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]; app.launch()
        app.tabBars.buttons["足迹"].tap()
        XCTAssertTrue(app.staticTexts["activityTotal"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["activityTotal"].label, "0 分钟")
    }
}
