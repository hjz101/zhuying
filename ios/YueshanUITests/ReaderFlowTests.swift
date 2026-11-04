import XCTest

final class ReaderFlowTests: XCTestCase {
    @MainActor
    func testShelfPrimaryCategoriesAndSecondaryFilters() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let novel = app.buttons["shelf-category-novel"]
        reveal(novel, in: app)
        XCTAssertTrue(novel.isSelected)
        let all = app.buttons["shelf-filter-0"]
        XCTAssertLessThan(novel.frame.maxY, all.frame.minY)
        XCTAssertTrue(all.label.contains("6"))
        app.buttons["shelf-filter-1"].tap()
        XCTAssertTrue(app.buttons["shelf-filter-1"].isSelected)

        for (id, title) in [("comic", "漫画"), ("audio", "听书")] {
            let tab = app.buttons["shelf-category-\(id)"]
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            XCTAssertFalse(novel.isSelected)
            XCTAssertTrue(all.isSelected, "Changing categories resets the secondary filter")
            XCTAssertTrue(all.label.contains("0"))
            XCTAssertTrue(app.staticTexts["还没有收藏的\(title)"].exists)
            XCTAssertFalse(app.buttons["read-changfeng"].exists)
            app.buttons["shelf-filter-1"].tap()
            XCTAssertTrue(app.staticTexts["还没有收藏的\(title)"].exists)
        }

