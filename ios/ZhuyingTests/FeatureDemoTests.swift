import XCTest
@testable import Zhuying

@MainActor
final class FeatureDemoTests: XCTestCase {
    private var library: LibraryStore!
    private var demo: FeatureDemoStore!
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        domain = "com.zhuying.catalog-tests.\(UUID().uuidString)"
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
        XCTAssertEqual(ToolCategory.allCases.count, 7)
        XCTAssertEqual(ids.count, FeatureCatalog.all.count)
        XCTAssertEqual(Set(ids), Set(FeatureCatalog.all.map(\.id)))
        for category in ToolCategory.allCases {
            XCTAssertFalse(category.features.isEmpty)
            XCTAssertEqual(category.search("   ").map(\.id), category.features.map(\.id))
        }
        XCTAssertEqual(ToolCategory.data.search("备份").map(\.id), ["backup", "icloud"])
        XCTAssertTrue(ToolCategory.reading.search("书源编辑").isEmpty)
        XCTAssertEqual(ToolCategory.sources.search("书源编辑").map(\.id), ["sourceEdit"])
        XCTAssertTrue(ToolCategory.advanced.search("书源编辑").isEmpty)
        for category in ToolCategory.allCases {
            XCTAssertEqual(Set((category.primaryFeatures + category.secondaryFeatures).map(\.id)), Set(category.features.map(\.id)))
        }
        XCTAssertFalse(ToolCategory.files.primaryFeatures.contains { ["txt", "epub", "pdf"].contains($0.id) })
        XCTAssertEqual(ToolCategory.files.secondaryFeatures.count, 5)
        XCTAssertTrue(ToolCategory.advanced.features.contains { $0.id == "engine" })
        XCTAssertTrue(ToolCategory.reading.primaryFeatures.contains { $0.id == "purify" })
    }

    func testCommonToolsAreUniqueAndSearchStillCoversAllCategories() {
        let common = FeatureCatalog.commonTools
        XCTAssertEqual(common.count, 4)
        XCTAssertEqual(Set(common.map(\.id)).count, common.count)
        XCTAssertEqual(common.map(\.id), ["import", "fulltext", "themes", "sources"])
        for feature in FeatureCatalog.all {
            XCTAssertTrue(FeatureCatalog.search(feature.title).contains { $0.id == feature.id })
        }
        XCTAssertTrue(FeatureCatalog.search("不存在的模块").isEmpty)
    }

    func testSourceFilePreviewValidatesDeduplicatesAndRequiresConfirmation() throws {
        let data = Data("""
        [{"bookSourceName":"远山","bookSourceUrl":"https://new.example","bookSourceGroup":"收藏","bookSourceType":2,"enabled":false},
         {"name":"重复","url":"https://new.example/"},
         {"name":"已有","url":"https://books.example"},
         {"name":"无网址"}, 42, {"name":"坏链接","url":"file:///tmp/source"},
         {"name":"  ","url":"https://blank.example"}]
        """.utf8)
        let original = demo.sources
        let preview = try SourceImportPreview.parse(data, existing: demo.sources)
        XCTAssertEqual(demo.sources, original)
        XCTAssertEqual(preview.sources.count, 1)
        XCTAssertEqual(preview.duplicates, 2)
        XCTAssertEqual(preview.invalid, 4)
        XCTAssertEqual(preview.sources.first?.kind, .comic)
        XCTAssertEqual(preview.sources.first?.group, "收藏")
        XCTAssertEqual(preview.sources.first?.enabled, false)
        XCTAssertEqual(demo.confirmSourceImport(preview), 1)
        XCTAssertEqual(demo.sources.count, original.count + 1)
        XCTAssertEqual(demo.confirmSourceImport(preview), 0)
    }

    func testSourceFileRejectsMalformedOversizedAndEmptyContent() throws {
        for value in ["bad JSON", "null", "42", "\"text\""] {
            XCTAssertThrowsError(try SourceImportPreview.parse(Data(value.utf8), existing: []))
        }
        XCTAssertThrowsError(try SourceImportPreview.parse(Data(repeating: 32, count: 5 * 1024 * 1024 + 1), existing: []))
        let empty = try SourceImportPreview.parse(Data("[]".utf8), existing: [])
        XCTAssertTrue(empty.sources.isEmpty)
        let single = try SourceImportPreview.parse(Data("{\"name\":\"  新源  \",\"url\":\"https://single.example\"}".utf8), existing: [])
        XCTAssertEqual(single.sources.first?.name, "新源")
    }

    func testSourceFiltersComposeCategoryGroupStatusAndSearch() {
        XCTAssertEqual(demo.filteredSources(kind: .novel).map(\.id), ["shanhai", "yunjian"])
        XCTAssertEqual(demo.filteredSources(kind: .comic, status: .failed).map(\.id), ["paper"])
        XCTAssertTrue(demo.filteredSources(kind: .audio).isEmpty)
        XCTAssertEqual(demo.filteredSources(status: .expired).map(\.id), ["yunjian"])
        XCTAssertEqual(demo.filteredSources(query: "  YUNJIAN.EXAMPLE \n").map(\.id), ["yunjian"])
        demo.moveSources(["shanhai", "paper"], group: "常用")
        XCTAssertEqual(demo.filteredSources(kind: .novel, group: "常用").map(\.id), ["shanhai"])
        XCTAssertEqual(demo.filteredSources(query: "常用").map(\.id), ["shanhai", "paper"])
        XCTAssertTrue(demo.filteredSources(kind: .comic, status: .expired).isEmpty)
    }

    func testSourceSortingKeepsPinsFirstAndUnknownOrFailedResponsesLast() {
        let newID = demo.createSource()
        XCTAssertEqual(demo.filteredSources(sort: .response).map(\.id), ["shanhai", "yunjian", "paper", newID])
        demo.toggleSourcePin("paper")
        XCTAssertEqual(demo.filteredSources(sort: .response).first?.id, "paper")
        XCTAssertEqual(demo.filteredSources(sort: .name).first?.id, "paper")
        demo.toggleSourcePin("paper")
        XCTAssertEqual(demo.filteredSources(sort: .response).first?.id, "shanhai")
        demo.sources[1].responseMilliseconds = 143
        XCTAssertEqual(demo.filteredSources(sort: .response).map(\.id), ["shanhai", "yunjian", "paper", newID])
        demo.toggleSourcePin("missing")
        XCTAssertFalse(demo.sources.contains { $0.pinned })
    }

    func testSourceBatchChangesOnlySelectedSourcesAndPreservesCategoryAndReading() {
        let before = library.progress
        demo.setSourcesEnabled(["shanhai", "paper", "missing"], enabled: false)
        XCTAssertEqual(Set(demo.filteredSources(status: .disabled).map(\.id)), ["shanhai", "paper"])
        XCTAssertTrue(demo.sources[1].enabled)
        demo.moveSources(["paper"], group: "  我的常用  ")
        XCTAssertEqual(demo.sources[2].group, "我的常用")
        XCTAssertEqual(demo.sources[2].kind, .comic)
        demo.moveSources(["paper"], group: " \n")
        XCTAssertEqual(demo.sources[2].group, "我的常用")
        demo.setSourcesEnabled([], enabled: false)
        demo.setSourcesEnabled(["paper"], enabled: true)
        XCTAssertEqual(demo.filteredSources(status: .disabled).map(\.id), ["shanhai"])
        XCTAssertEqual(library.progress, before)
    }

    func testNewSourceOpensItsOwnEditableDraft() {
        let id = demo.createSource()
        let edit = FeatureCatalog.feature("sourceEdit")
        demo.prepareSource(edit, scope: id)
        XCTAssertEqual(demo.text(edit, "name", scope: id), "自定义书源 4")
        XCTAssertEqual(demo.sources.last?.kind, .novel)
        XCTAssertNil(demo.sources.last?.responseMilliseconds)
        XCTAssertFalse(demo.sources.last!.hasFailure)
        let comicID = demo.createSource(kind: .comic, group: "个人收藏")
        XCTAssertEqual(demo.filteredSources(kind: .comic, group: "个人收藏").map(\.id), [comicID])
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
        XCTAssertEqual(first, ThemeImportResult(added: 2, duplicates: 1, invalid: 1, titlesAdded: 3, bubblesAdded: 3))
        XCTAssertEqual(demo.themes.count, 10)
        XCTAssertEqual(demo.themes.filter { $0.id == "mist" }.count, 1)
        XCTAssertEqual(demo.activeThemeID, "paper")
        let second = demo.importDemoThemes()
        XCTAssertEqual(second, ThemeImportResult(added: 0, duplicates: 5, invalid: 1))
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
