import XCTest

final class ThemeAssetsFlowTests: XCTestCase {
    @MainActor private func launch(fixtures: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = fixtures ? ["--ui-testing", "--theme-fixtures"] : ["--ui-testing"]
        app.launch(); app.tabBars.buttons["我的"].tap()
        let themes = app.buttons["profileThemes"]
        reveal(themes, app: app); themes.tap()
        XCTAssertTrue(app.segmentedControls["themeLibraryTabs"].waitForExistence(timeout: 8))
        // Start this mixing scenario with an explicitly selected theme. A fresh
        // reader otherwise shows its independent paper-color card.
        app.buttons["theme-card-paper"].tap()
        app.buttons["themeApply"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func tab(_ title: String, app: XCUIApplication) {
        let tabs = app.segmentedControls["themeLibraryTabs"]
        for _ in 0..<8 { if tabs.isHittable { break }; app.swipeDown() }
        tabs.buttons[title].tap()
    }
    @MainActor private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testCSSAndSVGLibrariesMixAndMissingAttachments() {
        let app = launch()
        let ready = ["paper", "white"].map { id in expectation(for: NSPredicate(format: "value == %@", "预览就绪"), evaluatedWith: app.buttons["theme-card-\(id)"]) }
        wait(for: ready, timeout: 20)
        capture(app, "Themes-Bundles")
        tab("章节标题", app: app)
        let title = app.buttons["theme-asset-paper:title:line"]
        reveal(title, app: app); title.tap()
        XCTAssertTrue(app.navigationBars["章节标题预览"].waitForExistence(timeout: 5))
        app.switches["assetLongTitle"].tap()
        capture(app, "Themes-LongTitle")
        app.buttons["themeAssetApply"].tap(); back(app)
        for _ in 0..<8 { if app.buttons["activeThemeCard"].exists { break }; app.swipeDown() }
        XCTAssertTrue(app.buttons["activeThemeCard"].label.contains("山林侧题"))
        tab("段评气泡", app: app)
        let bubble = app.buttons["theme-asset-night:bubble:main"]
        reveal(bubble, app: app); bubble.tap()
        XCTAssertTrue(app.staticTexts["分别预览 3、28、128 条段评"].exists)
        app.switches["assetDarkCanvas"].tap()
        capture(app, "Themes-SVGBubbles")
        app.buttons["themeAssetFavorite"].tap(); app.buttons["themeAssetApply"].tap(); back(app)
        let current = app.buttons["activeThemeCard"]
        for _ in 0..<8 { if current.exists { break }; app.swipeDown() }
        XCTAssertTrue(current.label.contains("暖纸山林")); XCTAssertTrue(current.label.contains("山林侧题")); XCTAssertTrue(current.label.contains("夜读深林·气泡"))
        current.tap(); app.buttons["themeCustomize"].tap()
        XCTAssertTrue(app.navigationBars["自定义搭配"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["mixTheme"].tap(); app.buttons["夜读深林"].tap()
        capture(app, "Themes-CustomMix")
        app.buttons["applyThemeMix"].tap(); back(app)
        XCTAssertTrue(current.label.contains("当前使用 · 夜读深林")); XCTAssertTrue(current.label.contains("山林侧题"))
        tab("主题套装", app: app)
        let white = app.buttons["theme-card-white"]
        reveal(white, app: app); white.tap()
        let missing = app.staticTexts["未附带，保留当前样式"].firstMatch
        reveal(missing, app: app)
        app.buttons["themeApply"].tap(); back(app)
        XCTAssertTrue(current.label.contains("当前使用 · 纯白阅读"))
        XCTAssertTrue(current.label.contains("山林侧题")); XCTAssertTrue(current.label.contains("夜读深林·气泡"))
    }

    @MainActor func testFileImportIncludesAssetsAndIndependentResources() {
        let app = launch(fixtures: true)
        app.buttons["themeImport"].tap(); app.buttons["选择套装文件"].tap()
        let file = app.collectionViews["File View"].descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "阅读套装")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            for labels in [["Browse", "浏览"], ["Browse", "浏览"], ["On My iPhone", "我的iPhone", "我的 iPhone"]] {
                for label in labels {
                    let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if item.exists && item.isHittable { item.tap(); break }
                }
            }
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "identifier IN %@", ["阅山, Container", "Yueshan, Container"])).firstMatch
            if folder.waitForExistence(timeout: 5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription); file.tap()
        if app.buttons["Open"].waitForExistence(timeout: 1) { app.buttons["Open"].tap() }
        else if app.buttons["打开"].exists { app.buttons["打开"].tap() }
        XCTAssertTrue(app.staticTexts["新增 2 套主题、3 款标题、3 款气泡 · 重复 1 项 · 无效 1 项"].waitForExistence(timeout: 10))
        app.buttons["知道了"].tap()
        tab("章节标题", app: app)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("远山")
        let standalone = app.buttons["theme-asset-standalone:title:solo"]
        XCTAssertTrue(standalone.waitForExistence(timeout: 5)); standalone.tap()
        XCTAssertTrue(app.staticTexts["独立样式包 · CSS 章节标题"].exists)
        app.buttons["themeAssetApply"].tap(); back(app)
        XCTAssertTrue(app.buttons["activeThemeCard"].label.contains("远山独立标题"))
    }
}
