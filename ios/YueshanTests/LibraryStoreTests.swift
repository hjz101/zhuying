import XCTest
@testable import Yueshan

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    private var books: [Book]!

    override func setUp() async throws {
        domain = "com.yueshan.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        books = try Book.load(bundle: Bundle(for: LibraryStore.self))
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testMockLibraryAndInitialShelf() {
        let store = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(books.count, 8)
        XCTAssertEqual(Set(books.map(\.id)).count, 8)
        XCTAssertEqual(store.favorites.count, 6)
        XCTAssertEqual(store.readingCount, 3)
        XCTAssertEqual(store.recent?.id, "changfeng")
        for book in books {
            XCTAssertEqual(book.chapters.count, book.content.count)
            XCTAssertTrue(book.content.allSatisfy { $0.count == 14 && $0.allSatisfy { !$0.isEmpty } })
        }
    }

    func testTitleAuthorAndCategorySearch() {
        let store = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(store.search(" 长风 ").map(\.id), ["changfeng"])
        XCTAssertEqual(store.search("林间渡").map(\.id), ["changfeng"])
        XCTAssertEqual(store.search("", category: "科幻").count, 2)
        XCTAssertTrue(store.search("群星", category: "都市").isEmpty)
        XCTAssertTrue(store.search("不存在的故事").isEmpty)
    }

    func testFavoriteRemovalPreservesProgressAndReaddingDoesNotDuplicate() {
        let store = LibraryStore(books: books, defaults: defaults)
        let book = books.first { $0.id == "changfeng" }!
        let old = store.progress[book.id]
        XCTAssertFalse(store.toggleFavorite(book))
        XCTAssertEqual(store.progress[book.id], old)
        XCTAssertTrue(store.toggleFavorite(book))
        XCTAssertEqual(store.favorites.filter { $0 == book.id }.count, 1)
    }

    func testUnfavoritedReadingAndChapterBounds() {
        let store = LibraryStore(books: books, defaults: defaults)
        let book = books.first { $0.id == "echo" }!
        XCTAssertTrue(store.record(book, chapter: 2, paragraph: 6))
        XCTAssertFalse(store.isFavorite(book))
        let old = store.progress[book.id]
        XCTAssertFalse(store.record(book, chapter: -1))
        XCTAssertFalse(store.record(book, chapter: book.chapters.count))
        XCTAssertEqual(store.progress[book.id], old)
    }

    func testProgressPreferencesAndFavoritesSurviveRelaunch() {
        let store = LibraryStore(books: books, defaults: defaults)
        let book = books.first { $0.id == "echo" }!
        store.toggleFavorite(book)
        store.record(book, chapter: 4, paragraph: 7)
        store.settings = ReadingSettings(fontSize: 24, lineSpacing: 18, theme: .dark)
        let restored = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(restored.settings, store.settings)
        XCTAssertEqual(restored.progress, store.progress)
        XCTAssertEqual(restored.favorites, store.favorites)
        XCTAssertEqual(restored.recent?.id, book.id)
    }

    func testEmptyShelfRemainsEmpty() {
        let store = LibraryStore(books: books, defaults: defaults)
        for book in store.shelf { store.toggleFavorite(book) }
        let restored = LibraryStore(books: books, defaults: defaults)
        XCTAssertTrue(restored.favorites.isEmpty)
        XCTAssertEqual(restored.progress.count, 3)
    }

    func testCorruptStorageFallsBackWithMessage() {
        defaults.set(Data("invalid".utf8), forKey: LibraryStore.storageKey)
        let store = LibraryStore(books: books, defaults: defaults)
        XCTAssertNotNil(store.storageMessage)
        XCTAssertEqual(store.favorites.count, 6)
    }

    func testStoredValuesAreClampedAndDeduplicated() throws {
        let raw = LibrarySnapshot(favorites: ["changfeng", "changfeng", "unknown"], progress: ["changfeng": .init(chapter: 999, paragraph: -5, updatedAt: Date())], settings: .init(fontSize: 900, lineSpacing: -20, theme: .paper))
        defaults.set(try JSONEncoder().encode(raw), forKey: LibraryStore.storageKey)
        let store = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(store.favorites, ["changfeng"])
        XCTAssertEqual(store.progress["changfeng"]?.chapter, 11)
        XCTAssertEqual(store.progress["changfeng"]?.paragraph, 0)
        XCTAssertEqual(store.settings.fontSize, 20)
        XCTAssertEqual(store.settings.lineSpacing, 12)
    }
}