        novel.tap()
        XCTAssertTrue(novel.isSelected)
        XCTAssertTrue(all.isSelected)
        XCTAssertTrue(all.label.contains("6"))
        XCTAssertFalse(app.otherElements["shelfEmptyState"].exists)
        app.buttons["列表布局"].tap()
        XCTAssertTrue(app.buttons["list-read-changfeng"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ShelfPrimaryCategories"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testShelfReaderContentsAndPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let resume = app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        acknowledgeFirstGuide(in: app)
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
        capture(app, name: "UnifiedReadingPreferences")
        let dark = app.buttons["夜读"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        reveal(dark, in: app)
        dark.tap()
        capture(app, name: "UnifiedReadingPreferencesNightSelection")
        reveal(app.segmentedControls.buttons["24"], in: app)
        app.segmentedControls.buttons["24"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["24"].isSelected)
        app.buttons["完成"].tap()
        assertFloatingToolbar(in: app)
        capture(app, name: "FloatingReaderToolbarDark")
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
        acknowledgeFirstGuide(in: app)
        XCTAssertTrue(app.staticTexts["第一章 山脚少年"].waitForExistence(timeout: 5))
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["阅读云海问道"].waitForExistence(timeout: 5))
    }
    @MainActor
    private func acknowledgeFirstGuide(in app: XCUIApplication) {
        let start = app.buttons["dismissGestureGuide"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 { if element.isHittable { return }; app.swipeUp() }
    }

    @MainActor
    private func assertFloatingToolbar(in app: XCUIApplication) {
        let bar = app.otherElements["readerFloatingToolbar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(bar.frame.minX, app.frame.minX + 14)
        XCTAssertLessThanOrEqual(bar.frame.maxX, app.frame.maxX - 14)
        XCTAssertLessThan(bar.frame.maxY, app.frame.maxY - 20)
        XCTAssertLessThanOrEqual(bar.frame.height, 80, "The primary toolbar should stay compact like the home tab bar")
        for id in ["readerContents", "readerSettings", "readerNarration", "readerSkins"] {
            XCTAssertTrue(bar.buttons[id].isHittable, "Bottom controls must remain accessible: \(id)")
        }
        XCTAssertFalse(bar.buttons["readerMoreTools"].exists)
        let more = app.otherElements["readerTopToolbar"].buttons["readerMoreTools"]
        XCTAssertTrue(more.isHittable)
        XCTAssertGreaterThan(more.frame.minX, app.frame.midX)
        XCTAssertLessThan(more.frame.maxY, app.frame.minY + app.frame.height * 0.25)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = name
        preview.lifetime = .keepAlways
        add(preview)
    }

    @MainActor
    func testThemedPreferencesResetAndContentsSearchPreserveProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        let chapter = app.staticTexts["chapterTitle"].label
        app.buttons["readerSettings"].tap()
        app.segmentedControls.buttons["左右翻页"].tap()
        let dark = app.buttons["夜读"]
        reveal(dark, in: app); dark.tap()
        let font = app.segmentedControls.buttons["22"]
        reveal(font, in: app); font.tap()
        let preview = app.staticTexts["readingStylePreview"]
        reveal(preview, in: app)
        XCTAssertTrue(preview.isHittable)
        capture(app, name: "UnifiedReadingStylePreview")

        let advanced = app.buttons["reading-option-typography"]
        reveal(advanced, in: app); advanced.tap()
        XCTAssertTrue(app.navigationBars["阅读排版"].waitForExistence(timeout: 5))
        capture(app, name: "UnifiedAdvancedTypography")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reset = app.buttons["resetReadingSettings"]
        reveal(reset, in: app); reset.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["continuousText"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)

        app.buttons["readerContents"].tap()
        XCTAssertTrue(app.buttons["chapter-2"].waitForExistence(timeout: 5))
        capture(app, name: "UnifiedChapterContents")
        // The system search field hides leading navigation actions while editing.
        app.buttons["正序"].tap()
        XCTAssertTrue(app.buttons["倒序"].exists)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("灯火")
        XCTAssertTrue(app.buttons["chapter-4"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chapter-2"].exists)
        app.buttons["chapter-4"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第五章 灯火入梦")
    }

    @MainActor
    func testReaderToolbarRoutesFavoriteNarrationAndSkins() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        assertFloatingToolbar(in: app)
        let chapter = app.staticTexts["chapterTitle"].label
        let progress = app.staticTexts["readerPageStatus"].label

        app.buttons["readerMoreTools"].tap()
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["系统朗读"].exists)
        XCTAssertFalse(app.buttons["段评与皮肤"].exists)
        capture(app, name: "ReaderMoreMenu")
        app.buttons["取消收藏"].tap()
        app.buttons["readerMoreTools"].tap()
        XCTAssertTrue(app.buttons["加入书架"].waitForExistence(timeout: 5))
        app.buttons["加入书架"].tap()
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, progress)

        for (entry, target, choices) in [
            ("readerNarration", "系统朗读", ["系统朗读", "在线朗读", "AI 多角色朗读"]),
            ("readerSkins", "段评与皮肤", ["主题管理", "段评与皮肤"])
        ] {
            app.buttons[entry].tap()
            for choice in choices { XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 5)) }
            app.buttons[target].tap()
            XCTAssertTrue(app.navigationBars[target].waitForExistence(timeout: 5))
            app.navigationBars.buttons["完成"].tap()
            XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
            XCTAssertEqual(app.staticTexts["readerPageStatus"].label, progress)
        }
    }

