import XCTest

final class ProductionLaunchTests: XCTestCase {
    @MainActor
    func testProductionEmptyShelfAndDemoRemainIsolatedWithSharedNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf-category-novel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["这里还没有故事"].exists)
        XCTAssertFalse(app.buttons["continueReading"].exists)
        XCTAssertFalse(app.buttons["shelfUpdates"].exists)
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
