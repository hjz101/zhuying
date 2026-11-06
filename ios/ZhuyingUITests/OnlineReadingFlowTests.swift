import XCTest

final class OnlineReadingFlowTests: XCTestCase {
    @MainActor func testTwoFixtureBooksSearchDetailsThreeChaptersAndOfflineRestartWithoutFavorite() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--online-fixtures"]; app.launch()
        for index in 1...2 {
            if index == 1 { app.tabBars.buttons["搜索"].tap() }
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
            if index == 1 { search.typeText("原生联调") }
            let result = app.buttons["online-result-remote-ui-fixture-\(index)"]
            XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
            let read = app.buttons["detailRead"]
            XCTAssertTrue(read.waitForExistence(timeout: 10))
            let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: read); wait(for: [ready], timeout: 10)
            app.buttons["detailContents"].tap()
            XCTAssertTrue(app.buttons["chapter-3"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["chapter-3"].isEnabled)
            app.buttons["完成"].tap(); read.tap()
            if app.buttons["dismissGestureGuide"].waitForExistence(timeout: 2) { app.buttons["dismissGestureGuide"].tap() }
            for chapter in 1...3 {
                let rendered = expectation(for: NSPredicate(format: "value CONTAINS %@", "作品\(index)的第\(chapter)章"), evaluatedWith: app.textViews["continuousText"])
                wait(for: [rendered], timeout: 10)
                if chapter < 3 { app.buttons["nextChapter"].tap() }
            }
            app.buttons["返回书架"].tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.terminate(); app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]; app.launch()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["profileContinueReading"].waitForExistence(timeout: 10)); app.buttons["profileContinueReading"].tap()
        let restored = expectation(for: NSPredicate(format: "value CONTAINS %@", "作品2的第3章"), evaluatedWith: app.textViews["continuousText"])
        wait(for: [restored], timeout: 10)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Online-Fixture-Offline-Restored"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