    @MainActor
    func testPagedReadingTapZonesSliderAndModeSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
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
        // Do not assume a fixed page count: full-height text fits more per page.
        app.buttons["previousChapter"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 2 /"))
        app.buttons["readerTapRight"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 3 /"), app.staticTexts["readerPageStatus"].label)
        app.buttons["readerTapCenter"].swipeRight()
        XCTAssertTrue(app.buttons["readerSettings"].isHittable, "A swipe must not also trigger the center tap and hide controls")
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 2 /"))
        app.buttons["readerTapCenter"].swipeLeft()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 3 /"))
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
    func testScrollingReaderFillsScreenWithoutMovingWhenControlsToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        let text = app.textViews["continuousText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        assertFloatingToolbar(in: app)
        capture(app, name: "FloatingReaderToolbar")
        text.swipeUp()
        let frame = text.frame
        let progress = app.staticTexts["readerPageStatus"].label
        // UITextView.tap() can choose its top-left accessibility hit point,
        // which now sits under the overlaid back button. Tap the actual center.
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["showReaderControls"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readerSettings"].exists)
        XCTAssertGreaterThan(text.frame.height, app.frame.height * 0.82, "Hidden controls must not reserve space above or below the text")
        XCTAssertGreaterThan(text.frame.maxY, app.frame.maxY - 65, "The text viewport must reach the bottom safe area")
        XCTAssertEqual(text.frame, frame, "Toggling the overlay must not resize or reflow the text")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "ImmersiveScrollingReader"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["showReaderControls"].tap()
        XCTAssertEqual(text.frame, frame)
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, progress)

        // Safe-area layout also fills the shorter viewport after rotation.
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["showReaderControls"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(text.frame.height, app.frame.height * 0.82)
        XCTAssertGreaterThan(text.frame.maxY, app.frame.maxY - 65)
    }

    @MainActor
    func testPagedReaderFillsScreenAndKeepsPageWhenControlsToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        app.buttons["readerSettings"].tap()
        app.segmentedControls.buttons["左右翻页"].tap()
        app.buttons["完成"].tap()
        app.buttons["nextChapter"].tap()
        let page = app.staticTexts["readerPageStatus"].label
        let text = app.otherElements["readerTouchSurface"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let frame = text.frame
        app.buttons["readerTapCenter"].tap()
        XCTAssertTrue(app.buttons["showReaderControls"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readerContents"].exists)
        XCTAssertGreaterThan(text.frame.height, app.frame.height * 0.78, "Pagination must use the full reading height")
        XCTAssertGreaterThan(text.frame.maxY, app.frame.maxY - 85)
        XCTAssertEqual(text.frame, frame)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "ImmersivePagedReader"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["showReaderControls"].tap()
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, page, "Showing controls must preserve the current page and page count")
        XCTAssertEqual(text.frame, frame)
        assertFloatingToolbar(in: app)
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
        acknowledgeFirstGuide(in: app)
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
        acknowledgeFirstGuide(in: app)
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

    @MainActor
    func testFirstReadingGuideOnlyAppearsOnceAcrossBooksAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gestureGuideMode"].label, "当前模式 · 上下滚动")
        XCTAssertTrue(app.staticTexts["gestureGuideTapStatus"].label.contains("需在阅读设置中开启"))
        XCTAssertEqual(app.staticTexts["gestureGuideSwipe"].label, "上下滑动阅读 · 底部箭头切换章节")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "FirstReadingGestureGuide"
        preview.lifetime = .keepAlways
        add(preview)
        acknowledgeFirstGuide(in: app)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["发现"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("群星")
        app.buttons["result-stars"].tap()
        app.buttons["detailRead"].tap()
        XCTAssertTrue(app.staticTexts["第二章 未来来信"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
        app.buttons["返回书架"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]
        app.launch()
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
    }

    @MainActor
    func testGuideCanBeReviewedFromSettingsWithoutChangingReadingPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["阅读偏好"].tap()
        app.segmentedControls.buttons["左右翻页"].tap()
        let tapToggle = app.switches["tapToTurnToggle"]
        tapToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        app.buttons["readingGestureHelp"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gestureGuideMode"].label, "当前模式 · 左右翻页")
        XCTAssertEqual(app.staticTexts["gestureGuideSwipe"].label, "左滑下一页 · 右滑上一页")
        XCTAssertTrue(app.staticTexts["gestureGuideTapStatus"].label.contains("已开启轻触翻页"))
        XCTAssertEqual(app.buttons["dismissGestureGuide"].label, "知道了")
        app.buttons["dismissGestureGuide"].tap()
        app.buttons["完成"].tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["continueReading"].tap()
        // Reviewing help before the first read does not consume the first-use presentation.
        XCTAssertTrue(app.buttons["dismissGestureGuide"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["dismissGestureGuide"].label, "开始阅读")
        acknowledgeFirstGuide(in: app)
        app.buttons["nextChapter"].tap()
        let before = app.staticTexts["readerPageStatus"].label
        app.buttons["readerSettings"].tap()
        app.buttons["readingGestureHelp"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        app.buttons["dismissGestureGuide"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, before)
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
    }

}
