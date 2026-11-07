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

private extension DiscoveryFlowTests {
    @MainActor func launchFilterDiscovery(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production", "--online-fixtures", "--discovery-fixtures", "--discovery-filter-fixtures"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["profileSettings"].tap()
        let settings = app.buttons["interfaceSettings"]; reveal(settings, app: app); settings.tap()
        let sourceSwitch = app.switches["nav-toggle-sources"]; reveal(sourceSwitch, app: app)
        sourceSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let sources = app.tabBars.buttons["书源"]; XCTAssertTrue(sources.waitForExistence(timeout: 5)); sources.tap()
        app.buttons["sourceMore"].tap(); app.buttons["sourcesDiscover"].tap()
        let mode = app.buttons["discoveryMode"]; XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.tap()
        app.buttons["discoveryRichMode"].tap()
        XCTAssertTrue(app.buttons["discoverySourcePicker"].waitForExistence(timeout: 8), app.debugDescription)
        return app
    }
    @MainActor func revealDiscoveryControl(_ element: XCUIElement, app: XCUIApplication) {
        // A scrolled-away SwiftUI button can report isHittable even when its
        // frame is under the status/search bars. Require a real 44pt tap area
        // inside the visible content before using its center.
        func viewport() -> CGRect {
            let screen = app.frame
            let navigationBars = app.navigationBars.allElementsBoundByIndex
            let foregroundBars = navigationBars.filter(\.isHittable)
            let bars = (foregroundBars.isEmpty ? Array(navigationBars.suffix(1)) : foregroundBars).map(\.frame)
                .filter { !$0.isEmpty && $0.intersects(screen) }
            let top = max(screen.minY + 44, (bars.map(\.maxY).max() ?? screen.minY) + 8)
            let tabs = app.tabBars.allElementsBoundByIndex.filter(\.isHittable).map(\.frame)
                .filter { !$0.isEmpty && $0.intersects(screen) }
            let bottom = min(screen.maxY - 24, (tabs.map(\.minY).min() ?? screen.maxY) - 8)
            return CGRect(x: screen.minX, y: top, width: screen.width, height: max(0, bottom - top))
        }
        func safelyHittable() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame, visible = viewport()
            let clearance = min(22, frame.height / 2)
            return !frame.isEmpty && frame.midY - clearance >= visible.minY && frame.midY + clearance <= visible.maxY
        }
        func shortVerticalDrag(upward: Bool) {
            let visible = viewport(), screen = app.frame
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            func point(_ fraction: CGFloat) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: visible.midX - screen.minX, dy: visible.minY + visible.height * fraction - screen.minY))
            }
            // Stay inside the content, move only 30% of its height and stop
            // while still touching it so a short screen cannot fling past a row.
            point(upward ? 0.65 : 0.35).press(forDuration: 0.05,
                thenDragTo: point(upward ? 0.35 : 0.65), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        var recentFrames: [String] = []
        // Only vertical gestures are used. Existing rows guide each step;
        // absent lazy rows get a bounded upward scan followed by a downward scan.
        for attempt in 0..<24 {
            if safelyHittable() { return }
            let visible = viewport()
            let frame = element.exists ? element.frame : .zero
            recentFrames.append("\(attempt): frame=\(frame), viewport=\(visible)")
            if recentFrames.count > 4 { recentFrames.removeFirst() }
            let upward: Bool
            if !frame.isEmpty {
                let clearance = min(22, frame.height / 2)
                if frame.midY - clearance < visible.minY { upward = false }
                else if frame.midY + clearance > visible.maxY { upward = true }
                else { upward = frame.midY >= visible.midY }
            } else { upward = attempt < 12 }
            shortVerticalDrag(upward: upward)
        }
        XCTAssertTrue(safelyHittable(), "Element frame: \(element.frame); safe viewport: \(viewport()); last steps: \(recentFrames)\n" + app.debugDescription)
    }
    @MainActor func assertDiscoveryControlFits(_ element: XCUIElement, app: XCUIApplication) {
        revealDiscoveryControl(element, app: app)
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX, element.debugDescription)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX, element.debugDescription)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, element.debugDescription)
    }
    @MainActor func chooseFilter(_ name: String, value: String, app: XCUIApplication) {
        let filter = app.buttons["discovery-filter-" + name]
        assertDiscoveryControlFits(filter, app: app)
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: filter)
        wait(for: [enabled], timeout: 8)
        filter.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), app.debugDescription)
        let option = app.buttons["discovery-option-" + value]
        assertDiscoveryControlFits(option, app: app)
        option.tap()
        let selected = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: filter)
        wait(for: [selected], timeout: 8)
        XCTAssertFalse(app.navigationBars[name].exists, "Selecting a value closes its options sheet")
    }
    @MainActor func filterResult(_ revision: Int, app: XCUIApplication) -> XCUIElement {
        let row = app.buttons["discovery-book-remote-discovery-filter-result-\(revision)"]
        revealDiscoveryControl(row, app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(row.label.contains("筛选结果 \(revision)"), row.label)
        return row
    }
    @MainActor func captureDiscovery(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}

extension DiscoveryFlowTests {
    @MainActor func testRichFiltersApplyAllSevenGroupsCancelWithoutChangesAndReachLastCategory() {
        let app = launchFilterDiscovery()
        let selected: [(String, String)] = [("线路", "备用线路"), ("模式", "听书模式"), ("频道", "女频"), ("平台", "女频精选"), ("字数", "百万字以上"), ("状态", "已完结"), ("排序", "最近更新")]
        for (index, item) in selected.enumerated() {
            chooseFilter(item.0, value: item.1, app: app)
            let row = filterResult(index + 1, app: app)
            XCTAssertTrue(row.label.contains(item.0 + "：" + item.1), row.label)
        }
        let finalSummary = filterResult(7, app: app).label
        for item in selected { XCTAssertTrue(finalSummary.contains(item.0 + "：" + item.1), finalSummary) }

        let line = app.buttons["discovery-filter-线路"]
        revealDiscoveryControl(line, app: app); line.tap()
        XCTAssertTrue(app.buttons["discovery-option-自动线路"].waitForExistence(timeout: 5))
        app.navigationBars["线路"].buttons["取消"].tap()
        XCTAssertEqual(line.value as? String, "备用线路")
        XCTAssertEqual(filterResult(7, app: app).label, finalSummary)
        XCTAssertFalse(app.buttons["discovery-book-remote-discovery-filter-result-8"].exists)

        // The platform choices depend on the channel, so stale selections must
        // reset and the next sheet must show only values for the new channel.
        chooseFilter("频道", value: "男频", app: app)
        let platform = app.buttons["discovery-filter-平台"]
        revealDiscoveryControl(platform, app: app)
        XCTAssertEqual(platform.value as? String, "全部平台")
        platform.tap()
        XCTAssertTrue(app.buttons["discovery-option-男频原创"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["discovery-option-女频精选"].exists)
        app.navigationBars["平台"].buttons["取消"].tap()
        XCTAssertTrue(filterResult(8, app: app).label.contains("平台：全部平台"))

        XCTAssertFalse(app.buttons["discovery-category-末项书单"].exists)
        let all = app.buttons["discoveryAllCategories"]
        revealDiscoveryControl(all, app: app); all.tap()
        XCTAssertTrue(app.navigationBars["全部分类"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["原创榜单"].exists)
        let last = app.buttons["discovery-category-末项书单"]
        assertDiscoveryControlFits(last, app: app); last.tap()
        XCTAssertFalse(app.navigationBars["全部分类"].exists)
        XCTAssertTrue(filterResult(8, app: app).label.contains("末项书单"))

        let toggle = app.buttons["discoveryFiltersToggle"]
        revealDiscoveryControl(toggle, app: app); toggle.tap()
        XCTAssertEqual(toggle.value as? String, "已收起")
        XCTAssertFalse(app.buttons["discovery-filter-线路"].exists)
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "已展开")
        assertDiscoveryControlFits(line, app: app)
        captureDiscovery(app, name: "竹影-丰富发现-七组筛选")
    }

    @MainActor func testRichFiltersAndOptionsFitAccessibilityTextWithVerticalOnlyNavigation() {
        let app = launchFilterDiscovery(largeText: true)
        for name in ["线路", "模式", "频道", "平台", "字数", "状态", "排序"] {
            assertDiscoveryControlFits(app.buttons["discovery-filter-" + name], app: app)
        }
        captureDiscovery(app, name: "竹影-丰富发现-辅助大字号-筛选")
        chooseFilter("字数", value: "百万字以上", app: app)
        XCTAssertTrue(filterResult(1, app: app).label.contains("字数：百万字以上"))
        let all = app.buttons["discoveryAllCategories"]
        revealDiscoveryControl(all, app: app); all.tap()
        let last = app.buttons["discovery-category-末项书单"]
        assertDiscoveryControlFits(last, app: app)
        captureDiscovery(app, name: "竹影-丰富发现-辅助大字号-全部分类")
        last.tap()
        XCTAssertTrue(filterResult(1, app: app).label.contains("末项书单"))
        let line = app.buttons["discovery-filter-线路"]
        revealDiscoveryControl(line, app: app); line.tap()
        assertDiscoveryControlFits(app.buttons["discovery-option-备用线路"], app: app)
        captureDiscovery(app, name: "竹影-丰富发现-辅助大字号-筛选选项")
        app.navigationBars["线路"].buttons["取消"].tap()
        XCTAssertEqual(line.value as? String, "自动线路")
    }
}
