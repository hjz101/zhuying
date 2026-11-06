import XCTest

final class LegadoSourceFlowTests: XCTestCase {
    @MainActor private func tap(_ labels: [String], app: XCUIApplication) {
        for label in labels {
            let value = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if value.exists && value.isHittable { value.tap(); return }
        }
    }
    @MainActor private func reveal(_ value: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 { if value.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(value.isHittable)
    }
    @MainActor private func run(scripted: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production", "--legado-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10)); app.tabBars.buttons["我的"].tap()
        let sources = app.buttons["profileSources"]; reveal(sources, app: app); sources.tap()
        app.buttons["sourceAdd"].tap(); app.buttons["导入书源"].tap()
        let methods = app.segmentedControls["sourcePackageMethod"]
        XCTAssertTrue(methods.waitForExistence(timeout: 5)); methods.buttons["JSON 文件"].tap()
        app.buttons["选择 JSON 文件"].tap()
        let name = scripted ? "竹影阅读3.0脚本源" : "竹影阅读3.0规则源"
        let file = app.collectionViews["File View"].descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            tap(["Browse", "浏览"], app: app); tap(["Browse", "浏览"], app: app)
            tap(["On My iPhone", "我的iPhone", "我的 iPhone"], app: app)
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "identifier IN %@", ["竹影, Container", "Zhuying, Container"])).firstMatch
            if folder.waitForExistence(timeout: 5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription); file.tap(); tap(["Open", "打开"], app: app)
        let note = app.staticTexts["sourcePackageLegado"]
        XCTAssertTrue(note.waitForExistence(timeout: 8)); XCTAssertTrue(note.label.contains("基础兼容"))
        let confirm = app.buttons["sourcePackageConfirm"]; reveal(confirm, app: app); confirm.tap()
        XCTAssertTrue(app.staticTexts["sourcePackageMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sourcePackageMessage"].label.contains("已保存 1 个书源"))
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("山间来信")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'online-result-'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 12), app.debugDescription); result.tap()
        let read = app.buttons["detailRead"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: read)
        wait(for: [enabled], timeout: 10)
        app.buttons.matching(NSPredicate(format: "label == '加入书架'")).firstMatch.tap()
        read.tap()
        let guide = app.buttons["dismissGestureGuide"]
        if guide.waitForExistence(timeout: 3) { guide.tap() }
        let phrase = scripted ? "第1章通过同步脚本取得的真实测试正文。" : "第1章通过阅读规则取得的真实测试正文。"
        let rendered = expectation(for: NSPredicate(format: "value CONTAINS %@", phrase), evaluatedWith: app.textViews["continuousText"])
        wait(for: [rendered], timeout: 10)
        app.buttons["nextChapter"].tap()
        let next = expectation(for: NSPredicate(format: "value CONTAINS %@", phrase.replacingOccurrences(of: "第1章", with: "第2章")), evaluatedWith: app.textViews["continuousText"])
        wait(for: [next], timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = scripted ? "Legado-Synchronous-Script-Reader" : "Legado-HTML-Rule-Reader"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["返回书架"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--production", "--legado-fixtures", "--preserve-ui-test-state"]; app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10)); app.buttons["continueReading"].tap()
        let restored = expectation(for: NSPredicate(format: "value CONTAINS %@", phrase.replacingOccurrences(of: "第1章", with: "第2章")), evaluatedWith: app.textViews["continuousText"])
        wait(for: [restored], timeout: 10)
    }

    @MainActor func testImportedHTMLRulesSearchReadNextChapterAndRestart() { run(scripted: false) }
    @MainActor func testImportedSynchronousScriptRulesSearchReadNextChapterAndRestart() { run(scripted: true) }
}
