import XCTest

final class FeatureFlowTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch(); return app
    }
    @MainActor private func openTools(in app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        if !app.navigationBars["全部工具"].exists {
            let tools = app.buttons["allTools"]
            reveal(tools, app: app); tools.tap()
        }
        XCTAssertTrue(app.navigationBars["全部工具"].waitForExistence(timeout: 5))
    }
    @MainActor private func open(_ id: String, title: String, app: XCUIApplication) {
        openTools(in: app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        if let old = search.value as? String, old != "搜索模块或功能" { search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        search.typeText(title)
        let route = app.buttons["feature-\(id)"]
        XCTAssertTrue(route.waitForExistence(timeout: 5), "Missing route: \(title)")
        route.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }

    @MainActor func testMagazineProfileLayoutAndDestinations() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["profileEditorialTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profileCurrentBook"].label, "长风渡山海")
        XCTAssertTrue(app.staticTexts["profileCurrentProgress"].label.contains("第3章"))
        XCTAssertFalse(app.staticTexts["常用工具"].exists)
        capture(app, name: "Profile-Magazine")
        let favorites = app.buttons["profileFavorites"]
        reveal(favorites, app: app); favorites.tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        app.tabBars.buttons["我的"].tap()
        let history = app.buttons["profileReadBooks"]
        reveal(history, app: app); history.tap()
        XCTAssertTrue(app.navigationBars["阅读历史"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let activity = app.buttons["profileActivity"]
        reveal(activity, app: app); activity.tap()
        XCTAssertTrue(app.segmentedControls["activityPeriod"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let settings = app.buttons["profileReadingSettings"]
        reveal(settings, app: app); settings.tap()
        XCTAssertTrue(app.segmentedControls["readingModePicker"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        for (id, title) in [("readingHistory", "阅读历史"), ("profile-tool-import", "智能导入"), ("profileThemes", "主题管理"), ("profileSources", "书源")] {
            let shortcut = app.buttons[id]
            reveal(shortcut, app: app); shortcut.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        openTools(in: app)
        XCTAssertTrue(app.buttons["tool-category-reading"].exists)
    }

    @MainActor func testMagazineProfileResumesActualReadingAndUpdatesChapter() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["profileContinueReading"].tap()
        XCTAssertTrue(app.buttons["dismissGestureGuide"].waitForExistence(timeout: 5))
        app.buttons["dismissGestureGuide"].tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第三章 山雨欲来")
        app.buttons["nextChapter"].tap()
        XCTAssertTrue(app.staticTexts["chapterTitle"].label.contains("第四章"))
        app.buttons["返回书架"].tap()
        XCTAssertTrue(app.staticTexts["profileCurrentProgress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["profileCurrentProgress"].label.contains("第4章"))
        let history = app.buttons["readingHistory"]
        reveal(history, app: app)
        XCTAssertTrue(history.isHittable)
        XCTAssertGreaterThanOrEqual(history.frame.minX, app.frame.minX + 20)
        XCTAssertLessThanOrEqual(app.buttons["profileReadingSettings"].frame.maxX, app.frame.maxX - 20)
        capture(app, name: "Profile-MagazineEntries")
    }

    @MainActor func testProfileSettingsHelpAndAbout() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["profileSettings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["阅读偏好"].tap()
        XCTAssertTrue(app.segmentedControls["readingModePicker"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["profileGestureHelp"].tap()
        XCTAssertTrue(app.staticTexts["gestureGuideTitle"].waitForExistence(timeout: 5))
        app.buttons["dismissGestureGuide"].tap()
        app.buttons["profileAbout"].tap()
        XCTAssertTrue(app.navigationBars["关于阅山"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["关于这个 Demo"].exists)
        capture(app, name: "Profile-About")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["阅读统计"].tap()
        XCTAssertTrue(app.navigationBars["阅读统计"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["iCloud 同步"].tap()
        XCTAssertTrue(app.navigationBars["iCloud"].waitForExistence(timeout: 5))
    }

    @MainActor func testToolsHomeShortcutsAndCategoryNavigation() {
        let app = launch()
        openTools(in: app)
        XCTAssertTrue(app.staticTexts["常用工具"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feature-shelf"].exists, "Home should not expand the full feature catalogue")
        capture(app, name: "Tools-CompactHome")
        for id in ["import", "fulltext", "cache", "backup", "systemTTS", "themes"] {
            let shortcut = app.buttons["tool-shortcut-\(id)"]
            reveal(shortcut, app: app); shortcut.tap()
            XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let routes = [("reading", "阅读", "contents"), ("files", "导入", "txt"),
                      ("audio", "朗读", "systemTTS"), ("style", "外观", "themes"),
                      ("data", "数据", "backup"), ("advanced", "高级", "sources")]
        for (id, title, featureID) in routes {
            let category = app.buttons["tool-category-\(id)"]
            reveal(category, app: app); category.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let feature = app.buttons["feature-\(featureID)"]
            reveal(feature, app: app)
            XCTAssertTrue(feature.isHittable)
            if id == "reading" { capture(app, name: "Tools-ReadingCategory") }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor func testToolsSearchEmptyResultsAndCategoryScope() {
        let app = launch()
        openTools(in: app)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("不存在的模块")
        XCTAssertTrue(app.staticTexts["没有找到相关功能"].waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        XCTAssertTrue(app.staticTexts["常用工具"].waitForExistence(timeout: 5))
        search.typeText("书源编辑")
        XCTAssertTrue(app.buttons["feature-sourceEdit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tool-shortcut-import"].exists)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        let reading = app.buttons["tool-category-reading"]
        reveal(reading, app: app); reading.tap()
        let categorySearch = app.textFields["toolCategorySearch"]
        categorySearch.tap(); categorySearch.typeText("书源编辑")
        XCTAssertTrue(app.staticTexts["没有找到相关功能"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feature-sourceEdit"].exists)
        categorySearch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        categorySearch.typeText("章节目录")
        XCTAssertTrue(app.buttons["feature-contents"].waitForExistence(timeout: 5))
        app.buttons["feature-contents"].tap()
        XCTAssertTrue(app.navigationBars["章节目录"].waitForExistence(timeout: 5))
    }

    @MainActor func testThemeLibraryImportPreviewFiltersAndDetails() {
        let app = launch()
        open("themes", title: "主题管理", app: app)
        XCTAssertTrue(app.staticTexts["当前使用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["themeImport"].exists)
        XCTAssertTrue(app.buttons["theme-filter-all"].exists)
        XCTAssertTrue(app.buttons["theme-card-paper"].exists)
        XCTAssertTrue(app.buttons["theme-card-night"].exists)
        capture(app, name: "Themes-Library")
        app.buttons["themeImport"].tap()
        XCTAssertTrue(app.staticTexts["已扫描 4 个主题：新增 2 个 · 重复 1 个 · 无效 1 个"].waitForExistence(timeout: 5))
        app.buttons["知道了"].tap()
        app.buttons["theme-filter-dark"].tap()
        XCTAssertTrue(app.buttons["theme-card-night"].exists)
        XCTAssertFalse(app.buttons["theme-card-white"].exists)
        app.buttons["theme-card-night"].tap()
        XCTAssertTrue(app.navigationBars["主题预览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["themeApply"].exists)
        app.buttons["themeFavorite"].tap()
        app.buttons["themeApply"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["夜读深林"].exists)
        app.buttons["theme-filter-all"].tap()
        app.buttons["themeManage"].tap()
        XCTAssertTrue(app.buttons["theme-card-paper"].exists)
        app.buttons["theme-card-mist"].tap()
        XCTAssertTrue(app.buttons["删除"].exists)
        app.buttons["删除"].tap()
        XCTAssertFalse(app.buttons["theme-card-mist"].exists)
    }

    @MainActor func testEveryFeaturePageIsReachable() {
        let app = launch()
        let routes = [
            ("shelf","书架管理"), ("search","书籍搜索"), ("fulltext","全文搜索"), ("discover","发现与订阅"), ("details","书籍详情"), ("sourceSwitch","换源"), ("contents","章节目录"), ("progress","阅读进度"), ("bookmarks","书签"), ("reading","正文阅读"), ("pageStyle","翻页方式"), ("typography","阅读排版"), ("chapterCache","章节缓存"),
            ("txt","TXT 阅读"), ("epub","EPUB 阅读"), ("pdf","PDF 阅读"), ("comic","漫画阅读"), ("archive","压缩包支持"), ("import","智能导入"),
            ("sources","书源管理"), ("sourceImport","书源导入导出"), ("sourceEdit","书源编辑"), ("sourceLogin","书源登录"), ("sourceDebug","书源调试"), ("sourceBatch","批量测试"), ("engine","书源兼容引擎"),
            ("systemTTS","系统朗读"), ("onlineTTS","在线朗读"), ("backgroundAudio","后台音频"), ("aiRoles","AI 多角色朗读"), ("aiConfig","AI 服务配置"), ("purify","正文净化"), ("highlight","高亮规则"), ("themes","主题管理"), ("fonts","字体管理"), ("titleDesign","章节标题设计"), ("comments","段评与皮肤"),
            ("backup","本地备份"), ("icloud","iCloud"), ("statistics","阅读统计"), ("files","文件管理"), ("cache","缓存管理"), ("browser","内置浏览器"), ("covers","封面搜索"), ("network","网络配置"), ("backend","远程后端"), ("links","外部链接接入")
        ]
        for (id, title) in routes {
            open(id, title: title, app: app)
            if ["typography", "titleDesign", "aiRoles"].contains(id) { capture(app, name: "Catalog-\(id)") }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor func testFulltextJumpAndChangeSourceInsideReader() {
        let app = launch()
        open("fulltext", title: "全文搜索", app: app)
        let hit = app.buttons["hit-changfeng:0:0"]
        reveal(hit, app: app); hit.tap()
        let guide = app.buttons["dismissGestureGuide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5)); guide.tap()
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 旧巷听风")
        app.buttons["readerMoreTools"].tap()
        app.buttons["换源"].tap()
        let alternate = app.buttons["candidate-yunjian"]
        XCTAssertTrue(alternate.waitForExistence(timeout: 5)); alternate.tap()
        XCTAssertEqual(alternate.value as? String, "当前来源")
        let resume = app.buttons["使用所选来源继续阅读"]
        reveal(resume, app: app); resume.tap()
        XCTAssertTrue(app.buttons["readerMoreTools"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chapterTitle"].label, "第一章 旧巷听风")
    }

    @MainActor func testSourceSwipeLoginAndDetailFallback() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["profileSources"]
        reveal(entry, app: app); entry.tap()
        let row = app.buttons["source-row-shanhai"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        XCTAssertFalse(app.buttons["删除书源"].exists)
        capture(app, name: "Source-SwipeActions")
        app.buttons["source-login-shanhai"].tap()
        XCTAssertEqual(app.staticTexts["currentSourceName"].label, "当前书源：山海书库")
        let login = app.buttons["demo-action-sourceLogin-模拟登录"]
        reveal(login, app: app); login.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.label.contains("已登录"))
        row.tap()
        XCTAssertTrue(app.navigationBars["书源详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sourceLoginStatus"].label.contains("已登录"))
        app.buttons["sourceDetailLogin"].tap()
        XCTAssertEqual(app.staticTexts["currentSourceName"].label, "当前书源：山海书库")
        let clear = app.buttons["demo-action-sourceLogin-清除演示 Cookie"]
        reveal(clear, app: app); clear.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["sourceLoginStatus"].label.contains("未登录"))
    }

    @MainActor func testSourceLongPressScopeToggleAndConfirmedRemoval() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["profileSources"]
        reveal(entry, app: app); entry.tap()
        let row = app.buttons["source-row-yunjian"]
        reveal(row, app: app); row.press(forDuration: 1)
        app.buttons["重新登录"].tap()
        XCTAssertEqual(app.staticTexts["currentSourceName"].label, "当前书源：云间小说")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        row.press(forDuration: 1); app.buttons["停用书源"].tap()
        XCTAssertTrue(row.label.contains("已停用"))
        row.press(forDuration: 1); app.buttons["删除书源"].tap()
        app.buttons["取消"].tap()
        XCTAssertTrue(row.exists)
        row.press(forDuration: 1); app.buttons["删除书源"].tap()
        app.buttons["确认删除书源"].tap()
        XCTAssertFalse(row.exists)
        XCTAssertTrue(app.buttons["source-row-shanhai"].exists)
    }

    @MainActor func testSourceEditingAndBatchReport() {
        let app = launch()
        app.tabBars.buttons["我的"].tap()
        let sources = app.buttons["profileSources"]
        reveal(sources, app: app); sources.tap()
        capture(app, name: "Catalog-Sources")
        let row = app.buttons["source-row-shanhai"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        app.buttons["source-edit-shanhai"].tap()
        let validate = app.buttons["demo-action-sourceEdit-校验 JSON"]
        reveal(validate, app: app); validate.tap()
        XCTAssertTrue(app.staticTexts["JSON 格式正确。这里只校验语法，不执行书源规则。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("sourceBatch", title: "批量测试", app: app)
        let run = app.buttons["demo-action-sourceBatch-生成演示报告"]
        reveal(run, app: app); run.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "成功 2 个")).firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Catalog-TestReport")
    }

    @MainActor func testMockImportAndPlayerFlow() {
        let app = launch()
        open("import", title: "智能导入", app: app)
        let recognize = app.buttons["demo-action-import-识别内容"]
        reveal(recognize, app: app); recognize.tap()
        let confirm = app.buttons["demo-action-import-确认模拟导入"]
        reveal(confirm, app: app); confirm.tap()
        XCTAssertTrue(app.staticTexts["新导入的故事.epub"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("systemTTS", title: "系统朗读", app: app)
        let play = app.buttons["demoPlayerToggle"]
        reveal(play, app: app); play.tap()
        XCTAssertEqual(play.label, "暂停演示朗读")
        capture(app, name: "Catalog-Player")
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["切换演示朗读"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["我的"].isHittable)
        capture(app, name: "Catalog-MiniPlayer")
    }

    @MainActor func testToolsHomeAndSampleFilePreview() {
        let app = launch()
        openTools(in: app)
        XCTAssertTrue(app.staticTexts["把阅读，调成你的样子。"].waitForExistence(timeout: 5))
        capture(app, name: "Catalog-ToolsHome")
        open("pdf", title: "PDF 阅读", app: app)
        let preview = app.buttons["demo-action-pdf-打开示例 PDF"]
        reveal(preview, app: app); preview.tap()
        XCTAssertTrue(app.navigationBars["山海图志.pdf"].waitForExistence(timeout: 5))
        let page = app.sliders.firstMatch
        page.adjust(toNormalizedSliderPosition: 0.65)
        XCTAssertFalse(app.staticTexts["1 / 12 · 模拟文件内容，无真实解析"].exists)
        capture(app, name: "Catalog-FilePreview")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["PDF 阅读"].waitForExistence(timeout: 5))
    }
}
