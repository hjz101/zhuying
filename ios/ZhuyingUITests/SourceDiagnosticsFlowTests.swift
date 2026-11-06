import XCTest

final class SourceDiagnosticsFlowTests: XCTestCase {
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    @MainActor private func tap(_ labels: [String], app: XCUIApplication) {
        for label in labels {
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if item.exists && item.isHittable { item.tap(); return }
        }
    }
    @MainActor private func enterSources(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10)); app.tabBars.buttons["我的"].tap()
        let sources = app.buttons["profileSources"]; reveal(sources, app: app); sources.tap()
    }
    @MainActor private func importFixture(_ app: XCUIApplication) {
        app.buttons["sourceAdd"].tap(); app.buttons["导入书源"].tap()
        let methods = app.segmentedControls["sourcePackageMethod"]
        XCTAssertTrue(methods.waitForExistence(timeout: 5)); methods.buttons["JSON 文件"].tap(); app.buttons["选择 JSON 文件"].tap()
        let file = app.collectionViews["File View"].descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "竹影诊断原创夹具")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            tap(["Browse", "浏览"], app: app); tap(["Browse", "浏览"], app: app); tap(["On My iPhone", "我的iPhone", "我的 iPhone"], app: app)
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "identifier IN %@", ["竹影, Container", "Zhuying, Container"])).firstMatch
            if folder.waitForExistence(timeout: 5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription); file.tap(); tap(["Open", "打开"], app: app)
        let confirm = app.buttons["sourcePackageConfirm"]; XCTAssertTrue(confirm.waitForExistence(timeout: 8)); reveal(confirm, app: app); confirm.tap()
        XCTAssertTrue(app.staticTexts["sourcePackageMessage"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    @MainActor private func openDebug(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'source-row-' AND label CONTAINS %@", "竹影诊断原创夹具")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); reveal(row, app: app); row.tap()
        let entry = app.buttons.containing(.staticText, identifier: "书源调试").firstMatch
        reveal(entry, app: app); entry.tap()
        XCTAssertTrue(app.textFields["sourceDiagnosticQuery"].waitForExistence(timeout: 5))
    }
    @MainActor private func setFullMode(_ app: XCUIApplication) {
        let picker = app.buttons["sourceDiagnosticMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap(); app.buttons["完整验收"].tap()
    }
    @MainActor private func enterQuery(_ text: String, app: XCUIApplication) {
        let query = app.textFields["sourceDiagnosticQuery"]; query.tap(); query.typeText(text + "\n")
    }
    @MainActor func testOriginalFilesImportTwoBooksSixChaptersAndRealProcessRestart() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--source-diagnostic-fixtures"]; app.launch()
        enterSources(app); importFixture(app); openDebug(app); setFullMode(app); enterQuery("原创", app: app)
        let run = app.buttons["sourceDiagnosticRun"]; reveal(run, app: app); run.tap()
        let status = app.staticTexts["sourceAcceptanceStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(status.label, "首次检查完成，等待真正重启")
        let verify = app.buttons["sourceAcceptanceVerifyRestart"]; reveal(verify, app: app); XCTAssertFalse(verify.isEnabled)
        app.terminate()
        app.launchArguments += ["--preserve-ui-test-state"]; app.launch()
        enterSources(app); openDebug(app); setFullMode(app); enterQuery("原创", app: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10)); reveal(verify, app: app); XCTAssertTrue(verify.isEnabled); verify.tap()
        let verified = expectation(for: NSPredicate(format: "label == %@", "测试夹具已通过跨进程重启复核"), evaluatedWith: status)
        wait(for: [verified], timeout: 20)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "竹影原创诊断两书六章真实重启"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.buttons["sourceDiagnosticExport"].exists)
    }
    @MainActor func testAuthenticationFailureUsesOriginalLoginRouteAndPreservesRetry() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--source-diagnostic-fixtures"]; app.launch()
        enterSources(app); importFixture(app); openDebug(app); enterQuery("登录", app: app)
        let run = app.buttons["sourceDiagnosticRun"]; reveal(run, app: app); run.tap()
        let issue = app.staticTexts["sourceDiagnosticIssue-loginRequired"]
        XCTAssertTrue(issue.waitForExistence(timeout: 15), app.debugDescription)
        let login = app.buttons["sourceDiagnosticLogin"]; reveal(login, app: app); login.tap()
        XCTAssertTrue(app.textFields["legadoLoginField-原创账号"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let retry = app.buttons["sourceDiagnosticRetry"]; reveal(retry, app: app); retry.tap()
        XCTAssertTrue(issue.waitForExistence(timeout: 15)); XCTAssertFalse(app.staticTexts["sourceAcceptanceStatus"].exists)
    }
}
