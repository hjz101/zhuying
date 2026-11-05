import XCTest
@testable import Yueshan

@MainActor
final class FeatureDemoTests: XCTestCase {
    private var library: LibraryStore!
    private var demo: FeatureDemoStore!
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        domain = "com.yueshan.catalog-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        library = LibraryStore(books: try Book.load(bundle: Bundle(for: LibraryStore.self)), defaults: defaults)
        demo = FeatureDemoStore()
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testCatalogueCoversUserListAndAllLinksResolve() {
        let expected: Set<String> = ["shelf", "search", "fulltext", "discover", "details", "sourceSwitch", "contents", "progress", "bookmarks", "reading", "pageStyle", "typography", "chapterCache", "txt", "epub", "pdf", "comic", "archive", "import", "sources", "sourceImport", "sourceEdit", "sourceLogin", "sourceDebug", "sourceBatch", "engine", "systemTTS", "onlineTTS", "backgroundAudio", "aiRoles", "aiConfig", "purify", "highlight", "themes", "fonts", "titleDesign", "comments", "backup", "icloud", "statistics", "files", "cache", "browser", "covers", "network", "backend", "links"]
        XCTAssertEqual(Set(FeatureCatalog.all.map(\.id)), expected)
        XCTAssertEqual(FeatureCatalog.all.count, expected.count)
        for feature in FeatureCatalog.all {
            XCTAssertFalse(feature.title.isEmpty)
            XCTAssertFalse(feature.summary.isEmpty)
            XCTAssertEqual(Set(feature.fields.map(\.id)).count, feature.fields.count)
            for id in feature.related { XCTAssertTrue(expected.contains(id), "Broken related feature: \(id)") }
        }
        XCTAssertTrue(Set(FeatureCatalog.search("JavaScript").map(\.id)).isSuperset(of: ["engine", "purify", "sourceEdit"]))
        XCTAssertTrue(FeatureCatalog.search("不存在的模块").isEmpty)
    }

    func testToolCategoriesCoverEveryFeatureExactlyOnce() {
        let ids = ToolCategory.allCases.flatMap { $0.features.map(\.id) }
        XCTAssertEqual(ToolCategory.allCases.count, 6)
        XCTAssertEqual(ids.count, FeatureCatalog.all.count)
        XCTAssertEqual(Set(ids), Set(FeatureCatalog.all.map(\.id)))
        for category in ToolCategory.allCases {
            XCTAssertFalse(category.features.isEmpty)
            XCTAssertEqual(category.search("   ").map(\.id), category.features.map(\.id))
        }
        XCTAssertEqual(ToolCategory.data.search("备份").map(\.id), ["backup", "icloud"])
        XCTAssertTrue(ToolCategory.reading.search("书源编辑").isEmpty)
        XCTAssertEqual(ToolCategory.advanced.search("书源编辑").map(\.id), ["sourceEdit"])
    }

    func testCommonToolsAreUniqueAndSearchStillCoversAllCategories() {
        let common = FeatureCatalog.commonTools
        XCTAssertEqual(common.count, 6)
        XCTAssertEqual(Set(common.map(\.id)).count, common.count)
        XCTAssertEqual(common.map(\.id), ["import", "fulltext", "cache", "backup", "systemTTS", "themes"])
        for feature in FeatureCatalog.all {
            XCTAssertTrue(FeatureCatalog.search(feature.title).contains { $0.id == feature.id })
        }
        XCTAssertTrue(FeatureCatalog.search("不存在的模块").isEmpty)
    }

