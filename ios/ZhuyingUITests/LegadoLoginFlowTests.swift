import XCTest

final class LegadoLoginFlowTests: XCTestCase {
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func tap(_ labels: [String], app: XCUIApplication) {
        for label in labels {
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if element.exists && element.isHittable { element.tap(); return }
        }
    }
    @MainActor private func enterSources(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10)); app.tabBars.buttons["我的"].tap()
        let sources = app.buttons["profileSources"]; reveal(sources, app: app); sources.tap()
    }
    @MainActor private func openLogin(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'source-row-' AND label CONTAINS %@", "竹影阅读3.0脚本原型")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription); reveal(row, app: app); row.tap()
        let login = app.buttons["sourceDetailLogin"]; reveal(login, app: app); login.tap()
        XCTAssertTrue(app.staticTexts["legadoLoginStatus"].waitForExistence(timeout: 5))
    }
    @MainActor private func importFixture(_ app: XCUIApplication) {
        app.buttons["sourceAdd"].tap(); app.buttons["导入书源"].tap()
        let methods = app.segmentedControls["sourcePackageMethod"]
        XCTAssertTrue(methods.waitForExistence(timeout: 5)); methods.buttons["JSON 文件"].tap(); app.buttons["选择 JSON 文件"].tap()
        let file = app.collectionViews["File View"].descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "竹影阅读3.0脚本源")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            tap(["Browse", "浏览"], app: app); tap(["Browse", "浏览"], app: app); tap(["On My iPhone", "我的iPhone", "我的 iPhone"], app: app)
            let folder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "identifier IN %@", ["竹影, Container", "Zhuying, Container"])).firstMatch
            if folder.waitForExistence(timeout: 5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8)); file.tap(); tap(["Open", "打开"], app: app)
        let confirm = app.buttons["sourcePackageConfirm"]; XCTAssertTrue(confirm.waitForExistence(timeout: 8)); reveal(confirm, app: app); confirm.tap()
        XCTAssertTrue(app.staticTexts["sourcePackageMessage"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor func testOriginalLoginUIStoresInputsAwaitsBrowserAndLogoutClearsRestartedState() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--legado-fixtures"]; app.launch()
        enterSources(app); importFixture(app); openLogin(app)
        let account = app.textFields["legadoLoginField-测试账号"], password = app.secureTextFields["legadoLoginField-测试密码"]
        account.tap(); account.typeText("fixture-reader"); password.tap(); password.typeText("fixture-password")
        let save = app.buttons["保存测试登录"]; reveal(save, app: app); save.tap()
        let feedback = app.staticTexts["legadoLoginMessage"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 8))
        XCTAssertTrue(feedback.label.contains("测试信息已保存"))
        XCTAssertLessThan(feedback.frame.midY, app.windows.firstMatch.frame.height / 2, "Feedback floats above the form regardless of scroll position")
        let dismissFeedback = app.buttons["关闭反馈"]
        if dismissFeedback.isHittable { dismissFeedback.tap() }
        let status = app.staticTexts["legadoLoginStatus"]
        let unverified = expectation(for: NSPredicate(format: "label CONTAINS %@", "尚未验证"), evaluatedWith: status)
        wait(for: [unverified], timeout: 8)
        let browser = app.buttons["打开测试网页登录"]; reveal(browser, app: app); browser.tap()
        XCTAssertTrue(app.buttons["legadoInteractionCancel"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["网页登录脚本已就绪"].waitForExistence(timeout: 8))
        let complete = app.buttons["legadoInteractionComplete"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: complete); wait(for: [ready], timeout: 8)
        complete.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 8)); XCTAssertTrue(status.label.contains("尚未验证"))

        app.terminate(); app.launchArguments += ["--preserve-ui-test-state"]; app.launch()
        enterSources(app); openLogin(app)
        XCTAssertEqual(app.textFields["legadoLoginField-测试账号"].value as? String, "fixture-reader")
        let logout = app.buttons["legadoLogout"]; reveal(logout, app: app); logout.tap(); app.alerts.buttons["退出登录"].tap()
        let signedOut = expectation(for: NSPredicate(format: "label == %@", "尚未登录"), evaluatedWith: app.staticTexts["legadoLoginStatus"])
        wait(for: [signedOut], timeout: 8)
        XCTAssertNotEqual(app.textFields["legadoLoginField-测试账号"].value as? String, "fixture-reader")
    }

    @MainActor func testRightSwipeOffersScopedLoginRefreshAndBrowserWithoutRemovingLeftSwipeEdit() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--legado-fixtures"]; app.launch()
        enterSources(app); importFixture(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'source-row-' AND label CONTAINS %@", "竹影阅读3.0脚本原型")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); reveal(row, app: app)
        let sourceID = String(row.identifier.dropFirst("source-row-".count))
        row.swipeRight()
        XCTAssertTrue(app.buttons["source-leading-login-" + sourceID].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["source-refresh-" + sourceID].exists)
        XCTAssertTrue(app.buttons["source-browser-" + sourceID].exists)
        app.buttons["source-leading-login-" + sourceID].tap()
        XCTAssertTrue(app.staticTexts["legadoLoginStatus"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        row.swipeRight(); app.buttons["source-refresh-" + sourceID].tap()
        XCTAssertTrue(app.staticTexts["sourceRefreshMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sourceRefreshMessage"].label.contains("已刷新"))
        let close = app.buttons["关闭反馈"]; if close.isHittable { close.tap() }
        row.swipeRight(); app.buttons["source-browser-" + sourceID].tap()
        let address = app.textFields["browserAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); XCTAssertTrue((address.value as? String)?.contains("legado-js.fixture") == true)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        row.swipeLeft()
        XCTAssertTrue(app.buttons["source-edit-" + sourceID].waitForExistence(timeout: 3))
    }
}
