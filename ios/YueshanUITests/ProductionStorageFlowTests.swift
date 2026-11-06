import XCTest

final class ProductionStorageFlowTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--legacy-library-fixtures"]; app.launch(); return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func openTool(_ id: String, title: String, app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        let tools = app.buttons["allTools"]; reveal(tools, app: app); tools.tap()
        let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title)
        let route = app.buttons["feature-\(id)"]; XCTAssertTrue(route.waitForExistence(timeout: 5)); route.tap()
    }
    @MainActor func testBookmarkAddJumpRestartDeleteAndEmptyGroupPersistence() {
        let app = launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10)); app.buttons["continueReading"].tap()
        XCTAssertTrue(app.textViews["continuousText"].waitForExistence(timeout: 5))
        app.buttons["readerMoreTools"].tap(); app.buttons["书签"].tap()
        XCTAssertTrue(app.buttons["bookmarkAdd"].waitForExistence(timeout: 5)); app.buttons["bookmarkAdd"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-open-")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["完成"].tap(); app.buttons["previousChapter"].tap()
        app.buttons["readerMoreTools"].tap(); app.buttons["书签"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-open-")).firstMatch.tap()
        let restored = expectation(for: NSPredicate(format: "value CONTAINS %@", "升级前已经读到的真实段落"), evaluatedWith: app.textViews["continuousText"]); wait(for: [restored], timeout: 5)
        app.buttons["返回书架"].tap()
        app.buttons["shelf-feature-shelf"].tap()
        let group = app.textFields["shelfNewGroup"]; XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap(); group.typeText("空的分组")
        app.buttons["createShelfGroup"].tap()
        XCTAssertTrue(app.staticTexts["分组已保存。"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]; app.launch()
        XCTAssertTrue(app.buttons["shelf-feature-shelf"].waitForExistence(timeout: 10)); app.buttons["shelf-feature-shelf"].tap()
        app.buttons["shelfGroupPicker"].tap(); XCTAssertTrue(app.buttons["空的分组"].exists); app.buttons["空的分组"].tap()
        XCTAssertTrue(app.staticTexts["此分组还没有作品。"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openTool("bookmarks", title: "书签", app: app)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-delete-")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        XCTAssertTrue(app.staticTexts["暂无书签，可添加当前位置。"].waitForExistence(timeout: 5))
    }
    @MainActor func testFileRenameDeleteCancellationAndPermanentDeleteAreTruthful() {
        let app = launch(); openTool("files", title: "文件管理", app: app)
        let actions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "file-actions-")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap(); app.buttons["重命名"].tap()
        let name = app.alerts.textFields.firstMatch; XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "改名归档")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["改名归档"].waitForExistence(timeout: 5))
        actions.tap(); app.buttons["永久删除"].tap()
        XCTAssertTrue(app.alerts.buttons["取消"].waitForExistence(timeout: 5)); app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["改名归档"].exists)
        let dismissed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: actions); wait(for: [dismissed], timeout: 5)
        actions.tap(); app.buttons["永久删除"].tap(); app.buttons["删除作品、正文和阅读记录"].tap()
        XCTAssertTrue(app.staticTexts["还没有导入文件"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]; app.launch()
        XCTAssertTrue(app.staticTexts["这里还没有故事"].waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["continueReading"].exists)
    }
    @MainActor func testBackupAndCacheKeepOriginalEntriesAndAllowPickerCancellation() {
        let app = launch(); openTool("backup", title: "本地备份", app: app)
        XCTAssertTrue(app.buttons["backupCreate"].waitForExistence(timeout: 5))
        app.buttons["backupChooseRestore"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.buttons["backupCreate"].isHittable)
        app.buttons["backupCreate"].tap()
        XCTAssertTrue(app.staticTexts["备份已生成，请选择保存位置。"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Backup-System-Export"; screenshot.lifetime = .keepAlways; add(screenshot)
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let save = files.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "保存"])).firstMatch
        if save.waitForExistence(timeout: 2) { save.tap() }
        else {
            // iOS 26 can host the Files picker outside either accessibility tree.
            // The retained screenshot verifies its top-right Save button on this QA device.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.106)).tap()
        }
        XCTAssertTrue(app.staticTexts["备份已导出。"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openTool("cache", title: "缓存管理", app: app)
        XCTAssertTrue(app.buttons["clearRecentCache"].waitForExistence(timeout: 5)); app.buttons["clearRecentCache"].tap()
        app.buttons["只清理网络章节缓存"].tap()
        XCTAssertTrue(app.staticTexts["cacheMessage"].waitForExistence(timeout: 5))
    }
}