    func testSourceLoginStatusAndEditorStayScopedToSelectedSource() {
        let login = FeatureCatalog.feature("sourceLogin")
        let edit = FeatureCatalog.feature("sourceEdit")
        demo.prepareSource(edit, scope: "yunjian")
        XCTAssertEqual(demo.text(edit, "name", scope: "yunjian"), "云间小说")
        XCTAssertEqual(demo.text(edit, "url", scope: "yunjian"), "https://yunjian.example")
        demo.set("自定义名称", feature: edit, field: edit.fields.first { $0.id == "name" }!, scope: "yunjian")
        demo.prepareSource(edit, scope: "yunjian")
        XCTAssertEqual(demo.text(edit, "name", scope: "yunjian"), "自定义名称")
        demo.execute("模拟登录", feature: login, scope: "shanhai", book: nil, library: library)
        XCTAssertEqual(demo.sources[0].loginStatus, .signedIn)
        XCTAssertEqual(demo.sources[1].loginStatus, .expired)
        demo.execute("清除演示 Cookie", feature: login, scope: "shanhai", book: nil, library: library)
        XCTAssertEqual(demo.sources[0].loginStatus, .signedOut)
        demo.execute("保存演示配置", feature: edit, scope: "yunjian", book: nil, library: library)
        XCTAssertEqual(demo.sources[1].name, "自定义名称")
        XCTAssertEqual(demo.sources[0].name, "山海书库")
        demo.setSourceLogin("unknown", status: .signedIn)
        XCTAssertEqual(demo.sources.count, 3)
    }

    func testRemovingSourceClearsOnlyItsDemoStateAndKeepsReadingData() {
        let before = library.progress
        let favorites = library.favorites
        let edit = FeatureCatalog.feature("sourceEdit")
        demo.prepareSource(edit, scope: "shanhai")
        demo.prepareSource(edit, scope: "yunjian")
        demo.bookSources = ["changfeng": "shanhai", "stars": "yunjian"]
        demo.removeSource("shanhai")
        XCTAssertFalse(demo.sources.contains { $0.id == "shanhai" })
        XCTAssertNil(demo.bookSources["changfeng"])
        XCTAssertEqual(demo.bookSources["stars"], "yunjian")
        XCTAssertFalse(demo.values.keys.contains { $0.contains(":shanhai:") })
        XCTAssertEqual(demo.text(edit, "name", scope: "yunjian"), "云间小说")
        XCTAssertEqual(library.progress, before)
        XCTAssertEqual(library.favorites, favorites)
    }

    func testThemeLibraryImportDeduplicatesAndKeepsActiveTheme() {
        XCTAssertEqual(demo.themes.count, 8)
        XCTAssertEqual(demo.activeThemeID, "paper")
        let first = demo.importDemoThemes()
        XCTAssertEqual(first, ThemeImportResult(added: 2, duplicates: 1, invalid: 1))
        XCTAssertEqual(demo.themes.count, 10)
        XCTAssertEqual(demo.themes.filter { $0.id == "mist" }.count, 1)
        XCTAssertEqual(demo.activeThemeID, "paper")
        let second = demo.importDemoThemes()
        XCTAssertEqual(second, ThemeImportResult(added: 0, duplicates: 3, invalid: 1))
        XCTAssertEqual(demo.themes.count, 10)
    }

    func testThemeActionsAreScopedAndCannotDeleteActiveTheme() {
        demo.toggleThemeFavorite("white")
        XCTAssertTrue(demo.themes.first { $0.id == "white" }!.favorite)
        demo.applyTheme("night")
        demo.removeThemes(["night", "white"])
        XCTAssertTrue(demo.themes.contains { $0.id == "night" })
        XCTAssertFalse(demo.themes.contains { $0.id == "white" })
        demo.applyTheme("unknown")
        XCTAssertEqual(demo.activeThemeID, "night")
    }

    func testFieldsAreScopedToFeatureAndSource() {
        let feature = FeatureCatalog.feature("sourceEdit")
        let field = feature.fields.first { $0.id == "name" }!
        demo.set("测试书源", feature: feature, field: field, scope: "shanhai")
        XCTAssertEqual(demo.value(feature, field, scope: "shanhai"), "测试书源")
        XCTAssertEqual(demo.value(feature, field, scope: "yunjian"), field.initial)
        demo.reset(feature, scope: "shanhai")
        XCTAssertEqual(demo.value(feature, field, scope: "shanhai"), field.initial)
    }

