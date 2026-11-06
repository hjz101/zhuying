import XCTest

final class ReadingPreferencesFlowTests: XCTestCase {
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<16 {
            if element.isHittable { return }
            if element.exists && element.frame.maxY < 170 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }
    @MainActor private func launchPreferences() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["profileReadingSettings"]; reveal(entry, app); entry.tap()
        XCTAssertTrue(app.buttons["reading-category-layout"].waitForExistence(timeout: 5))
        return app
    }
    @MainActor private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testOverviewTypographyTitleAndPersistence() {
        let app = launchPreferences()
        capture(app, "Native-Reading-Overview")
        XCTAssertFalse(app.staticTexts["更多阅读设置"].exists)
        app.buttons["reading-category-layout"].tap(); app.buttons["reading-body"].tap()
        for (id, position) in [("fontPicker", 0.5), ("lineSpacingPicker", 0.75), ("paragraphSpacingSlider", 0.75)] {
            let slider = app.sliders[id]; reveal(slider, app); slider.adjust(toNormalizedSliderPosition: position)
        }
        let expectedFont = app.sliders["fontPicker"].value as? String
        let linked = app.switches["readingMarginsLinked"]; reveal(linked, app)
        if linked.value as? String == "1" { linked.tap() }
        let left = app.sliders["leftMarginSlider"]; reveal(left, app); left.adjust(toNormalizedSliderPosition: 0.5)
        let right = app.sliders["rightMarginSlider"]; reveal(right, app); right.adjust(toNormalizedSliderPosition: 0.08)
        capture(app, "Native-Typography-And-Margins")
        back(app); app.buttons["reading-title"].tap()
        let source = app.segmentedControls["titleStyleSource"]; reveal(source, app); source.buttons["自定义"].tap()
        let size = app.sliders["titleFontSizeSlider"]; reveal(size, app); size.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertTrue(source.buttons["自定义"].isSelected)
        capture(app, "Native-Custom-Chapter-Title")
        app.terminate(); app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]; app.launch()
        app.tabBars.buttons["我的"].tap(); let entry = app.buttons["profileReadingSettings"]; reveal(entry, app); entry.tap()
        app.buttons["reading-category-layout"].tap()
        XCTAssertTrue(app.buttons["reading-title"].label.contains("个人自定义"))
        app.buttons["reading-body"].tap()
        XCTAssertEqual(app.sliders["fontPicker"].value as? String, expectedFont)
        XCTAssertTrue(app.sliders["lineSpacingPicker"].exists)
    }
    @MainActor func testFreePageElementsAndContentRules() {
        let app = launchPreferences()
        app.buttons["reading-category-layout"].tap(); app.buttons["reading-page-elements"].tap()
        let add = app.buttons["addHeaderElement"]; reveal(add, app); add.tap()
        let field = app.textFields["pageElementText"]; reveal(field, app); field.tap(); field.typeText(" · 山海\n")
        app.swipeUp()
        let x = app.sliders["pageElementX"]; reveal(x, app); x.adjust(toNormalizedSliderPosition: 0.7)
        let y = app.sliders["pageElementY"]; reveal(y, app); y.adjust(toNormalizedSliderPosition: 0.65)
        capture(app, "Native-Free-Header-Elements")
        let remove = app.buttons["removePageElement"]; reveal(remove, app); remove.tap()
        XCTAssertFalse(app.textFields["pageElementText"].exists)
        back(app); back(app)
        app.buttons["reading-category-content"].tap(); app.buttons["reading-style-rules"].tap()
        let addRule = app.buttons["addReadingRule"]; reveal(addRule, app); addRule.tap()
        XCTAssertTrue(app.textFields["readingRuleName"].waitForExistence(timeout: 5))
        let save = app.buttons["saveReadingRule"]; reveal(save, app); save.tap()
        XCTAssertTrue(app.staticTexts["我的正文规则"].waitForExistence(timeout: 5))
        back(app); app.buttons["reading-comments"].tap()
        let bubbles = app.switches["showReadingBubbles"]; reveal(bubbles, app); bubbles.tap()
        let god = app.switches["showGodComments"]; reveal(god, app); god.tap()
        app.buttons["reading-god-skin"].tap()
        let create = app.buttons["createCommentSkin"]; reveal(create, app); create.tap()
        XCTAssertEqual(app.switches["commentSkinFollowsTheme"].value as? String, "0")
        capture(app, "Native-Comment-Skin")
    }
    @MainActor func testPageElementDragUpdatesActualReaderHeader() {
        let app = launchPreferences()
        app.buttons["reading-category-layout"].tap(); app.buttons["reading-page-elements"].tap()
        let enabled = app.switches["readerHeaderEnabled"]; reveal(enabled, app); enabled.tap()
        let book = app.staticTexts["page-element-header-book"]
        reveal(book, app)
        capture(app, "Native-Header-Before-Drag")
        let origin = book.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: 35, dy: 8)))
        let x = app.sliders["pageElementX"]; reveal(x, app)
        XCTAssertNotEqual(x.value as? String, "28 %")
        capture(app, "Native-Dragged-Header")
        app.buttons["readingPreferencesDone"].tap()
        app.tabBars.buttons["书架"].tap(); app.buttons["continueReading"].tap()
        let guide = app.buttons["dismissGestureGuide"]; if guide.waitForExistence(timeout: 3) { guide.tap() }
        XCTAssertTrue(app.staticTexts["reader-page-element-header-book"].waitForExistence(timeout: 5))
        app.textViews["continuousText"].tap()
        XCTAssertFalse(app.buttons["readerSettings"].exists)
        XCTAssertTrue(app.staticTexts["reader-page-element-header-book"].exists)
        capture(app, "Native-Reader-Custom-Header")
    }

    @MainActor func testVerticalPaginationAndIndependentEffectsInReader() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["continueReading"].tap()
        let guide = app.buttons["dismissGestureGuide"]; if guide.waitForExistence(timeout: 3) { guide.tap() }
        let chapter = app.staticTexts["chapterTitle"].label
        app.buttons["readerSettings"].tap(); app.buttons["reading-category-operation"].tap()
        app.segmentedControls["readingModePicker"].buttons["上下翻页"].tap()
        let effect = app.buttons["readingEffectPicker"]; if effect.exists { effect.tap(); app.buttons["覆盖"].tap() }
        app.buttons["readingPreferencesDone"].tap()
        XCTAssertTrue(app.buttons["readerTapCenter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        app.buttons["readerTapCenter"].swipeUp()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 2 /"))
        app.buttons["readerTapCenter"].swipeDown()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 1 /"))
        capture(app, "Native-Vertical-Paged-Reader")
    }
    @MainActor func testToolboxNativeReadingSettingsRoutesExposeLiveControls() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["我的"].tap()
        let toolbox = app.buttons["allTools"]; reveal(toolbox, app); toolbox.tap()
        XCTAssertTrue(app.navigationBars["全部工具"].waitForExistence(timeout: 5))
        let routes = [("pageStyle", "翻页方式"), ("typography", "阅读排版"), ("highlight", "高亮规则"),
                      ("fonts", "字体管理"), ("titleDesign", "章节标题设计"), ("themes", "主题管理")]
        for (id, title) in routes {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            if let old = search.value as? String, old != "搜索模块或功能", !old.isEmpty {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            search.typeText(title)
            let route = app.buttons["feature-\(id)"]
            XCTAssertTrue(route.waitForExistence(timeout: 5), "Missing toolbox route: \(id)")
            XCTAssertFalse(app.staticTexts["tool-status-\(id)"].exists)
            route.tap()
            switch id {
            case "pageStyle":
                let modes = app.segmentedControls["readingModePicker"]
                XCTAssertTrue(modes.waitForExistence(timeout: 5))
                XCTAssertTrue(modes.buttons["上下翻页"].exists)
                modes.buttons["左右翻页"].tap()
                XCTAssertTrue(app.descendants(matching: .any)["readingEffectPicker"].firstMatch.waitForExistence(timeout: 5))
            case "typography":
                let font = app.sliders["fontPicker"]; reveal(font, app)
                XCTAssertTrue(font.isHittable)
                XCTAssertTrue(app.sliders["lineSpacingPicker"].exists)
                XCTAssertTrue(app.sliders["paragraphSpacingSlider"].exists)
                XCTAssertTrue(app.sliders["leftMarginSlider"].exists)
                XCTAssertTrue(app.sliders["rightMarginSlider"].exists)
            case "highlight":
                let add = app.buttons["addReadingRule"]; reveal(add, app)
                XCTAssertTrue(add.isHittable)
                XCTAssertTrue(app.buttons["importReadingRules"].exists)
                XCTAssertTrue(app.switches["reading-rule-enabled-dialogue"].exists)
            case "fonts":
                let sample = app.descendants(matching: .any)["readingFontSample"].firstMatch
                XCTAssertTrue(sample.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["readingFontImport"].exists)
                XCTAssertTrue(app.buttons["reading-font-system"].exists)
            case "titleDesign":
                let source = app.segmentedControls["titleStyleSource"]; reveal(source, app)
                XCTAssertTrue(source.buttons["自定义"].exists)
                source.buttons["自定义"].tap()
                XCTAssertTrue(source.buttons["自定义"].isSelected)
                XCTAssertTrue(app.sliders["titleFontSizeSlider"].exists)
            case "themes":
                let tabs = app.segmentedControls["themeLibraryTabs"]
                XCTAssertTrue(tabs.waitForExistence(timeout: 5))
                XCTAssertTrue(tabs.buttons["章节标题"].exists)
                XCTAssertTrue(tabs.buttons["段评气泡"].exists)
                XCTAssertTrue(app.buttons["globalThemeImport"].exists)
                XCTAssertTrue(app.buttons["globalThemeCreate"].exists)
                tabs.buttons["阅读搭配"].tap()
                XCTAssertTrue(app.buttons["themeImport"].exists)
            default: XCTFail("Unverified native settings route: \(id)")
            }
            back(app)
            XCTAssertTrue(app.navigationBars["全部工具"].waitForExistence(timeout: 5))
        }
    }

}
