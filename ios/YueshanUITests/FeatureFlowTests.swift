import XCTest

final class FeatureFlowTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch(); return app
    }
    @MainActor private func open(_ id: String, title: String, app: XCUIApplication) {
        app.tabBars.buttons["工具"].tap()
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

    @MainActor func testSourceEditingAndBatchReport() {
        let app = launch()
        app.tabBars.buttons["书源"].tap()
        capture(app, name: "Catalog-Sources")
        let edit = app.buttons["编辑"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
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
        XCTAssertTrue(app.tabBars.buttons["工具"].isHittable)
        capture(app, name: "Catalog-MiniPlayer")
    }

    @MainActor func testToolsHomeAndSampleFilePreview() {
        let app = launch()
        app.tabBars.buttons["工具"].tap()
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
