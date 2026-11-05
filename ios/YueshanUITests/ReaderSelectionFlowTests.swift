import XCTest

final class ReaderSelectionFlowTests: XCTestCase {
    @MainActor func testLongPressCanCopyInScrollingAndPagedModesWithoutTurningChapter() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["continueReading"].tap()
        if app.buttons["dismissGestureGuide"].waitForExistence(timeout: 3) { app.buttons["dismissGestureGuide"].tap() }
        let chapter = app.staticTexts["chapterTitle"].label
        let scrolling = app.textViews["continuousText"]
        XCTAssertTrue(scrolling.waitForExistence(timeout: 5))
        copyText(in: scrolling, app: app)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        XCTAssertTrue(app.buttons["readerSettings"].isHittable)
        app.buttons["readerSettings"].tap()
        app.buttons["reading-category-operation"].tap()
        app.segmentedControls.buttons["左右翻页"].tap()
        app.buttons["完成"].tap()
        let paged = app.textViews["pagedText"]
        XCTAssertTrue(paged.waitForExistence(timeout: 5))
        copyText(in: paged, app: app)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        app.buttons["nextChapter"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 2 /"))
    }
    @MainActor private func copyText(in text: XCUIElement, app: XCUIApplication) {
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.2)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "复制", "拷贝"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
    }
}
