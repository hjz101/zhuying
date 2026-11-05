import XCTest

final class ProductionLaunchTests: XCTestCase {
    @MainActor
    func testProductionOpenFailureCanRetryInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production", "--storage-retry-fixture"]
        app.launch()
        let alert = app.alerts["本地记录提示"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["书库读取或升级失败，原有文件和记录已保留，请重试。"].exists)
        alert.buttons["重试"].tap()
        XCTAssertTrue(app.staticTexts["这里还没有故事"].waitForExistence(timeout: 10))
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.alerts.firstMatch)
        wait(for: [dismissed], timeout: 5)
    }

    @MainActor
    func testProductionThemeSelectionSurvivesRestartUsingOriginalThemePage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production"]
        app.launch()
        XCTAssertTrue(app.staticTexts["这里还没有故事"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        let themes = app.buttons["profileThemes"]
        for _ in 0..<8 { if themes.isHittable { break }; app.swipeUp() }
        themes.tap()
        let night = app.buttons["theme-card-night"]
        for _ in 0..<8 { if night.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(night.isHittable); night.tap()
        app.buttons["themeApply"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["activeThemeCard"].label.contains("夜读深林"))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]
        app.launch()
        XCTAssertTrue(app.staticTexts["这里还没有故事"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        for _ in 0..<8 { if themes.isHittable { break }; app.swipeUp() }
        themes.tap()
        XCTAssertTrue(app.buttons["activeThemeCard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["activeThemeCard"].label.contains("夜读深林"))
    }
    @MainActor
    func testLegacyLibraryMigratesAndRestartIgnoresStaleBrokenArchive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production", "--legacy-library-fixtures"]
        app.launch()
        let resume = app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第二章 重逢")
        XCTAssertTrue(app.staticTexts["升级前已经读到的真实段落。"].exists)
        XCTAssertFalse(app.buttons["dismissGestureGuide"].exists)
        app.buttons["readerSettings"].tap()
        XCTAssertTrue(app.navigationBars["阅读偏好"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["返回书架"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state", "--corrupt-migrated-legacy-fixtures"]
        app.launch()
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第二章 重逢")
        XCTAssertTrue(app.staticTexts["升级前已经读到的真实段落。"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Production-Legacy-Migration-Restored"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
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
