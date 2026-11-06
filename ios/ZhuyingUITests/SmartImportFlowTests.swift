import XCTest

final class SmartImportFlowTests: XCTestCase {
    @MainActor private func assertReaderText(_ value: String, app: XCUIApplication) {
        let rendered = expectation(for: NSPredicate(format: "value CONTAINS %@", value), evaluatedWith: app.textViews["continuousText"])
        wait(for: [rendered], timeout: 5)
    }
    @MainActor private func launch(production: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--import-fixtures"] + (production ? ["--production"] : []); app.launch(); return app
    }
    @MainActor private func openImport(_ app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["profile-tool-import"]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap()
        XCTAssertTrue(app.segmentedControls["importSource"].waitForExistence(timeout: 5))
    }
    @MainActor private func tapAny(_ app: XCUIApplication, labels: [String]) -> Bool {
        for label in labels {
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if element.exists && element.isHittable { element.tap(); return true }
        }
        return false
    }
    @MainActor private func chooseFile(_ name: String, app: XCUIApplication) {
        let file = app.collectionViews["File View"].descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            _ = tapAny(app, labels: ["Browse", "浏览"])
            _ = tapAny(app, labels: ["Browse", "浏览"])
            _ = tapAny(app, labels: ["On My iPhone", "我的iPhone", "我的 iPhone"])
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "identifier IN %@", ["竹影, Container", "Zhuying, Container"])).firstMatch
            if folder.waitForExistence(timeout: 5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
        file.tap()
        if app.buttons["Open"].waitForExistence(timeout: 1) { app.buttons["Open"].tap() }
        else if app.buttons["打开"].exists { app.buttons["打开"].tap() }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testSourcesValidationHelpAndPickerCancellation() {
        let app = launch(); openImport(app)
        XCTAssertTrue(app.buttons["importChooseFiles"].isHittable)
        XCTAssertFalse(app.textFields["importLinkInput"].exists)
        XCTAssertFalse(app.staticTexts["配置与选项"].exists)
        capture(app, "Import-LocalEntry")
        app.buttons["importChooseFiles"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5) || app.buttons["取消"].exists)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.buttons["取消"].tap() }
        let dismissed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["importChooseFiles"])
        wait(for: [dismissed], timeout: 5)
        XCTAssertFalse(app.buttons["importConfirm"].exists)
        app.segmentedControls["importSource"].buttons["链接导入"].tap()
        let input = app.textFields["importLinkInput"]
        XCTAssertTrue(input.exists); input.tap(); input.typeText("not-a-url")
        app.buttons["importRecognizeLink"].tap()
        XCTAssertTrue(app.staticTexts["importMessage"].label.contains("https"))
        app.segmentedControls["importSource"].buttons["剪贴板"].tap()
        XCTAssertTrue(app.buttons["importReadClipboard"].exists)
        XCTAssertFalse(app.staticTexts["importMessage"].exists)
        app.buttons["导入帮助"].tap()
        XCTAssertTrue(app.navigationBars["导入帮助"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["选择 → 预览 → 导入"].exists)
    }

    @MainActor func testShelfAutomaticPickerCancelAndReopenOnlyImportsSelectedFileOnce() {
        let app = launch(production: true)
        app.buttons["shelfAddBook"].tap()
        app.buttons["本地导入"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5) || app.buttons["取消"].exists)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.buttons["取消"].tap() }
        XCTAssertTrue(app.buttons["importChooseFiles"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["importConfirm"].exists)
        app.buttons["importChooseFiles"].tap()
        chooseFile("导入测试", app: app)
        XCTAssertTrue(app.buttons["importConfirm"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["importConfirm"].label.contains("1"))
        XCTAssertFalse(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.buttons["取消"].exists)
        XCTAssertTrue(app.staticTexts["importStatus-导入测试.txt"].exists)
    }

    @MainActor func testActualFileImportReadingDuplicateAndRestart() {
        let app = launch(); openImport(app)
        app.buttons["importChooseFiles"].tap(); chooseFile("导入测试", app: app)
        XCTAssertTrue(app.buttons["importConfirm"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["这是从系统文件选择器导入的真实正文。"].exists)
        capture(app, "Import-FilePreview")
        app.buttons["importConfirm"].tap()
        XCTAssertTrue(app.staticTexts["importSummary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["importSummary"].label.contains("成功 1 项"))
        app.buttons["importAddFiles"].tap(); chooseFile("导入测试", app: app)
        XCTAssertTrue(app.staticTexts["内容重复，已跳过"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["importConfirm"].exists)
        app.buttons["importShowShelf"].tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        let read = app.buttons["阅读导入测试"]
        for _ in 0..<6 { if read.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(read.isHittable); read.tap()
        if app.buttons["dismissGestureGuide"].waitForExistence(timeout: 3) { app.buttons["dismissGestureGuide"].tap() }
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 来信")
        assertReaderText("这是从系统文件选择器导入的真实正文。", app: app)
        app.buttons["nextChapter"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第二章 回声")
        app.buttons["返回书架"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]; app.launch()
        app.tabBars.buttons["我的"].tap()
        XCTAssertEqual(app.staticTexts["profileCurrentBook"].label, "导入测试")
        app.buttons["profileContinueReading"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第二章 回声")
    }

    @MainActor func testShelfShortcutAndUnsupportedFile() {
        let app = launch()
        app.buttons["shelfAddBook"].tap(); app.buttons["本地导入"].tap()
        chooseFile("不支持的格式", app: app)
        let status = app.staticTexts["importStatus-不支持的格式.epub"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("EPUB"), "A malformed EPUB must explain the format error without adding a book")
        XCTAssertFalse(app.buttons["importConfirm"].exists)
        app.buttons["移除不支持的格式.epub"].tap()
        XCTAssertTrue(app.buttons["importChooseFiles"].exists)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["shelfAddBook"].isHittable)
    }

    @MainActor func testProductionDatabaseImportThreeChaptersBackgroundAndRestart() {
        let app = launch(production: true)
        openImport(app)
        app.buttons["importChooseFiles"].tap(); chooseFile("导入测试", app: app)
        XCTAssertTrue(app.buttons["importConfirm"].waitForExistence(timeout: 10))
        app.buttons["importConfirm"].tap()
        XCTAssertTrue(app.staticTexts["importSummary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["importSummary"].label.contains("成功 1 项"))
        app.buttons["importShowShelf"].tap()
        let read = app.buttons["阅读导入测试"]
        for _ in 0..<6 { if read.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(read.isHittable); read.tap()
        if app.buttons["dismissGestureGuide"].waitForExistence(timeout: 3) { app.buttons["dismissGestureGuide"].tap() }
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 来信")
        app.buttons["nextChapter"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第二章 回声")
        app.buttons["nextChapter"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 远山")
        assertReaderText("远山之下的真实正文，来自同一个本地文件。", app: app)
        app.buttons["readerSettings"].tap()
        app.buttons["reading-category-layout"].tap()
        app.buttons["reading-body"].tap()
        let font = app.sliders["fontPicker"]
        for _ in 0..<6 { if font.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(font.isHittable)
        font.adjust(toNormalizedSliderPosition: 0.625)
        let savedFont = font.value as? String
        XCTAssertNotNil(savedFont)
        app.buttons["完成"].tap()
        capture(app, "Production-Database-Third-Chapter")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--production", "--preserve-ui-test-state"]
        app.launch()
        let resume = app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 远山")
        assertReaderText("远山之下的真实正文，来自同一个本地文件。", app: app)
        XCTAssertFalse(app.buttons["dismissGestureGuide"].exists)
        capture(app, "Production-Database-Restored-Reader")
        app.buttons["readerSettings"].tap()
        app.buttons["reading-category-layout"].tap()
        app.buttons["reading-body"].tap()
        for _ in 0..<6 { if font.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(font.value as? String, savedFont)
    }
}
