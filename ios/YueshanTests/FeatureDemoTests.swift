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
