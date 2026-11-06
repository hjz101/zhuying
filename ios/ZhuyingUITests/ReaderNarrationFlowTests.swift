import XCTest

final class ReaderNarrationFlowTests: XCTestCase {
    @MainActor func testUnfavoritedReaderOffersShelfAfterTwoVisibleMinutes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production", "--legacy-library-fixtures", "--narration-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10))
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.buttons["readerMoreTools"].waitForExistence(timeout: 10))
        app.buttons["readerMoreTools"].tap(); app.buttons["取消收藏"].tap()
        XCTAssertFalse(app.alerts["加入书架？"].exists)
        let invitation = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.alerts["加入书架？"])
        wait(for: [invitation], timeout: 130)
        XCTAssertTrue(app.alerts["加入书架？"].buttons["暂不加入"].exists)
        app.alerts["加入书架？"].buttons["加入书架"].tap()
        app.buttons["readerMoreTools"].tap()
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5))
    }

    @MainActor func testNativeNarrationMiniPlayerPauseManualPagingAndReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production", "--legacy-library-fixtures", "--narration-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10))
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.buttons["readerNarration"].waitForExistence(timeout: 10))
        app.buttons["readerNarration"].tap(); app.buttons["系统朗读"].tap()
        XCTAssertTrue(app.buttons["narrationPlay"].waitForExistence(timeout: 5))
        app.buttons["narrationPlay"].tap()
        let playing = expectation(for: NSPredicate(format: "label CONTAINS '正在播放'"), evaluatedWith: app.staticTexts["narrationStatus"])
        wait(for: [playing], timeout: 15)
        app.buttons["完成"].tap()
        let toggle = app.buttons["miniPlayerToggle"]
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Reader-After-Returning-From-Narration"; initial.lifetime = .keepAlways; add(initial)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription); XCTAssertEqual(toggle.label, "暂停朗读")
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 44); XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        XCTAssertTrue(app.buttons["readerContents"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["readerContents"].frame.maxY, toggle.frame.minY)
        app.buttons["nextChapter"].tap()
        let follow = app.buttons["miniPlayerFollow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        let page = app.staticTexts["readerPageStatus"].label
        // Reopening playback waits through multiple speech progress callbacks.
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.staticTexts["narrationStatus"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, page)
        toggle.tap(); XCTAssertEqual(toggle.label, "继续朗读")
        follow.tap(); XCTAssertFalse(follow.exists)
        XCTAssertNotEqual(app.staticTexts["readerPageStatus"].label, page)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production-Reader-Narration-Mini-Player"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["readerTapCenter"].tap()
        XCTAssertFalse(app.buttons["readerContents"].exists)
        XCTAssertTrue(toggle.isHittable, "The narration window stays available with reader controls hidden")
        toggle.tap(); XCTAssertEqual(toggle.label, "暂停朗读")
        app.buttons["关闭播放器"].tap()
        XCTAssertFalse(toggle.exists)
    }
}
