import XCTest

final class GlobalThemeFlowTests: XCTestCase {
    @MainActor private func launch(preserve: Bool = false, inkMountain: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--global-theme-fixtures"] + (preserve ? ["--preserve-ui-test-state"] : []) + (inkMountain ? ["--ink-mountain-theme-fixtures"] : [])
        app.launch(); return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            if element.exists && element.frame.minY < 100 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    @MainActor private func openThemes(_ app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["profileThemes"]; reveal(entry, app: app); entry.tap()
        XCTAssertTrue(app.navigationBars["主题管理"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["globalThemeCreate"].exists)
        XCTAssertFalse(app.buttons["globalThemeEntry"].exists)
    }
    @MainActor private func apply(_ app: XCUIApplication) {
        let apply = app.buttons["globalThemeApply"]; reveal(apply, app: app); apply.tap()
        let confirm = app.buttons["确认应用"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.staticTexts["globalThemeResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["globalThemeResult"].label.contains("已应用"), app.debugDescription)
    }
    @MainActor private func backToManager(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["主题管理"].waitForExistence(timeout: 5))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor func testGlobalThemeAppliesAcrossOriginalNavigationPersistsAndRestores() {
        let app = launch(); openThemes(app)
        let night = app.buttons["globalTheme-zhuying.builtin.night"]; reveal(night, app: app); night.tap()
        XCTAssertTrue(app.otherElements["globalThemePreview"].waitForExistence(timeout: 4))
        apply(app); backToManager(app)
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "幻想夜航")
        capture(app, "竹影-全局主题-幻想夜航")
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["shelfAddBook"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        capture(app, "竹影-夜航书架-原布局")
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 4))
        app.terminate()
        let reopened = launch(preserve: true); openThemes(reopened)
        XCTAssertEqual(reopened.staticTexts["globalThemeCurrent"].label, "幻想夜航")
        let restore = reopened.buttons["globalThemeRestore"]; reveal(restore, app: reopened); restore.tap()
        let current = reopened.staticTexts["globalThemeCurrent"]
        let expected = NSPredicate(format: "label == %@", "竹影原色")
        expectation(for: expected, evaluatedWith: current)
        waitForExpectations(timeout: 8)
    }
    @MainActor func testThemeEditorKeepsExistingPagesAndCanSaveCustomInterface() {
        let app = launch(); openThemes(app)
        app.buttons["globalThemeCreate"].tap()
        XCTAssertTrue(app.navigationBars["制作主题"].waitForExistence(timeout: 4))
        let name = app.textFields.firstMatch
        name.tap(); name.press(forDuration: 1)
        if app.menuItems["全选"].exists { app.menuItems["全选"].tap() }
        if app.buttons["Return"].exists { app.buttons["Return"].tap() }
        app.swipeUp()
        let save = app.buttons["globalThemeEditorSave"]; reveal(save, app: app); save.tap()
        XCTAssertTrue(app.navigationBars["主题管理"].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "我的竹影配色")
        XCTAssertEqual(app.tabBars.buttons.count, 4)
    }
    @MainActor func testExportOffersThemePackageAndAIKitWithoutLeavingCurrentNavigation() {
        let app = launch(); openThemes(app)
        app.buttons["globalThemeExport"].tap()
        XCTAssertTrue(app.navigationBars["打包分享"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["globalThemeGenerate"].exists)
        let kit = app.buttons["globalThemeAuthoringKit"]; reveal(kit, app: app); kit.tap()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["保存", "Save", "存储"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8), app.debugDescription)
        capture(app, "竹影-AI主题制作资料导出")
    }
    @MainActor func testUnifiedThemeManagerKeepsReadingAssetsWithoutAnExtraNavigationLevel() {
        let app = launch(); openThemes(app)
        let tabs = app.segmentedControls["themeLibraryTabs"]
        XCTAssertEqual(tabs.buttons.count, 4)
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
        capture(app, "竹影-统一主题管理")
        tabs.buttons["阅读搭配"].tap()
        XCTAssertTrue(app.buttons["theme-card-paper"].waitForExistence(timeout: 5))
        tabs.buttons["章节标题"].tap()
        XCTAssertTrue(app.buttons["theme-asset-paper:title:line"].waitForExistence(timeout: 5))
        tabs.buttons["段评气泡"].tap()
        XCTAssertTrue(app.buttons["theme-asset-night:bubble:main"].waitForExistence(timeout: 5))
        tabs.buttons["主题"].tap()
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
        XCTAssertTrue(app.buttons["globalThemeExport"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["profileThemes"].waitForExistence(timeout: 5))
        XCTAssertFalse(tabs.exists)
        XCTAssertEqual(app.tabBars.buttons.count, 4)
    }
    @MainActor func testReceivedThemeCanBePreviewedSavedWithoutApplyingThenFullyApplied() {
        let app = launch(); openThemes(app)
        app.buttons["globalThemeImport"].tap()
        chooseThemeFile("竹影完整主题", app: app)
        let save = app.buttons["globalThemeSaveOnly"]; reveal(save, app: app); save.tap()
        XCTAssertTrue(app.staticTexts["globalThemeResult"].label.contains("当前外观保留"))
        apply(app)
        capture(app, "竹影-收到主题包-完整应用")
    }
    @MainActor private func chooseThemeFile(_ prefix: String, app: XCUIApplication) {
        let file = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            for labels in [["Browse", "浏览"], ["Browse", "浏览"], ["On My iPhone", "我的iPhone", "我的 iPhone"]] {
                for label in labels {
                    let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if item.exists && item.isHittable { item.tap(); break }
                }
            }
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "identifier IN %@", ["竹影, Container", "Zhuying, Container"])).firstMatch
            if folder.waitForExistence(timeout: 4) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription); file.tap()
        if app.buttons["Open"].waitForExistence(timeout: 1) { app.buttons["Open"].tap() }
        else if app.buttons["打开"].exists { app.buttons["打开"].tap() }
    }
    @MainActor func testRealInkMountainLightAndDarkPackagesImportApplyAndRenderInExistingShelf() {
        let app = launch(inkMountain: true); openThemes(app)
        for mode in ["浅色", "深色"] {
            app.buttons["globalThemeImport"].tap()
            chooseThemeFile("水墨山水-孤舟-" + mode, app: app)
            apply(app)
            capture(app, "竹影-孤舟-\(mode)-主题预览")
            app.buttons["完成"].tap()
            XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "水墨山水·孤舟（\(mode)）")
            app.tabBars.buttons["书架"].tap()
            XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.tabBars.buttons.count, 4)
            capture(app, "竹影-孤舟-\(mode)-书架")
            app.buttons["continueReading"].tap()
            let guide = app.buttons["dismissGestureGuide"]
            if guide.waitForExistence(timeout: 2) { guide.tap() }
            XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 8))
            capture(app, "竹影-孤舟-\(mode)-实际阅读")
            app.buttons["返回书架"].tap()
            app.tabBars.buttons["我的"].tap()
            XCTAssertTrue(app.navigationBars["主题管理"].waitForExistence(timeout: 5))
        }
    }
}
