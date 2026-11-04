import XCTest

final class NavigationFlowTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch(); return app
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func settings(_ app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        if app.navigationBars["底部导航"].exists { return }
        let entry = app.buttons["interfaceSettings"]
        reveal(entry, in: app); entry.tap()
        XCTAssertTrue(app.navigationBars["底部导航"].waitForExistence(timeout: 5))
    }
    @MainActor private func toggle(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor
    func testDefaultNavigationHeatmapAndReadingFromToday() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["足迹"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        XCTAssertFalse(app.tabBars.buttons["发现"].exists)
        XCTAssertFalse(app.tabBars.buttons["书源"].exists)
        capture(app, "NavigationDefault")
        app.tabBars.buttons["足迹"].tap()
        XCTAssertTrue(app.staticTexts["阅读热力图"].waitForExistence(timeout: 5))
        let before = app.staticTexts["selectedActivityDate"].label
        capture(app, "ReadingFootprints")
        app.buttons["activity-day-0"].tap()
        XCTAssertNotEqual(app.staticTexts["selectedActivityDate"].label, before)
        app.buttons["activityToday"].tap()
        XCTAssertEqual(app.staticTexts["selectedActivityDate"].label, before)
        let book = app.buttons["activity-book-changfeng"]
        reveal(book, in: app); book.tap()
        let guide = app.buttons["dismissGestureGuide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5)); guide.tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
    }
    @MainActor
    func testNavigationCustomizationLimitOrderingPersistenceAndReset() {
        let app = launch()
        settings(app)
        capture(app, "NavigationSettings")
        toggle(app.switches["nav-toggle-footprints"], in: app)
        toggle(app.switches["nav-toggle-discover"], in: app)
        toggle(app.switches["nav-toggle-sources"], in: app)
        XCTAssertFalse(app.switches["nav-toggle-tools"].isEnabled)
        let move = app.buttons["nav-move-sources-up"]
        reveal(move, in: app); move.tap()
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["书架", "书源", "发现", "我的", "搜索"])
        toggle(app.switches["navAutoCollapse"], in: app)
        XCTAssertEqual(app.switches["navAutoCollapse"].value as? String, "1")
        capture(app, "NavigationAutoCollapseSetting")
        app.terminate()
        app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["书架", "书源", "发现", "我的", "搜索"])
        settings(app)
        let reset = app.buttons["resetNavigation"]
        reveal(reset, in: app); reset.tap()
        XCTAssertTrue(app.tabBars.buttons["足迹"].isHittable)
        XCTAssertFalse(app.tabBars.buttons["书源"].exists)
        XCTAssertEqual(app.switches["navAutoCollapse"].value as? String, "0")
    }
    @MainActor
    func testAutomaticCollapseKeepsSearchAndFixedModeStaysExpanded() {
        let app = launch()
        settings(app)
        toggle(app.switches["navAutoCollapse"], in: app)
        app.tabBars.buttons["书架"].tap()
        app.swipeUp()
        let footprints = app.tabBars.buttons["足迹"]
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: footprints)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        XCTAssertTrue(app.tabBars.buttons["搜索"].isHittable)
        capture(app, "NavigationCollapsed")
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(footprints.isHittable, "Tapping the current tab capsule should expand navigation")
        app.swipeUp()
        app.swipeDown()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: footprints)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        settings(app)
        toggle(app.switches["navAutoCollapse"], in: app)
        app.tabBars.buttons["书架"].tap()
        app.swipeUp()
        XCTAssertTrue(footprints.isHittable)
        XCTAssertTrue(app.tabBars.buttons["搜索"].isHittable)
    }
}
