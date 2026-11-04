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
        reveal(dark, in: app)
        dark.tap()
        reveal(app.segmentedControls.buttons["24"], in: app)
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
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 { if element.isHittable { return }; app.swipeUp() }
    }

    @MainActor
    func testPagedReadingTapZonesSliderAndModeSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        app.buttons["readerSettings"].tap()
        app.segmentedControls.buttons["左右翻页"].tap()
        let tapToggle = app.switches["tapToTurnToggle"]
        tapToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(tapToggle.value as? String, "1")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 1 /"))
        XCTAssertTrue(app.buttons["readerTapCenter"].waitForExistence(timeout: 5))
        app.buttons["nextChapter"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 2 /"))
        // Both edges advance; only the center controls the toolbar.
        app.buttons["readerTapLeft"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 3 /"), app.staticTexts["readerPageStatus"].label)
        app.buttons["readerTapRight"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 4 /"), app.staticTexts["readerPageStatus"].label)
        app.buttons["readerTapCenter"].swipeRight()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 3 /"))
        app.buttons["readerTapCenter"].swipeLeft()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 4 /"))
        app.buttons["readerTapCenter"].tap()
        XCTAssertTrue(app.buttons["showReaderControls"].waitForExistence(timeout: 5))
        app.buttons["showReaderControls"].tap()
        XCTAssertTrue(app.buttons["readerContents"].isHittable)
        let slider = app.sliders["chapterSlider"]
        slider.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertNotEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["readerSettings"].tap()
        app.segmentedControls.buttons["上下滚动"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["continuousText"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["readerContents"].isHittable)
    }

    @MainActor
    func testBatchShelfRemovalUndoAndSorting() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let manage = app.buttons["manageShelf"]
        reveal(manage, in: app)
        manage.tap()
        app.buttons["select-changfeng"].tap()
        app.buttons["select-stars"].tap()
        app.buttons["removeSelected"].tap()
        app.buttons["移出收藏，保留阅读进度"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 5))
        app.buttons["撤销"].tap()
        let sorting = app.buttons["shelfSort"]
        reveal(sorting, in: app)
        sorting.tap()
        app.buttons["加入时间"].tap()
        XCTAssertTrue(app.staticTexts["按加入时间排列"].waitForExistence(timeout: 5))
        app.buttons["manageShelf"].tap()
        XCTAssertTrue(app.buttons["select-changfeng"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["select-stars"].exists)
    }

    @MainActor
    func testHistoryFindsUnfavoritedBook() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("明日")
        app.buttons["result-echo"].tap()
        app.buttons["detailRead"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["我的"].tap()
        app.buttons["readingHistory"].tap()
        XCTAssertTrue(app.buttons["history-echo"].waitForExistence(timeout: 5))
        app.buttons["history-save-echo"].tap()
        XCTAssertFalse(app.buttons["history-save-echo"].exists)
        app.buttons["history-echo"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 记忆商店")
    }

    @MainActor
    func testSimulatedUpdatesResumeAndMarkRead() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["shelfUpdates"].tap()
        XCTAssertTrue(app.buttons["update-read-changfeng"].waitForExistence(timeout: 5))
        app.buttons["update-read-changfeng"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第十章 长夜将明")
        app.buttons["返回书架"].tap()
        app.buttons["shelfUpdates"].tap()
        XCTAssertTrue(app.staticTexts["更新 2 章"].waitForExistence(timeout: 5))
        let simulate = app.buttons["simulateUpdates"]
        reveal(simulate, in: app)
        simulate.tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["更新 3 章"].firstMatch.waitForExistence(timeout: 5))
    }

}
