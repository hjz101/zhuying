import XCTest
import UIKit

final class GlobalThemeFlowTests: XCTestCase {
    @MainActor func testPageEndsRemainVisibleBetweenNativeBarsAfterScrolling() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        let first = app.staticTexts["profileEditorialTitle"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        for _ in 0..<5 { app.swipeUp() }
        let last = app.buttons["allTools"]
        XCTAssertTrue(last.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(last.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertTrue(last.isHittable)
        capture(app, "竹影-页面底部安全边界")
        for _ in 0..<5 { app.swipeDown() }
        XCTAssertGreaterThanOrEqual(first.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(first.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertTrue(first.isHittable)
        capture(app, "竹影-页面顶部安全边界")
    }
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
        XCTAssertTrue(app.buttons["globalThemeTools"].exists)
        XCTAssertFalse(app.buttons["globalThemeEntry"].exists)
    }
    @MainActor private func apply(_ app: XCUIApplication) {
        let apply = app.buttons["globalThemeApply"]; reveal(apply, app: app); apply.tap()
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
    @MainActor private func assertChrome(_ app: XCUIApplication, background: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        // The native focused search page hides its navigation bar behind the search field.
        guard app.navigationBars.firstMatch.exists else { return }
        let cgImage = app.screenshot().image.cgImage!
        let scale = CGFloat(cgImage.width) / app.frame.width
        let bar = app.navigationBars.firstMatch.frame
        var points = [CGPoint(x: app.frame.width / 2, y: bar.minY + 2), CGPoint(x: app.frame.width * 0.12, y: app.frame.height - 4)]
        if app.keyboards.firstMatch.exists { points.removeLast() }
        for (location, point) in points.enumerated() {
            let rect = CGRect(x: floor(point.x * scale), y: floor(point.y * scale), width: 1, height: 1)
            let pixel = cgImage.cropping(to: rect)!
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let expected = [UInt8((background >> 16) & 255), UInt8((background >> 8) & 255), UInt8(background & 255)]
            // The native floating bar casts a shadow into the bottom safe area.
            // Allow that dimming while requiring the theme's color balance.
            let shade = location == 0 ? 1 : Double(rgba.prefix(3).max()!) / Double(expected.max()!)
            XCTAssertGreaterThanOrEqual(shade, 0.55, file: file, line: line)
            XCTAssertLessThanOrEqual(shade, 1.08, file: file, line: line)
            for index in 0..<3 { XCTAssertEqual(Double(rgba[index]), Double(expected[index]) * shade, accuracy: 4, "主题边缘颜色不一致 at \(point): \(rgba)", file: file, line: line) }
        }
    }
    @MainActor func testNativeBarsFollowLightDarkThemesAcrossTabsAndScroll() {
        let app = launch(); openThemes(app)
        capture(app, "竹影-顶部底部-竹影原色")
        assertChrome(app, background: 0xF7F6F0)
        for (id, name, color) in [("night", "幻想夜航", UInt32(0x151622)), ("green", "清透青绿", UInt32(0xF7FAF8))] {
            let card = app.buttons["globalTheme-zhuying.builtin.\(id)"]; reveal(card, app: app); card.tap()
            apply(app); backToManager(app)
            XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, name)
            assertChrome(app, background: color)
            capture(app, "竹影-顶部底部-\(name)-主题库")
            app.tabBars.buttons["书架"].tap()
            XCTAssertTrue(app.buttons["shelfAddBook"].waitForExistence(timeout: 5))
            assertChrome(app, background: color)
            app.swipeUp(); app.swipeDown()
            assertChrome(app, background: color)
            XCTAssertEqual(app.tabBars.buttons.count, 4)
            capture(app, "竹影-顶部底部-\(name)-书架")
            app.tabBars.buttons["搜索"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            assertChrome(app, background: color)
            capture(app, "竹影-顶部底部-\(name)-搜索")
            let closeSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "Cancel", "取消"])).firstMatch
            if closeSearch.exists { closeSearch.tap() }
            if !app.tabBars.buttons["我的"].exists { app.tabBars.buttons["书架"].tap() }
            XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5))
            app.tabBars.buttons["我的"].tap()
            XCTAssertTrue(app.navigationBars["主题管理"].waitForExistence(timeout: 5))
        }
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
        reopened.buttons["globalThemeCurrentMenu"].tap()
        let restore = reopened.buttons["globalThemeRestore"]; restore.tap()
        let current = reopened.staticTexts["globalThemeCurrent"]
        let expected = NSPredicate(format: "label == %@", "竹影原色")
        expectation(for: expected, evaluatedWith: current)
        waitForExpectations(timeout: 8)
    }
    @MainActor func testThemeEditorKeepsExistingPagesAndCanSaveCustomInterface() {
        let app = launch(); openThemes(app)
        app.buttons["globalThemeTools"].tap()
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
        app.buttons["globalThemeCurrentMenu"].tap()
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
        XCTAssertFalse(app.segmentedControls["themeLibraryTabs"].exists)
        app.buttons["globalThemeTools"].tap()
        app.buttons["globalThemeReadingAssets"].tap()
        let tabs = app.segmentedControls["themeLibraryTabs"]
        XCTAssertEqual(tabs.buttons.count, 3)
        capture(app, "竹影-阅读搭配与独立样式")
        tabs.buttons["阅读搭配"].tap()
        XCTAssertTrue(app.buttons["theme-card-paper"].waitForExistence(timeout: 5))
        tabs.buttons["章节标题"].tap()
        XCTAssertTrue(app.buttons["theme-asset-paper:title:line"].waitForExistence(timeout: 5))
        tabs.buttons["段评气泡"].tap()
        XCTAssertTrue(app.buttons["theme-asset-night:bubble:main"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
        XCTAssertTrue(app.buttons["globalThemeCurrentMenu"].exists)
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
    @MainActor func testCardMenuSharesUnusedThemeAndManagementStaysOnLibraryPage() {
        let app = launch(); openThemes(app)
        let more = app.buttons["globalThemeMore-zhuying.builtin.green"]
        reveal(more, app: app); more.tap()
        app.buttons["分享这套主题"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 6), app.debugDescription)
        capture(app, "竹影-未启用主题直接分享")
        app.buttons["header.closeButton"].tap()
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
        let manage = app.buttons["globalThemeManage"]; reveal(manage, app: app); manage.tap()
        XCTAssertTrue(app.buttons["globalThemeSelectAll"].exists)
        app.buttons["globalThemeSelectAll"].tap()
        XCTAssertEqual(app.staticTexts["globalThemeSelectionCount"].label, "已选 3 套")
        XCTAssertFalse(app.buttons["globalThemeBulkDelete"].isEnabled)
        XCTAssertTrue(app.buttons["globalThemeBulkShare"].isEnabled)
        XCTAssertTrue(app.navigationBars["主题管理"].exists)
        capture(app, "竹影-主题库同页批量管理")
    }
    @MainActor func testBubbleQuickScopeKeepsCurrentInterfaceAndCanDeleteActivePartInPlace() {
        let app = launch(); openThemes(app)
        app.buttons["globalThemeImport"].tap(); chooseThemeFile("竹影完整主题", app: app)
        app.buttons["globalThemeScope-bubble"].tap()
        XCTAssertEqual(app.buttons["globalThemeApply"].label, "仅应用气泡")
        XCTAssertTrue(app.staticTexts["globalThemeScopeSummary"].label.contains("其余保留当前搭配"))
        apply(app)
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
        let more = app.buttons["globalThemeMore-zhuying.fixtures.complete"]; reveal(more, app: app); more.tap()
        app.buttons["删除这套主题"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "气泡将恢复默认")).firstMatch.waitForExistence(timeout: 4))
        app.buttons["确认删除"].tap()
        XCTAssertFalse(more.waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["主题管理"].exists)
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
    }
    @MainActor func testLongPressOpensSameThemeActionsWithoutApplyingIt() {
        let app = launch(); openThemes(app)
        let card = app.buttons["globalTheme-zhuying.builtin.green"]; reveal(card, app: app)
        card.press(forDuration: 1)
        XCTAssertTrue(app.buttons["分享这套主题"].waitForExistence(timeout: 4), app.debugDescription)
        app.buttons["选择多个主题"].tap()
        XCTAssertEqual(app.staticTexts["globalThemeSelectionCount"].label, "已选 1 套")
        app.buttons["globalThemeManage"].tap()
        XCTAssertEqual(app.staticTexts["globalThemeCurrent"].label, "竹影原色")
        XCTAssertTrue(app.navigationBars["主题管理"].exists)
    }
    @MainActor func testLibraryLargeTextAndLandscapeKeepControlsVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); openThemes(app)
        let more = app.buttons["globalThemeMore-zhuying.builtin.original"]
        reveal(more, app: app)
        XCTAssertGreaterThanOrEqual(more.frame.width, 44)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        capture(app, "竹影-主题库-辅助大字号")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let manage = app.buttons["globalThemeManage"]; reveal(manage, app: app); manage.tap()
        XCTAssertTrue(app.buttons["globalThemeBulkShare"].isHittable)
        XCTAssertTrue(app.buttons["globalThemeBulkDelete"].isHittable)
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        capture(app, "竹影-主题库-横屏管理")
    }
    @MainActor func testCompactLibraryKeepsCoversDotsAndApplyButtonWithinSafeArea() {
        let app = launch(); openThemes(app)
        let card = app.buttons["globalTheme-zhuying.builtin.original"]
        let more = app.buttons["globalThemeMore-zhuying.builtin.original"]
        XCTAssertGreaterThanOrEqual(more.frame.width, 44)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        XCTAssertGreaterThanOrEqual(card.frame.minX, 0)
        XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.width)
        capture(app, "竹影-封面主题库-透明更多按钮")
        app.buttons["globalTheme-zhuying.builtin.green"].tap()
        let scope = app.buttons["globalThemeScope-icons"]; reveal(scope, app: app); scope.tap()
        XCTAssertEqual(app.buttons["globalThemeApply"].label, "仅应用图标")
        XCTAssertTrue(app.buttons["globalThemeApply"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["globalThemeApply"].frame.maxY, app.tabBars.firstMatch.frame.minY)
        capture(app, "竹影-主题预览-快捷取用")
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
