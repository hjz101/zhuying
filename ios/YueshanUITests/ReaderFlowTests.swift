import XCTest

final class ReaderFlowTests: XCTestCase {
    @MainActor
    func testShelfReaderContentsAndPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let resume = app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["readerContents"].tap()
        let target = app.buttons["chapter-4"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(app.staticTexts["第五章 灯火入梦"].waitForExistence(timeout: 5))
        app.buttons["readerContents"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["第五章 灯火入梦"].waitForExistence(timeout: 5))
        app.buttons["readerSettings"].tap()
        let dark = app.buttons["夜读"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        app.segmentedControls.buttons["24"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["24"].isSelected)
        app.buttons["完成"].tap()
        app.buttons["返回书架"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.staticTexts["第五章 灯火入梦"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSearchDetailFavoriteAndRead() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("云海")
        let result = app.buttons["result-cloud"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let add = app.buttons["加入书架"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["已在书架"].waitForExistence(timeout: 5))
        app.buttons["detailRead"].tap()
        XCTAssertTrue(app.staticTexts["第一章 山脚少年"].waitForExistence(timeout: 5))
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["阅读云海问道"].waitForExistence(timeout: 5))
    }
}
