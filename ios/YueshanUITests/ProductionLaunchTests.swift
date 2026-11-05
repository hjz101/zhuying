import XCTest

final class ProductionLaunchTests: XCTestCase {
    @MainActor
    func testProductionSourceLoginHasRealFieldsAndEmptyToolsDoNotCrash() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production"]
        app.launch()
        let groups = app.buttons["shelf-feature-shelf"]
        XCTAssertTrue(groups.waitForExistence(timeout: 10))
        groups.tap()
        XCTAssertTrue(app.staticTexts["当前版本暂不支持此功能。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["我的"].tap()
        let sources = app.buttons["profileSources"]
        if !sources.isHittable { app.swipeUp() }
        sources.tap()
        XCTAssertTrue(app.buttons["source-row-shushan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sourceManage"].exists)
        app.buttons["source-row-shushan"].tap()
        XCTAssertTrue(app.buttons["sourceDetailLogin"].waitForExistence(timeout: 5))
        app.buttons["sourceDetailLogin"].tap()
        XCTAssertTrue(app.textFields["shushanHost"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["shushanEmail"].exists)
        XCTAssertTrue(app.secureTextFields["shushanPassword"].exists)
        XCTAssertFalse(app.buttons["shushanLogin"].isEnabled)
        XCTAssertFalse(app.staticTexts["界面演示 · 示例数据，本页不连接外部服务"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Production-Shushan-Login"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testProductionEmptyShelfAndDemoRemainIsolatedWithSharedNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf-category-novel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["这里还没有故事"].exists)
        XCTAssertFalse(app.buttons["continueReading"].exists)
        XCTAssertTrue(app.buttons["shelfUpdates"].exists, "Keep the Demo's update entry with truthful empty state")
        XCTAssertFalse(app.buttons["read-changfeng"].exists)
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "Production-Empty-Shelf"
        empty.lifetime = .keepAlways
        add(empty)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["shelfUpdates"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]
        app.launch()
        XCTAssertTrue(app.staticTexts["这里还没有故事"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["continueReading"].exists)
    }
}
