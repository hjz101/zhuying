import XCTest

final class MediaFlowTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing","--production","--media-fixtures"]; app.launch(); return app
    }
    @MainActor private func tools(_ app: XCUIApplication,_ id: String) {
        app.tabBars.buttons["我的"].tap()
        let tools = app.buttons["allTools"]
        for _ in 0..<8 { if tools.isHittable { break }; app.swipeUp() }
        tools.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText(id == "pdf" ? "PDF 阅读" : "压缩包支持")
        let entry = app.buttons["feature-" + id]
        XCTAssertTrue(entry.waitForExistence(timeout:5)); entry.tap()
    }
    @MainActor private func choose(_ name: String,_ app: XCUIApplication) {
        let file = app.collectionViews["File View"].descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH %@",name)).firstMatch
        if !file.waitForExistence(timeout:3) {
            for labels in [["Browse","浏览"],["Browse","浏览"],["On My iPhone","我的iPhone","我的 iPhone"]] {
                for label in labels { let element = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",label)).firstMatch; if element.isHittable { element.tap(); break } }
            }
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format:"identifier IN %@",["竹影, Container","Zhuying, Container"])).firstMatch
            if folder.waitForExistence(timeout:5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout:8),app.debugDescription); file.tap()
        if app.buttons["Open"].waitForExistence(timeout:1) { app.buttons["Open"].tap() }
        else if app.buttons["打开"].exists { app.buttons["打开"].tap() }
    }
    @MainActor private func status(_ text: String,_ app: XCUIApplication) {
        let expectation = expectation(for:NSPredicate(format:"label == %@",text),evaluatedWith:app.staticTexts["mediaPageStatus"])
        wait(for:[expectation],timeout:10)
    }
    @MainActor func testPDFActualImportPagesBookmarkAndRestart() {
        let app = launch(); tools(app,"pdf"); app.buttons["mediaImport"].tap(); choose("原创页面",app)
        XCTAssertTrue(app.buttons["importConfirm"].waitForExistence(timeout:10)); app.buttons["importConfirm"].tap()
        XCTAssertTrue(app.staticTexts["importSummary"].waitForExistence(timeout:10)); app.buttons["importShowShelf"].tap()
        let read = app.buttons["阅读原创页面"]
        for _ in 0..<8 { if read.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(read.isHittable); read.tap(); status("第 1 / 3 页",app)
        app.segmentedControls["mediaDisplayMode"].buttons["分页"].tap()
        app.buttons["mediaNextPage"].tap(); status("第 2 / 3 页",app)
        app.buttons["mediaAddBookmark"].tap(); app.buttons["mediaBookmarks"].tap()
        XCTAssertTrue(app.navigationBars["页面书签"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS '第 2 页'")).firstMatch.exists)
        app.buttons["完成"].tap(); app.buttons["返回书架"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing","--production","--preserve-ui-test-state"]; app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout:10)); app.buttons["continueReading"].tap(); status("第 2 / 3 页",app)
        XCUIDevice.shared.orientation = .landscapeLeft; status("第 2 / 3 页",app); XCUIDevice.shared.orientation = .portrait
    }
    @MainActor func testComicActualArchivePreviewPagingStripAndRestart() {
        let app = launch(); tools(app,"archive"); app.buttons["archiveChoose"].tap(); choose("原创漫画",app)
        XCTAssertTrue(app.staticTexts["archiveSummary"].waitForExistence(timeout:10)); XCTAssertTrue(app.staticTexts["archiveSummary"].label.contains("图片 2"))
        app.buttons["archiveImportComic"].tap()
        let imported = expectation(for:NSPredicate(format:"label CONTAINS '漫画已导入'"),evaluatedWith:app.staticTexts["archiveMessage"]); wait(for:[imported],timeout:10)
        app.navigationBars.buttons.element(boundBy:0).tap(); app.navigationBars.buttons.element(boundBy:0).tap(); app.tabBars.buttons["书架"].tap()
        let read = app.buttons["阅读原创漫画"]
        for _ in 0..<8 { if read.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(read.isHittable); read.tap(); status("第 1 / 2 页",app)
        XCTAssertTrue(app.images["漫画页面"].waitForExistence(timeout:10))
        app.buttons["mediaNextPage"].tap(); status("第 2 / 2 页",app); app.buttons["mediaAddBookmark"].tap()
        app.segmentedControls["mediaDisplayMode"].buttons["条漫"].tap(); status("第 2 / 2 页",app)
        app.buttons["返回书架"].tap(); app.terminate(); app.launchArguments = ["--ui-testing","--production","--preserve-ui-test-state"]; app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout:10)); app.buttons["continueReading"].tap(); status("第 2 / 2 页",app)
    }
}
