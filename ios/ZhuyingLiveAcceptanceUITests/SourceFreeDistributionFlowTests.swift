import XCTest

/// Run against a Release App on a fresh, isolated device. The operator supplies
/// 用户导入验收.json in Documents before launch; the App contains no test source.
final class SourceFreeDistributionFlowTests: XCTestCase {
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor private func openSources(_ app: XCUIApplication) {
        let profile = app.tabBars.buttons["我的"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15), app.debugDescription)
        profile.tap()
        let sources = app.buttons["profileSources"]
        reveal(sources, app: app)
        sources.tap()
        XCTAssertTrue(app.staticTexts["sourceCount"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["source-kind-全部"].exists)
    }

    @MainActor private func assertSourceCount(_ expected: Int, app: XCUIApplication) {
        let count = app.staticTexts["sourceCount"]
        let settled = expectation(for: NSPredicate(format: "label == %@", "\(expected) 个书源"), evaluatedWith: count)
        wait(for: [settled], timeout: 10)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'source-row-'"))
        XCTAssertEqual(rows.count, expected, app.debugDescription)
        if expected == 0 {
            XCTAssertTrue(app.staticTexts["还没有书源"].exists)
        } else {
            XCTAssertTrue(rows.firstMatch.label.contains("用户导入验证"), rows.firstMatch.label)
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func restartAndOpenSources(_ app: XCUIApplication) {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = []
        app.launch()
        openSources(app)
    }

    @MainActor private func tapAvailable(_ labels: [String], app: XCUIApplication) {
        for label in labels {
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if element.exists && element.isHittable {
                element.tap()
                return
            }
        }
    }

    @MainActor private func importExternalJSON(_ app: XCUIApplication) {
        app.buttons["sourceAdd"].tap()
        app.buttons["导入书源"].tap()
        let methods = app.segmentedControls["sourcePackageMethod"]
        XCTAssertTrue(methods.waitForExistence(timeout: 5))
        methods.buttons["JSON 文件"].tap()
        app.buttons["选择 JSON 文件"].tap()

        let file = app.collectionViews["File View"].descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH '用户导入验收'")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            tapAvailable(["Browse", "浏览"], app: app)
            tapAvailable(["Browse", "浏览"], app: app)
            tapAvailable(["On My iPhone", "我的iPhone", "我的 iPhone"], app: app)
            let folder = app.collectionViews["File View"].cells.matching(
                NSPredicate(format: "identifier IN %@", ["竹影, Container", "Zhuying, Container"])
            ).firstMatch
            if folder.waitForExistence(timeout: 5) { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
        tapAvailable(["Open", "打开"], app: app)

        let confirm = app.buttons["sourcePackageConfirm"]
        reveal(confirm, app: app)
        XCTAssertTrue(app.staticTexts["用户导入验证"].exists)
        confirm.tap()
        let message = app.staticTexts["sourcePackageMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("已保存 1 个书源"), message.label)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor func testReleaseStartsEmptyImportsExternalSourceAndDoesNotRestoreDeletedDefaults() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        openSources(app)
        assertSourceCount(0, app: app)
        capture(app, name: "Source-Free-Release-First-Launch")

        restartAndOpenSources(app)
        assertSourceCount(0, app: app)
        importExternalJSON(app)
        assertSourceCount(1, app: app)

        restartAndOpenSources(app)
        assertSourceCount(1, app: app)
        capture(app, name: "Source-Free-Release-User-Import-Persisted")

        app.buttons["sourceManage"].tap()
        app.buttons["sourceSelectAll"].tap()
        let delete = app.buttons["sourceBatchDelete"]
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        let confirmation = app.alerts.buttons["确认删除书源"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        app.buttons["sourceManageDone"].tap()
        assertSourceCount(0, app: app)

        restartAndOpenSources(app)
        assertSourceCount(0, app: app)
        capture(app, name: "Source-Free-Release-Deleted-Source-Stays-Deleted")
        app.terminate()
    }
}
