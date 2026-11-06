import XCTest

final class ReaderFlowTests: XCTestCase {
    @MainActor
    func testShelfPrimaryCategoriesAndSecondaryFilters() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let novel = app.buttons["shelf-category-novel"]
        XCTAssertTrue(novel.waitForExistence(timeout: 10))
        let title = app.descendants(matching: .any)["shelfTitle"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertLessThanOrEqual(title.frame.maxX + 8, novel.frame.minX, "The compact category switch belongs beside the shelf title")
        XCTAssertEqual(title.frame.midY, novel.frame.midY, accuracy: 5)
        var previous: XCUIElement?
        for id in ["novel", "comic", "audio"] {
            let tab = app.buttons["shelf-category-\(id)"]
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
            XCTAssertLessThanOrEqual(tab.frame.maxX, app.frame.maxX - 21)
            if let previous {
                XCTAssertLessThanOrEqual(previous.frame.maxX, tab.frame.minX)
                XCTAssertEqual(previous.frame.midY, tab.frame.midY, accuracy: 1)
            }
            previous = tab
        }
        XCTAssertTrue(novel.isSelected)
        let all = app.buttons["shelf-filter-0"]
        XCTAssertLessThan(novel.frame.maxY, all.frame.minY)
        XCTAssertTrue(app.buttons["continueReading"].exists)
        XCTAssertTrue(app.buttons["shelfUpdates"].exists)
        capture(app, name: "ShelfCompactSegments")
        reveal(all, in: app)
        XCTAssertTrue(all.label.contains("6"))
        app.buttons["shelf-filter-1"].tap()
        XCTAssertTrue(app.buttons["shelf-filter-1"].isSelected)

        for (id, title) in [("comic", "漫画"), ("audio", "听书")] {
            let tab = app.buttons["shelf-category-\(id)"]
            revealShelfCategories(in: app)
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            XCTAssertFalse(novel.isSelected)
            XCTAssertTrue(all.isSelected, "Changing categories resets the secondary filter")
            XCTAssertTrue(all.label.contains("0"))
            XCTAssertTrue(app.staticTexts["还没有收藏的\(title)"].exists)
            XCTAssertFalse(app.buttons["read-changfeng"].exists)
            XCTAssertFalse(app.buttons["continueReading"].exists, "Novel progress must not appear in another content category")
            XCTAssertFalse(app.buttons["shelfUpdates"].exists, "Novel updates must not appear in another content category")
            app.buttons["shelf-filter-1"].tap()
            XCTAssertTrue(app.staticTexts["还没有收藏的\(title)"].exists)
        }

        revealShelfCategories(in: app)
        novel.tap()
        XCTAssertTrue(novel.isSelected)
        XCTAssertTrue(all.isSelected)
        XCTAssertTrue(all.label.contains("6"))
        XCTAssertFalse(app.otherElements["shelfEmptyState"].exists)
        XCTAssertTrue(app.buttons["continueReading"].exists)
        XCTAssertTrue(app.buttons["shelfUpdates"].exists)
        reveal(app.buttons["shelfLayout"], in: app)
        app.buttons["shelfLayout"].tap()
        app.buttons["列表"].tap()
        XCTAssertTrue(app.buttons["list-read-changfeng"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ShelfPrimaryCategories"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testShelfCategoryChangeClearsManagedSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let manage = app.buttons["manageShelf"]
        reveal(manage, in: app)
        manage.tap()
        let book = app.buttons["select-changfeng"]
        reveal(book, in: app)
        book.tap()
        let remove = app.buttons["removeSelected"]
        XCTAssertTrue(remove.isEnabled)
        XCTAssertTrue(remove.label.contains("1"))

        revealShelfCategories(in: app)
        app.buttons["shelf-category-comic"].tap()
        XCTAssertTrue(app.buttons["shelf-category-comic"].isSelected)
        XCTAssertTrue(app.staticTexts["已选择 0 本"].exists)
        XCTAssertFalse(remove.isEnabled)
        XCTAssertTrue(app.staticTexts["还没有收藏的漫画"].exists)
        app.buttons["shelf-category-novel"].tap()
        XCTAssertTrue(app.staticTexts["已选择 0 本"].exists)
        XCTAssertFalse(remove.isEnabled, "Returning to novels must not restore a hidden selection")
        reveal(book, in: app)
        XCTAssertTrue(book.exists, "Changing categories must preserve saved novels")
        XCTAssertTrue(app.buttons["shelf-filter-0"].label.contains("6"))
    }

    @MainActor
    func testShelfCategoriesReflowBelowTitleAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let title = app.descendants(matching: .any)["shelfTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let novel = app.buttons["shelf-category-novel"]
        XCTAssertGreaterThanOrEqual(novel.frame.minY, title.frame.maxY + 8, "Accessibility text sizes move the category switch onto its own row")
        var previous: XCUIElement?
        for (id, label) in [("novel", "小说"), ("comic", "漫画"), ("audio", "听书")] {
            let tab = app.buttons["shelf-category-\(id)"]
            XCTAssertTrue(tab.isHittable)
            XCTAssertEqual(tab.label, label)
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
            XCTAssertGreaterThanOrEqual(tab.frame.minX, app.frame.minX + 21)
            XCTAssertLessThanOrEqual(tab.frame.maxX, app.frame.maxX - 21)
            if let previous { XCTAssertLessThanOrEqual(previous.frame.maxX, tab.frame.minX) }
            previous = tab
        }
        app.buttons["shelf-category-audio"].tap()
        XCTAssertTrue(app.buttons["shelf-category-audio"].isSelected)
        XCTAssertTrue(app.staticTexts["还没有收藏的听书"].exists)
        capture(app, name: "ShelfCompactSegmentsAccessibilitySize")
    }

    @MainActor
    func testShelfDensityGeometryDetailsAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let layout = app.buttons["shelfLayout"]
        reveal(layout, in: app)
        XCTAssertEqual(layout.value as? String, "三列 · 标准")
        // Hide the hero while managing so the entire first row is visible.
        app.buttons["manageShelf"].tap()
        for (title, count) in [("两列 · 大封面", 2), ("三列 · 标准", 3), ("四列 · 紧凑", 4)] {
            layout.tap(); app.buttons[title].tap()
            XCTAssertEqual(layout.value as? String, title)
            let books = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "select-"))
            XCTAssertGreaterThanOrEqual(books.count, count + 1)
            let first = books.element(boundBy: 0).frame
            for index in 1..<count {
                let frame = books.element(boundBy: index).frame
                XCTAssertEqual(frame.minY, first.minY, accuracy: 2)
                XCTAssertGreaterThan(frame.minX, books.element(boundBy: index - 1).frame.maxX)
                XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX - 21)
            }
            XCTAssertGreaterThan(books.element(boundBy: count).frame.minY, first.maxY)
            XCTAssertEqual(app.staticTexts["shelf-author-changfeng"].exists, count == 2)
            XCTAssertEqual(app.descendants(matching: .any)["shelf-progress-changfeng"].exists, count != 4)
            capture(app, name: "ShelfDensity-\(count)Columns")
        }
        app.buttons["select-changfeng"].tap()
        layout.tap(); app.buttons["列表"].tap()
        XCTAssertEqual(layout.value as? String, "列表")
        XCTAssertTrue(app.buttons["移出书架 (1)"].exists)
        app.buttons["manageShelf"].tap()
        XCTAssertTrue(app.buttons["list-read-changfeng"].exists)
        layout.tap(); app.buttons["四列 · 紧凑"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]
        app.launch()
        reveal(layout, in: app)
        XCTAssertEqual(layout.value as? String, "四列 · 紧凑")
        revealShelfCategories(in: app)
        app.buttons["shelf-category-comic"].tap()
        XCTAssertEqual(layout.value as? String, "四列 · 紧凑")
        app.buttons["shelf-category-novel"].tap()
        reveal(app.buttons["shelf-filter-2"], in: app)
        app.buttons["shelf-filter-2"].tap()
        XCTAssertEqual(layout.value as? String, "四列 · 紧凑")
    }

    @MainActor
    func testCompactShelfContextMenuAndReading() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let layout = app.buttons["shelfLayout"]
        reveal(layout, in: app)
        layout.tap(); app.buttons["四列 · 紧凑"].tap()
        let cover = app.buttons["read-changfeng"]
        reveal(cover, in: app)
        cover.press(forDuration: 1)
        app.buttons["选择多本"].tap()
        XCTAssertTrue(app.buttons["select-changfeng"].exists)
        XCTAssertTrue(app.buttons["移出书架 (1)"].exists)
        app.buttons["manageShelf"].tap()
        app.buttons["read-changfeng"].tap()
        acknowledgeFirstGuide(in: app)
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
    }

    @MainActor
    func testSpineShelfGeometryFilteringAndLayoutPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        chooseShelfLayout("书脊与封面", in: app)
        app.buttons["manageShelf"].tap()

        let expected: Set<String> = ["changfeng", "stars", "sunset", "mountains", "letter", "reunion"]
        assertShelfBooks(expected, managing: true, in: app)
        let cover = app.buttons["select-changfeng"]
        let spine = app.buttons["select-stars"]
        XCTAssertTrue(app.descendants(matching: .any)["shelf-spine-cover-changfeng"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["shelf-spine-stars"].firstMatch.exists)
        XCTAssertGreaterThan(cover.frame.width, spine.frame.width * 1.7, "The featured book faces forward and uses about two spine slots")
        XCTAssertEqual(cover.frame.maxY, spine.frame.maxY, accuracy: 2, "Books share a shelf baseline")
        var previous = cover
        for id in ["stars", "sunset", "mountains"] {
            let book = app.buttons["select-\(id)"]
            XCTAssertEqual(book.frame.maxY, cover.frame.maxY, accuracy: 2)
            XCTAssertGreaterThan(book.frame.minX, previous.frame.maxX)
            previous = book
        }
        XCTAssertGreaterThan(app.buttons["select-letter"].frame.minY, cover.frame.maxY)
        for id in expected {
            let book = app.buttons["select-\(id)"]
            XCTAssertGreaterThanOrEqual(book.frame.width, 44)
            XCTAssertGreaterThanOrEqual(book.frame.height, 44)
            XCTAssertGreaterThanOrEqual(book.frame.minX, app.frame.minX + 21)
            XCTAssertLessThanOrEqual(book.frame.maxX, app.frame.maxX - 21)
        }
        capture(app, name: "ShelfSpinesAndCover")

        app.buttons["shelf-filter-1"].tap()
        assertShelfBooks(["changfeng", "stars", "sunset"], managing: true, in: app)
        app.buttons["shelf-filter-2"].tap()
        assertShelfBooks(["mountains", "letter", "reunion"], managing: true, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shelf-spine-cover-mountains"].firstMatch.exists, "An unread-only shelf features its first visible book")
        XCTAssertFalse(app.descendants(matching: .any)["shelf-spine-cover-changfeng"].firstMatch.exists)
        app.buttons["shelf-filter-0"].tap()
        assertShelfBooks(expected, managing: true, in: app)

        let sorting = app.buttons["shelfSort"]
        sorting.tap(); app.buttons["加入时间"].tap()
        let ordered = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "select-")).allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(ordered, ["changfeng", "sunset", "stars", "mountains", "letter", "reunion"].map { "select-\($0)" }, "The forward-facing book must not reorder the selected shelf sort")
        revealShelfCategories(in: app)
        app.buttons["shelf-category-comic"].tap()
        XCTAssertTrue(app.staticTexts["还没有收藏的漫画"].exists)
        assertShelfBooks([], managing: true, in: app)
        app.buttons["shelf-category-novel"].tap()
        assertShelfBooks(expected, managing: true, in: app)

        app.terminate()
        app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]
        app.launch()
        let layout = app.buttons["shelfLayout"]
        reveal(layout, in: app)
        XCTAssertEqual(layout.value as? String, "书脊与封面")
        XCTAssertEqual(sorting.value as? String, "加入时间")
        app.buttons["manageShelf"].tap()
        assertShelfBooks(expected, managing: true, in: app)
    }

    @MainActor
    func testSpineShelfRemainsInsidePageAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        chooseShelfLayout("书脊与封面", in: app)
        app.buttons["manageShelf"].tap()

        let cover = app.buttons["select-changfeng"]
        let spine = app.buttons["select-stars"]
        reveal(spine, in: app)
        XCTAssertTrue(cover.exists)
        XCTAssertTrue(spine.isHittable)
        XCTAssertEqual(cover.frame.maxY, spine.frame.maxY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(spine.frame.width, 44)
        XCTAssertGreaterThan(spine.frame.minX, cover.frame.maxX)
        for book in [cover, spine] {
            XCTAssertGreaterThanOrEqual(book.frame.minX, app.frame.minX + 21)
            XCTAssertLessThanOrEqual(book.frame.maxX, app.frame.maxX - 21)
        }
        let nextRow = app.buttons["select-sunset"]
        reveal(nextRow, in: app)
        XCTAssertTrue(nextRow.exists)
        XCTAssertGreaterThan(nextRow.frame.minY, spine.frame.maxY, "Accessibility sizes reduce the first shelf to one cover and one spine")
        capture(app, name: "ShelfSpinesAccessibility")
    }

    @MainActor
    func testSpineShelfReadingRestoresProgressAndUpdatesFeaturedCover() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        chooseShelfLayout("书脊与封面", in: app)
        let stars = app.buttons["read-stars"]
        reveal(stars, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shelf-spine-stars"].firstMatch.exists)
        stars.tap()
        acknowledgeFirstGuide(in: app)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第二章 未来来信")
        app.buttons["nextChapter"].tap()
        let chapter = app.staticTexts["chapterTitle"].label
        XCTAssertTrue(chapter.hasPrefix("第三章"))
        app.buttons["返回书架"].tap()

        reveal(stars, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shelf-spine-cover-stars"].firstMatch.exists, "Reading a spine promotes that book to the forward-facing cover")
        XCTAssertFalse(app.descendants(matching: .any)["shelf-spine-cover-changfeng"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["shelf-spine-changfeng"].firstMatch.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "read-stars").count, 1, "Promoting the cover must not duplicate the book")
        capture(app, name: "ShelfSpinesRecentReading")
        stars.tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
        XCTAssertFalse(app.buttons["dismissGestureGuide"].exists)
    }

    @MainActor
    func testSpineShelfContextSelectionLayoutChangeAndRemovalUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        chooseShelfLayout("书脊与封面", in: app)
        let stars = app.buttons["read-stars"]
        reveal(stars, in: app)
        stars.press(forDuration: 1)
        app.buttons["选择多本"].tap()
        let remove = app.buttons["removeSelected"]
        XCTAssertTrue(remove.isEnabled)
        XCTAssertTrue(remove.label.contains("1"))

        chooseShelfLayout("两列 · 大封面", in: app)
        XCTAssertTrue(remove.label.contains("1"))
        chooseShelfLayout("书脊与封面", in: app)
        XCTAssertTrue(remove.label.contains("1"), "Changing layouts preserves the current managed selection")
        let changfeng = app.buttons["select-changfeng"]
        reveal(changfeng, in: app)
        changfeng.tap()
        XCTAssertTrue(remove.label.contains("2"))
        remove.tap()
        app.buttons["移出收藏，保留阅读进度"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["read-stars"].exists)
        XCTAssertFalse(app.buttons["read-changfeng"].exists)
        app.buttons["撤销"].tap()
        let manage = app.buttons["manageShelf"]
        revealShelfCategories(in: app)
        reveal(manage, in: app)
        manage.tap()
        assertShelfBooks(["changfeng", "stars", "sunset", "mountains", "letter", "reunion"], managing: true, in: app)
        XCTAssertFalse(remove.isEnabled)
        XCTAssertEqual(app.buttons["shelfLayout"].value as? String, "书脊与封面")
    }

    @MainActor private func preferenceCategory(_ id: String, in app: XCUIApplication) {
        let entry = app.buttons["reading-category-\(id)"]
        reveal(entry, in: app); entry.tap()
    }
    @MainActor private func preferenceHome(in app: XCUIApplication) {
        for _ in 0..<4 {
            if app.buttons["reading-category-layout"].exists { return }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    func testShelfReaderContentsAndPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let resume = app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        acknowledgeFirstGuide(in: app)
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["readerContents"].tap()
        let target = app.buttons["chapter-4"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(app.staticTexts["第五章 灯火入梦"].waitForExistence(timeout: 5))
        app.buttons["readerContents"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["第五章 灯火入梦"].waitForExistence(timeout: 5))
        app.buttons["readerSettings"].tap()
        capture(app, name: "UnifiedReadingPreferences")
        preferenceCategory("appearance", in: app)
        let dark = app.buttons["reading-paper-dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        reveal(dark, in: app)
        dark.tap()
        capture(app, name: "UnifiedReadingPreferencesNightSelection")
        preferenceHome(in: app)
        preferenceCategory("layout", in: app)
        app.buttons["reading-body"].tap()
        let font = app.sliders["fontPicker"]
        reveal(font, in: app); font.adjust(toNormalizedSliderPosition: 0.625)
        app.buttons["完成"].tap()
        assertFloatingToolbar(in: app)
        capture(app, name: "FloatingReaderToolbarDark")
        app.buttons["返回书架"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.staticTexts["第五章 灯火入梦"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSearchDetailFavoriteAndRead() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("云海")
        let result = app.buttons["result-cloud"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let add = app.buttons["加入书架"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["已在书架"].waitForExistence(timeout: 5))
        app.buttons["detailRead"].tap()
        acknowledgeFirstGuide(in: app)
        XCTAssertTrue(app.staticTexts["第一章 山脚少年"].waitForExistence(timeout: 5))
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["阅读云海问道"].waitForExistence(timeout: 5))
    }
    @MainActor
    private func acknowledgeFirstGuide(in app: XCUIApplication) {
        let start = app.buttons["dismissGestureGuide"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            if element.exists && element.frame.maxY < 170 { app.swipeDown() } else { app.swipeUp() }
        }
    }

    @MainActor
    private func revealShelfCategories(in app: XCUIApplication) {
        let novel = app.buttons["shelf-category-novel"]
        for _ in 0..<5 { if novel.isHittable { return }; app.swipeDown() }
        XCTAssertTrue(novel.isHittable)
    }

    @MainActor
    private func chooseShelfLayout(_ title: String, in app: XCUIApplication) {
        let layout = app.buttons["shelfLayout"]
        if !layout.isHittable {
            revealShelfCategories(in: app)
            reveal(layout, in: app)
        }
        layout.tap()
        let option = app.buttons[title]
        for _ in 0..<4 {
            if option.exists && option.isHittable { break }
            let menu = app.collectionViews.firstMatch
            guard menu.exists else { break }
            menu.swipeUp()
        }
        XCTAssertTrue(option.isHittable, "The native layout menu can scroll at accessibility text sizes")
        option.tap()
        XCTAssertEqual(layout.value as? String, title)
    }

    @MainActor
    private func assertShelfBooks(_ ids: Set<String>, managing: Bool, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let prefix = managing ? "select-" : "read-"
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let stableBooks = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            query.count == ids.count && ids.allSatisfy { app.buttons.matching(identifier: prefix + $0).count == 1 }
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [stableBooks], timeout: 5)
        XCTAssertEqual(outcome, .completed, "The shelf finishes filtering before its book list is inspected", file: file, line: line)
        guard outcome == .completed else { return }
        let books = query.allElementsBoundByIndex
        XCTAssertEqual(books.count, ids.count, "Every visible shelf book appears exactly once", file: file, line: line)
        XCTAssertEqual(Set(books.map { String($0.identifier.dropFirst(prefix.count)) }), ids, file: file, line: line)
    }

    @MainActor
    private func assertFloatingToolbar(in app: XCUIApplication) {
        let bar = app.otherElements["readerFloatingToolbar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(bar.frame.minX, app.frame.minX + 14)
        XCTAssertLessThanOrEqual(bar.frame.maxX, app.frame.maxX - 14)
        // The Demo reserves 8 pt below the toolbar plus the device safe area.
        // Home-button devices have a smaller safe area than Face ID devices.
        XCTAssertLessThanOrEqual(bar.frame.maxY, app.frame.maxY - 8)
        XCTAssertLessThanOrEqual(bar.frame.height, 80, "The primary toolbar should stay compact like the home tab bar")
        for id in ["readerContents", "readerSettings", "readerNarration", "readerSkins"] {
            XCTAssertTrue(bar.buttons[id].isHittable, "Bottom controls must remain accessible: \(id)")
        }
        XCTAssertFalse(bar.buttons["readerMoreTools"].exists)
        let more = app.otherElements["readerTopToolbar"].buttons["readerMoreTools"]
        XCTAssertTrue(more.isHittable)
        XCTAssertGreaterThan(more.frame.minX, app.frame.midX)
        XCTAssertLessThan(more.frame.maxY, app.frame.minY + app.frame.height * 0.25)
    }

    @MainActor
    private func assertReaderControlsHidden(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.otherElements["readerTopToolbar"].exists && !app.otherElements["readerFloatingToolbar"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "Tapping the text center hides both reading toolbars", file: file, line: line)
        XCTAssertFalse(app.otherElements["readerTopToolbar"].exists, file: file, line: line)
        XCTAssertFalse(app.otherElements["readerFloatingToolbar"].exists, file: file, line: line)
        XCTAssertFalse(app.sliders["chapterSlider"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["readerPageStatus"].exists, file: file, line: line)
        for id in ["readerMoreTools", "readerContents", "readerSettings", "readerNarration", "readerSkins", "previousChapter", "nextChapter", "showReaderControls"] {
            XCTAssertFalse(app.buttons[id].exists, "Hidden reading controls must leave no button behind: \(id)", file: file, line: line)
        }
        XCTAssertFalse(app.buttons["显示工具栏"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["显示工具栏"].exists, file: file, line: line)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = name
        preview.lifetime = .keepAlways
        add(preview)
    }

    @MainActor
    func testThemedPreferencesResetAndContentsSearchPreserveProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        let chapter = app.staticTexts["chapterTitle"].label
        app.buttons["readerSettings"].tap()
        preferenceCategory("operation", in: app)
        app.segmentedControls.buttons["左右翻页"].tap()
        preferenceHome(in: app)
        preferenceCategory("appearance", in: app)
        let dark = app.buttons["reading-paper-dark"]
        reveal(dark, in: app); dark.tap()
        preferenceHome(in: app)
        preferenceCategory("layout", in: app)
        app.buttons["reading-body"].tap()
        let font = app.sliders["fontPicker"]
        reveal(font, in: app); font.adjust(toNormalizedSliderPosition: 0.5)
        let preview = app.descendants(matching: .any)["readingStylePreview"].firstMatch
        XCTAssertTrue(preview.exists)
        capture(app, name: "UnifiedReadingStylePreview")
        preferenceHome(in: app)
        let reset = app.buttons["resetReadingSettings"]
        reveal(reset, in: app); reset.tap()
        app.alerts.buttons["恢复默认"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["continuousText"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)

        app.buttons["readerContents"].tap()
        XCTAssertTrue(app.buttons["chapter-2"].waitForExistence(timeout: 5))
        capture(app, name: "UnifiedChapterContents")
        // The system search field hides leading navigation actions while editing.
        app.buttons["正序"].tap()
        XCTAssertTrue(app.buttons["倒序"].exists)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("灯火")
        XCTAssertTrue(app.buttons["chapter-4"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chapter-2"].exists)
        app.buttons["chapter-4"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第五章 灯火入梦")
    }

    @MainActor
    func testReaderToolbarRoutesFavoriteNarrationAndSkins() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        assertFloatingToolbar(in: app)
        let chapter = app.staticTexts["chapterTitle"].label
        let progress = app.staticTexts["readerPageStatus"].label

        app.buttons["readerMoreTools"].tap()
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["系统朗读"].exists)
        XCTAssertFalse(app.buttons["段评与皮肤"].exists)
        capture(app, name: "ReaderMoreMenu")
        app.buttons["取消收藏"].tap()
        app.buttons["readerMoreTools"].tap()
        XCTAssertTrue(app.buttons["加入书架"].waitForExistence(timeout: 5))
        app.buttons["加入书架"].tap()
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, progress)

        for (entry, target, choices) in [
            ("readerNarration", "系统朗读", ["系统朗读", "在线朗读", "AI 多角色朗读"]),
            ("readerSkins", "段评与皮肤", ["主题管理", "段评与皮肤"])
        ] {
            app.buttons[entry].tap()
            for choice in choices { XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 5)) }
            app.buttons[target].tap()
            let nativeTitle = target == "段评与皮肤" ? "段评与神人评论" : target
            XCTAssertTrue(app.navigationBars[nativeTitle].waitForExistence(timeout: 5))
            app.navigationBars.buttons["完成"].tap()
            XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["chapterTitle"].label, chapter)
            XCTAssertEqual(app.staticTexts["readerPageStatus"].label, progress)
        }
    }

    @MainActor
    func testPagedReadingTapZonesSliderAndModeSwitch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        func waitForPage(_ page: Int) {
            let rendered = expectation(for: NSPredicate(format: "label CONTAINS %@", "本章 \(page) /"), evaluatedWith: app.staticTexts["readerPageStatus"])
            wait(for: [rendered], timeout: 5)
        }
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        app.buttons["readerSettings"].tap()
        preferenceCategory("operation", in: app)
        app.segmentedControls.buttons["左右翻页"].tap()
        let tapToggle = app.switches["tapToTurnToggle"]
        reveal(tapToggle, in: app)
        tapToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(tapToggle.value as? String, "1")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["readerPageStatus"].label.contains("本章 1 /"))
        XCTAssertTrue(app.buttons["readerTapCenter"].waitForExistence(timeout: 5))
        app.buttons["nextChapter"].tap()
        waitForPage(2)
        // Both edges advance; only the center controls the toolbar.
        app.buttons["readerTapLeft"].tap()
        let diagnostic = XCTAttachment(screenshot: app.screenshot()); diagnostic.name = "Reader-Paged-Selection-Compatible"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        waitForPage(3)
        // Do not assume a fixed page count: full-height text fits more per page.
        app.buttons["previousChapter"].tap()
        waitForPage(2)
        app.buttons["readerTapRight"].tap()
        waitForPage(3)
        app.buttons["readerTapCenter"].swipeRight()
        XCTAssertTrue(app.buttons["readerSettings"].isHittable, "A swipe must not also trigger the center tap and hide controls")
        waitForPage(2)
        app.buttons["readerTapCenter"].swipeLeft()
        waitForPage(3)
        let pageBeforeHiding = app.staticTexts["readerPageStatus"].label
        app.buttons["readerTapCenter"].tap()
        assertReaderControlsHidden(in: app)
        app.buttons["readerTapCenter"].tap()
        assertFloatingToolbar(in: app)
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, pageBeforeHiding, "Center taps toggle the controls without turning a page")
        let slider = app.sliders["chapterSlider"]
        slider.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertNotEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["readerSettings"].tap()
        preferenceCategory("operation", in: app)
        app.segmentedControls.buttons["上下滚动"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["continuousText"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["readerContents"].isHittable)
    }

    @MainActor
    func testScrollingReaderFillsScreenWithoutMovingWhenControlsToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        let text = app.textViews["continuousText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        assertFloatingToolbar(in: app)
        capture(app, name: "FloatingReaderToolbar")
        text.swipeUp()
        let frame = text.frame
        let progress = app.staticTexts["readerPageStatus"].label
        // UITextView.tap() can choose its top-left accessibility hit point,
        // which now sits under the overlaid back button. Tap the actual center.
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertReaderControlsHidden(in: app)
        XCTAssertGreaterThan(text.frame.height, app.frame.height * 0.82, "Hidden controls must not reserve space above or below the text")
        XCTAssertGreaterThan(text.frame.maxY, app.frame.maxY - 65, "The text viewport must reach the bottom safe area")
        XCTAssertEqual(text.frame, frame, "Toggling the overlay must not resize or reflow the text")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "ImmersiveScrollingReader"
        preview.lifetime = .keepAlways
        add(preview)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertFloatingToolbar(in: app)
        XCTAssertEqual(text.frame, frame)
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, progress)

        // Safe-area layout also fills the shorter viewport after rotation.
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let landscapeFrame = text.frame
        let landscapeProgress = app.staticTexts["readerPageStatus"].label
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertReaderControlsHidden(in: app)
        XCTAssertGreaterThan(text.frame.height, app.frame.height * 0.82)
        XCTAssertGreaterThan(text.frame.maxY, app.frame.maxY - 65)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["readerContents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["chapterSlider"].exists)
        XCTAssertEqual(text.frame, landscapeFrame)
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, landscapeProgress)
    }

    @MainActor
    func testPagedReaderFillsScreenAndKeepsPageWhenControlsToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        acknowledgeFirstGuide(in: app)
        app.buttons["readerSettings"].tap()
        preferenceCategory("operation", in: app)
        app.segmentedControls.buttons["左右翻页"].tap()
        app.buttons["完成"].tap()
        app.buttons["nextChapter"].tap()
        let page = app.staticTexts["readerPageStatus"].label
        let text = app.otherElements["readerTouchSurface"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let frame = text.frame
        app.buttons["readerTapCenter"].tap()
        assertReaderControlsHidden(in: app)
        XCTAssertGreaterThan(text.frame.height, app.frame.height * 0.78, "Pagination must use the full reading height")
        XCTAssertGreaterThan(text.frame.maxY, app.frame.maxY - 85)
        XCTAssertEqual(text.frame, frame)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "ImmersivePagedReader"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["readerTapCenter"].tap()
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, page, "Showing controls must preserve the current page and page count")
        XCTAssertEqual(text.frame, frame)
        assertFloatingToolbar(in: app)
    }

    @MainActor
    func testBatchShelfRemovalUndoAndSorting() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let manage = app.buttons["manageShelf"]
        reveal(manage, in: app)
        manage.tap()
        app.buttons["select-changfeng"].tap()
        app.buttons["select-stars"].tap()
        app.buttons["removeSelected"].tap()
        app.buttons["移出收藏，保留阅读进度"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 5))
        app.buttons["撤销"].tap()
        let sorting = app.buttons["shelfSort"]
        reveal(sorting, in: app)
        sorting.tap()
        app.buttons["加入时间"].tap()
        XCTAssertEqual(sorting.value as? String, "加入时间")
        app.buttons["manageShelf"].tap()
        XCTAssertTrue(app.buttons["select-changfeng"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["select-stars"].exists)
    }

    @MainActor
    func testHistoryFindsUnfavoritedBook() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("明日")
        app.buttons["result-echo"].tap()
        app.buttons["detailRead"].tap()
        acknowledgeFirstGuide(in: app)
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["我的"].tap()
        app.buttons["readingHistory"].tap()
        XCTAssertTrue(app.buttons["history-echo"].waitForExistence(timeout: 5))
        app.buttons["history-save-echo"].tap()
        XCTAssertFalse(app.buttons["history-save-echo"].exists)
        app.buttons["history-echo"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 记忆商店")
    }

    @MainActor
    func testSimulatedUpdatesResumeAndMarkRead() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["shelfUpdates"].tap()
        XCTAssertTrue(app.buttons["update-read-changfeng"].waitForExistence(timeout: 5))
        app.buttons["update-read-changfeng"].tap()
        acknowledgeFirstGuide(in: app)
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第十章 长夜将明")
        app.buttons["返回书架"].tap()
        app.buttons["shelfUpdates"].tap()
        XCTAssertTrue(app.staticTexts["更新 2 章"].waitForExistence(timeout: 5))
        let simulate = app.buttons["simulateUpdates"]
        reveal(simulate, in: app)
        simulate.tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["更新 3 章"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testFirstReadingGuideOnlyAppearsOnceAcrossBooksAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gestureGuideMode"].label, "当前模式 · 上下滚动")
        XCTAssertTrue(app.staticTexts["gestureGuideTapStatus"].label.contains("需在阅读设置中开启"))
        XCTAssertEqual(app.staticTexts["gestureGuideSwipe"].label, "上下滑动阅读 · 底部箭头切换章节")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "FirstReadingGestureGuide"
        preview.lifetime = .keepAlways
        add(preview)
        acknowledgeFirstGuide(in: app)
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["返回书架"].tap()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("群星")
        app.buttons["result-stars"].tap()
        app.buttons["detailRead"].tap()
        XCTAssertTrue(app.staticTexts["第二章 未来来信"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
        app.buttons["返回书架"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--preserve-ui-test-state"]
        app.launch()
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
    }

    @MainActor
    func testGuideCanBeReviewedFromSettingsWithoutChangingReadingPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["阅读偏好"].tap()
        preferenceCategory("operation", in: app)
        app.segmentedControls.buttons["左右翻页"].tap()
        let tapToggle = app.switches["tapToTurnToggle"]
        reveal(tapToggle, in: app)
        tapToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        reveal(app.buttons["readingGestureHelp"], in: app)
        app.buttons["readingGestureHelp"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gestureGuideMode"].label, "当前模式 · 左右翻页")
        XCTAssertEqual(app.staticTexts["gestureGuideSwipe"].label, "左滑下一页 · 右滑上一页")
        XCTAssertTrue(app.staticTexts["gestureGuideTapStatus"].label.contains("已开启轻触翻页"))
        XCTAssertEqual(app.buttons["dismissGestureGuide"].label, "知道了")
        app.buttons["dismissGestureGuide"].tap()
        app.buttons["完成"].tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["continueReading"].tap()
        // Reviewing help before the first read does not consume the first-use presentation.
        XCTAssertTrue(app.buttons["dismissGestureGuide"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["dismissGestureGuide"].label, "开始阅读")
        acknowledgeFirstGuide(in: app)
        app.buttons["nextChapter"].tap()
        let before = app.staticTexts["readerPageStatus"].label
        app.buttons["readerSettings"].tap()
        preferenceCategory("operation", in: app)
        reveal(app.buttons["readingGestureHelp"], in: app)
        reveal(app.buttons["readingGestureHelp"], in: app)
        app.buttons["readingGestureHelp"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        app.buttons["dismissGestureGuide"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["readerPageStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["readerPageStatus"].label, before)
        XCTAssertFalse(app.staticTexts["gestureGuideTitle"].exists)
    }

}
