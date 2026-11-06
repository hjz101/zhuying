import XCTest

final class SourcePackageFlowTests: XCTestCase {
    @MainActor private func reveal(_ value: XCUIElement,app: XCUIApplication) { for _ in 0..<8 { if value.isHittable { break }; app.swipeUp() }; XCTAssertTrue(value.isHittable) }
    @MainActor private func tap(_ labels: [String],app: XCUIApplication) {
        for label in labels { let value = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",label)).firstMatch; if value.exists && value.isHittable { value.tap(); return } }
    }
    @MainActor private func openSources(_ app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap(); let entry = app.buttons["profileSources"]; reveal(entry,app:app); entry.tap()
    }
    @MainActor func testNativeJSONFilePreviewConfirmAndSourceRestart() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing","--production","--source-package-fixtures"]; app.launch(); openSources(app)
        app.buttons["sourceAdd"].tap(); app.buttons["导入书源"].tap()
        let picker = app.segmentedControls["sourcePackageMethod"]; XCTAssertTrue(picker.waitForExistence(timeout:5)); picker.buttons["JSON 文件"].tap()
        app.buttons["选择 JSON 文件"].tap()
        let file = app.collectionViews["File View"].descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH '原创书源测试'")).firstMatch
        if !file.waitForExistence(timeout:3) {
            tap(["Browse","浏览"],app:app); tap(["Browse","浏览"],app:app); tap(["On My iPhone","我的iPhone","我的 iPhone"],app:app)
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format:"identifier IN %@",["阅山, Container","Yueshan, Container"])).firstMatch
            if folder.waitForExistence(timeout:5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout:8)); file.tap(); tap(["Open","打开"],app:app)
        let confirm = app.buttons["sourcePackageConfirm"]; XCTAssertTrue(confirm.waitForExistence(timeout:8)); reveal(confirm,app:app); confirm.tap()
        let message = app.staticTexts["sourcePackageMessage"]; XCTAssertTrue(message.waitForExistence(timeout:5)); XCTAssertTrue(message.label.contains("已保存 1 个书源"))
        app.navigationBars.buttons.element(boundBy:0).tap()
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'source-row-' AND label CONTAINS '原创 JSON 书源'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:5)); XCTAssertTrue(row.label.contains("待实测"))
        app.terminate(); app.launchArguments = ["--ui-testing","--production","--preserve-ui-test-state"]; app.launch(); openSources(app)
        XCTAssertTrue(row.waitForExistence(timeout:5))
    }
}
