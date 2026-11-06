import XCTest

final class DiscoveryFlowTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--production", "--online-fixtures", "--discovery-fixtures"]; app.launch(); return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor func testPreciseSearchToggleFiltersIrrelevantBooksAndDetailHasRefresh() {
        let app = launch(); app.tabBars.buttons["搜索"].tap()
        let field = app.searchFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("精准测试\n")
        let exact = app.switches["exactSearchToggle"]; XCTAssertTrue(exact.waitForExistence(timeout: 5))
        if exact.value as? String == "1" { exact.tap() }
        let unrelated = app.buttons["online-result-remote-precision-1"]
        XCTAssertTrue(unrelated.waitForExistence(timeout: 10))
        exact.tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: unrelated); wait(for: [removed], timeout: 8)
        let match = app.buttons["online-result-remote-precision-0"]; XCTAssertTrue(match.waitForExistence(timeout: 8)); match.tap()
        let refresh = app.buttons["refreshBookDetail"]; XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: refresh); wait(for: [ready], timeout: 10)
        XCTAssertEqual(refresh.label, "刷新作品详情"); refresh.tap()
        XCTAssertTrue(app.buttons["detailRead"].exists)
        XCTAssertFalse(app.navigationBars.buttons["加入书架"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if exact.value as? String == "1" { exact.tap() }
    }
    @MainActor func testSourceTabOpensRichDiscoverySwitchesCategoriesAndKeepsSimpleMode() {
        let app = launch(); app.tabBars.buttons["我的"].tap()
        app.buttons["profileSettings"].tap()
        let settings = app.buttons["interfaceSettings"]; reveal(settings, app: app); settings.tap()
        let sourceSwitch = app.switches["nav-toggle-sources"]; reveal(sourceSwitch, app: app)
        sourceSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let sources = app.tabBars.buttons["书源"]; XCTAssertTrue(sources.waitForExistence(timeout: 5)); sources.tap()
        app.buttons["sourceMore"].tap()
        let discovery = app.buttons["sourcesDiscover"]; XCTAssertTrue(discovery.waitForExistence(timeout: 5)); discovery.tap()
        let mode = app.buttons["discoveryMode"]; XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.tap()
        app.buttons["discoveryRichMode"].tap()
        XCTAssertTrue(app.buttons["discoverySourcePicker"].waitForExistence(timeout: 8), app.debugDescription)
        let rank = app.buttons["discovery-category-排行榜"]; XCTAssertTrue(rank.waitForExistence(timeout: 10), app.debugDescription)
        let book = app.buttons["discovery-book-remote-ui-fixture-1"]; XCTAssertTrue(book.waitForExistence(timeout: 10))
        let all = app.buttons["discovery-category-全部"]; all.tap(); XCTAssertTrue(book.waitForExistence(timeout: 8))
        let refresh = app.buttons["refreshDiscovery"]; reveal(refresh, app: app); refresh.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["discoverySourceLogin"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Zhuying-Rich-Discovery"; image.lifetime = .keepAlways; add(image)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["sourceMore"].tap(); app.buttons["sourcesDiscover"].tap()
        XCTAssertTrue(app.buttons["discoverySourcePicker"].waitForExistence(timeout: 8), app.debugDescription)
        mode.tap(); app.buttons["discoverySimpleMode"].tap()
        XCTAssertTrue(app.buttons["discoverMultiSearch"].waitForExistence(timeout: 5))
    }
}