    func testJSONValidationSuccessAndFailureWithoutRuleExecution() {
        let feature = FeatureCatalog.feature("sourceEdit")
        demo.execute("校验 JSON", feature: feature, scope: "main", book: nil, library: library)
        XCTAssertEqual(demo.outcomes["sourceEdit:main"]?.success, true)
        demo.set("{invalid}", feature: feature, field: feature.fields.first { $0.id == "json" }!)
        demo.execute("校验 JSON", feature: feature, scope: "main", book: nil, library: library)
        XCTAssertEqual(demo.outcomes["sourceEdit:main"]?.success, false)
    }

    func testSourceSwitchRetainsProgressAndRejectsDisabledSource() {
        let book = library.books[0]
        library.record(book, chapter: 4, paragraph: 3, characterOffset: 7)
        let before = library.progress[book.id]
        demo.switchSource("yunjian", book: book)
        XCTAssertEqual(demo.bookSources[book.id], "yunjian")
        XCTAssertEqual(library.progress[book.id], before)
        demo.sources[0].enabled = false
        demo.switchSource("shanhai", book: book)
        XCTAssertEqual(demo.bookSources[book.id], "yunjian")
    }

    func testFulltextHitsHaveValidRestorablePositions() {
        let hits = demo.fulltext("地图", books: library.books)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(demo.fulltext("   ", books: library.books).isEmpty)
        for hit in hits {
            let book = library.books.first { $0.id == hit.bookID }!
            XCTAssertEqual(book.content[hit.chapter][hit.paragraph], hit.text)
            XCTAssertEqual((hit.text as NSString).substring(with: NSRange(location: hit.offset, length: 2)), "地图")
            XCTAssertTrue(library.record(book, chapter: hit.chapter, paragraph: hit.paragraph, characterOffset: hit.offset))
        }
    }

    func testBookmarksDeduplicateAndCapturePosition() {
        let book = library.books[1]
        library.record(book, chapter: 3, paragraph: 4, characterOffset: 5)
        demo.addBookmark(book: book, progress: library.progress[book.id])
        demo.addBookmark(book: book, progress: library.progress[book.id])
        let marks = demo.bookmarks.filter { $0.bookID == book.id }
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].chapter, 3)
        XCTAssertEqual(marks[0].offset, 5)
    }

    func testMockImportCacheAndBackupLeaveActualReadingDataIntact() {
        let before = library.progress
        let favorites = library.favorites
        demo.execute("清理演示缓存", feature: FeatureCatalog.feature("cache"), scope: "main", book: nil, library: library)
        XCTAssertTrue(demo.cacheMB.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(library.progress, before)
        XCTAssertEqual(library.favorites, favorites)
        let count = demo.backups.count
        demo.execute("创建演示备份", feature: FeatureCatalog.feature("backup"), scope: "main", book: nil, library: library)
        XCTAssertEqual(demo.backups.count, count + 1)
        demo.execute("确认模拟导入", feature: FeatureCatalog.feature("import"), scope: "main", book: nil, library: library)
        XCTAssertTrue(library.favorites.contains("cloud"))
        XCTAssertEqual(library.progress, before)
        XCTAssertEqual(demo.files.first?.name, "新导入的故事.epub")
    }

    func testGroupCreationAndSourceManagement() {
        let feature = FeatureCatalog.feature("shelf")
        let name = feature.fields.first { $0.id == "newGroup" }!
        demo.set("睡前", feature: feature, field: name)
        demo.execute("新建分组", feature: feature, scope: "main", book: nil, library: library)
        XCTAssertTrue(demo.groups.contains("睡前"))
        demo.execute("新建分组", feature: feature, scope: "main", book: nil, library: library)
        XCTAssertEqual(demo.outcomes["shelf:main"]?.success, false)
        demo.execute("全部停用", feature: FeatureCatalog.feature("sources"), scope: "main", book: nil, library: library)
        XCTAssertTrue(demo.sources.allSatisfy { !$0.enabled })
    }
}
