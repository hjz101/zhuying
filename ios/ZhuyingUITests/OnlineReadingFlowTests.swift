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
            // The directory is below the fold; move it above the fixed reading CTA.
            let contents = app.buttons["detailContents"]
            for _ in 0..<3 {
                if contents.frame.maxY < read.frame.minY - 8 && contents.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(contents.isHittable)
            contents.tap()
            XCTAssertTrue(app.navigationBars["章节目录"].waitForExistence(timeout: 5))
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


extension OnlineReadingFlowTests {
    @MainActor func testReaderRefreshAndBothCacheActionsKeepCurrentChapterReadable() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--online-fixtures"]; app.launch()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("原生联调")
        let result = app.buttons["online-result-remote-ui-fixture-1"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        let read = app.buttons["detailRead"]
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: read); wait(for: [ready], timeout: 10)
        read.tap()
        if app.buttons["dismissGestureGuide"].waitForExistence(timeout: 2) { app.buttons["dismissGestureGuide"].tap() }
        XCTAssertTrue(app.textViews["continuousText"].waitForExistence(timeout: 10))
        let chapter = app.staticTexts["chapterTitle"].label
        app.buttons["readerMoreTools"].tap()
        app.buttons["readerRefreshChapter"].tap()
        let feedback = app.staticTexts["readerFeedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.label, "正文已刷新")
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        app.buttons["readerMoreTools"].tap(); app.buttons["readerClearCache"].tap()
        let cleared = expectation(for: NSPredicate(format: "label == %@", "本书临时正文缓存已清除"), evaluatedWith: feedback)
        wait(for: [cleared], timeout: 5)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        XCTAssertTrue(app.textViews["continuousText"].exists)
        app.buttons["readerContents"].tap()
        XCTAssertTrue(app.buttons["contentsTools"].waitForExistence(timeout: 5))
        app.buttons["contentsTools"].tap(); app.buttons["contentsClearCache"].tap()
        XCTAssertTrue(app.staticTexts["contentsCacheFeedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chapter-0"].exists)
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        XCTAssertTrue(app.textViews["continuousText"].exists)
    }
}
