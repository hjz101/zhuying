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
        XCTAssertFalse(store.hasSeenReadingGuide, "Seeded reading history must not suppress the first-use guide")
        for book in books {
            XCTAssertEqual(book.chapters.count, book.content.count)
            XCTAssertTrue(book.content.allSatisfy { $0.count == 14 && $0.allSatisfy { !$0.isEmpty } })
        }
    }

    func testShelfLayoutsPersistWithoutChangingReadingData() {
        let store = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(store.shelfLayout, .standard)
        let favorites = store.favorites
        let progress = store.progress
        store.sort = .title
        for layout in ShelfLayout.allCases {
            store.shelfLayout = layout
            let restored = LibraryStore(books: books, defaults: defaults)
            XCTAssertEqual(restored.shelfLayout, layout)
            XCTAssertEqual(restored.favorites, favorites)
            XCTAssertEqual(restored.progress, progress)
            XCTAssertEqual(restored.sort, .title)
            XCTAssertNil(restored.storageMessage)
        }
        store.settings = .init()
        XCTAssertEqual(LibraryStore(books: books, defaults: defaults).shelfLayout, .spines)
    }

    func testSpineRowsPreserveSortFiltersAndUniqueBooksAcrossCapacities() {
        let store = LibraryStore(books: books, defaults: defaults)
        store.shelfLayout = .spines
        for sort in ShelfSort.allCases {
            store.sort = sort
            let variants = [
                store.shelf,
                store.shelf.filter { store.progress[$0.id] != nil },
                store.shelf.filter { store.progress[$0.id] == nil }
            ]
            for visible in variants {
                let expectedCover = store.history.first { candidate in visible.contains { $0.id == candidate.id } }?.id ?? visible.first?.id
                for capacity in [3, 5, 6] {
                    let rows = store.spineRows(for: visible, columns: capacity)
                    let flattened = rows.flatMap(\.books)
                    XCTAssertEqual(flattened.map(\.id), visible.map(\.id), "Packing must preserve the selected sort and filter")
                    XCTAssertEqual(Set(flattened.map(\.id)).count, visible.count)
                    XCTAssertEqual(rows.compactMap(\.featuredID), expectedCover.map { [$0] } ?? [])
                    for row in rows {
                        XCTAssertFalse(row.books.isEmpty)
                        XCTAssertEqual(row.id, row.books.first?.id)
                        XCTAssertLessThanOrEqual(row.books.count + (row.featuredID == nil ? 0 : 1), capacity)
                        if let featuredID = row.featuredID { XCTAssertTrue(row.books.contains { $0.id == featuredID }) }
                    }
                }
            }
        }
    }

    func testSpineFeaturedCoverFollowsVisibleReadingHistoryWithoutChangingOrder() throws {
        let store = LibraryStore(books: books, defaults: defaults)
        store.sort = .added
        let originalOrder = store.shelf.map(\.id)
        let selected = try XCTUnwrap(store.shelf.last)
        store.record(selected, chapter: 1, now: Date(timeIntervalSince1970: 4_000_000_000))
        let rows = store.spineRows(for: store.shelf, columns: 5)
        XCTAssertEqual(rows.flatMap(\.books).map(\.id), originalOrder)
        XCTAssertEqual(rows.compactMap(\.featuredID), [selected.id])
        XCTAssertEqual(rows.last?.featuredID, selected.id, "A late cover can wrap onto the next shelf without moving ahead of other books")

        let hidden = try XCTUnwrap(books.first { $0.id == "echo" })
        store.record(hidden, chapter: 1, now: Date(timeIntervalSince1970: 4_000_000_001))
        XCTAssertFalse(store.isFavorite(hidden))
        XCTAssertEqual(store.spineRows(for: store.shelf, columns: 5).compactMap(\.featuredID), [selected.id])
        let filtered = store.shelf.filter { $0.id != selected.id }
        XCTAssertEqual(store.spineRows(for: filtered, columns: 5).compactMap(\.featuredID), ["changfeng"])
    }

    func testSpineRowsHandleEmptyUnreadSingleBookAndNarrowCapacity() throws {
        let store = LibraryStore(books: books, defaults: defaults)
        XCTAssertTrue(store.spineRows(for: [], columns: 5).isEmpty)
        let unread = store.shelf.filter { store.progress[$0.id] == nil }
        let first = try XCTUnwrap(unread.first)
        let rows = store.spineRows(for: unread, columns: 5)
        XCTAssertEqual(rows.compactMap(\.featuredID), [first.id])
        XCTAssertEqual(rows.flatMap(\.books).map(\.id), unread.map(\.id))
        let single = store.spineRows(for: [first], columns: 0)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.books.map(\.id), [first.id])
        XCTAssertEqual(single.first?.featuredID, first.id)
        let narrow = store.spineRows(for: store.shelf, columns: -1)
        XCTAssertEqual(narrow.flatMap(\.books).map(\.id), store.shelf.map(\.id))
        XCTAssertTrue(narrow.allSatisfy { $0.books.count + ($0.featuredID == nil ? 0 : 1) <= 3 })
    }

    func testSpineRowsKeepLongTitlesAndRestoreAfterRelaunch() throws {
        let longTitle = "一封穿过群山与岁月终于抵达远方的来信"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(books[0])) as? [String: Any])
        object["title"] = longTitle
        let renamed = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: object))
        let library = [renamed] + books.dropFirst()
        let store = LibraryStore(books: library, defaults: defaults)
        store.shelfLayout = .spines
        store.sort = .title
        store.record(renamed, chapter: 4, paragraph: 6, now: Date(timeIntervalSince1970: 4_000_000_000))
        let initialRows = store.spineRows(for: store.shelf, columns: 5)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: defaults.data(forKey: LibraryStore.storageKey)!) as? [String: Any])
        XCTAssertEqual(snapshot["shelfLayout"] as? String, "spines")
        let restored = LibraryStore(books: library, defaults: defaults)
        XCTAssertEqual(restored.shelfLayout, .spines)
        XCTAssertEqual(restored.sort, .title)
        XCTAssertEqual(restored.progress, store.progress)
        XCTAssertEqual(restored.favorites, store.favorites)
        let restoredRows = restored.spineRows(for: restored.shelf, columns: 5)
        XCTAssertEqual(restoredRows.map { $0.books.map(\.id) }, initialRows.map { $0.books.map(\.id) })
        XCTAssertEqual(restoredRows.compactMap(\.featuredID), [renamed.id])
        XCTAssertEqual(restoredRows.flatMap(\.books).first { $0.id == renamed.id }?.title, longTitle)
        XCTAssertNil(restored.storageMessage)
    }

    func testUnknownShelfLayoutFallsBackWithoutLosingSavedData() throws {
        let store = LibraryStore(books: books, defaults: defaults)
        store.record(books[0], chapter: 3, paragraph: 4)
        var object = try JSONSerialization.jsonObject(with: defaults.data(forKey: LibraryStore.storageKey)!) as! [String: Any]
        object["shelfLayout"] = "future-layout"
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: LibraryStore.storageKey)
        let restored = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(restored.shelfLayout, .standard)
        XCTAssertEqual(restored.favorites, store.favorites)
        XCTAssertEqual(restored.progress, store.progress)
        XCTAssertNil(restored.storageMessage)
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
        XCTAssertEqual(store.settings.fontSize, 30)
        XCTAssertEqual(store.settings.lineSpacing, 0)
    }
    func testOldSnapshotMigratesWithoutLosingData() throws {
        let store = LibraryStore(books: books, defaults: defaults)
        store.record(books[0], chapter: 3, paragraph: 4)
        var object = try JSONSerialization.jsonObject(with: defaults.data(forKey: LibraryStore.storageKey)!) as! [String: Any]
        object.removeValue(forKey: "sort"); object.removeValue(forKey: "updates")
        object.removeValue(forKey: "hasSeenReadingGuide")
        object.removeValue(forKey: "shelfLayout")
        var settings = object["settings"] as! [String: Any]
        for key in ["mode", "hand", "tapToTurn", "haptics"] { settings.removeValue(forKey: key) }
        object["settings"] = settings
        var progress = object["progress"] as! [String: [String: Any]]
        for key in progress.keys { progress[key]?.removeValue(forKey: "characterOffset") }
        object["progress"] = progress
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: LibraryStore.storageKey)
        let migrated = LibraryStore(books: books, defaults: defaults)
        XCTAssertNil(migrated.storageMessage)
        XCTAssertEqual(migrated.favorites, store.favorites)
        XCTAssertEqual(migrated.progress[books[0].id]?.paragraph, 4)
        XCTAssertEqual(migrated.settings.mode, .scroll)
        XCTAssertFalse(migrated.hasSeenReadingGuide)
        XCTAssertEqual(migrated.shelfLayout, .standard)
    }

    func testHistoryIncludesUnfavoritedBooksAndIgnoresShelfSort() {
        let store = LibraryStore(books: books, defaults: defaults)
        let book = books.first { $0.id == "echo" }!
        store.record(book, chapter: 1, paragraph: 5, characterOffset: 9)
        store.sort = .title
        XCTAssertEqual(store.history.first?.id, book.id)
        XCTAssertFalse(store.isFavorite(book))
        let restored = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(restored.history.first?.id, book.id)
        XCTAssertEqual(restored.progress[book.id]?.characterOffset, 9)
        XCTAssertEqual(restored.sort, .title)
    }

    func testSortingAndBulkRemovalUndoPreserveReadingData() {
        let store = LibraryStore(books: books, defaults: defaults)
        let initial = store.favorites
        let progress = store.progress
        let receipt = store.removeFavorites(Set(initial.prefix(3)))
        XCTAssertEqual(receipt.count, 3)
        XCTAssertEqual(store.favorites.count, 3)
        XCTAssertEqual(store.progress, progress)
        store.undoRemoval(receipt)
        store.undoRemoval(receipt)
        XCTAssertEqual(store.favorites, initial)
        store.toggleFavorite(books.last!)
        store.sort = .added
        XCTAssertEqual(store.shelf.first?.id, books.last?.id)
        store.sort = .title
        XCTAssertEqual(store.shelf.map(\.title), store.shelf.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func testUpdateBadgesDecreaseOnlyAfterReadingUpdatedChapters() {
        let store = LibraryStore(books: books, defaults: defaults)
        let book = books[0]
        XCTAssertEqual(store.updateCount(book), 3)
        store.record(book, chapter: 2)
        XCTAssertEqual(store.updateCount(book), 3)
        store.record(book, chapter: 10)
        XCTAssertEqual(store.updateCount(book), 1)
        store.record(book, chapter: 1)
        XCTAssertEqual(store.updateCount(book), 1)
        store.record(book, chapter: 11)
        XCTAssertEqual(store.updateCount(book), 0)
        XCTAssertEqual(LibraryStore(books: books, defaults: defaults).updateCount(book), 0)
        store.simulateUpdates()
        XCTAssertEqual(store.updateCount(book), 3)
        XCTAssertEqual(store.updateCount(books[1]), 0)
    }

    func testExpandedSettingsSurviveRelaunch() {
        let store = LibraryStore(books: books, defaults: defaults)
        store.settings = .init(fontSize: 22, lineSpacing: 18, theme: .dark, mode: .paged, tapToTurn: true, haptics: false)
        XCTAssertEqual(LibraryStore(books: books, defaults: defaults).settings, store.settings)
    }

    func testGuideCompletionSurvivesRelaunchAndPreferenceReset() {
        let store = LibraryStore(books: books, defaults: defaults)
        store.settings = .init(fontSize: 22, theme: .dark, mode: .paged, tapToTurn: true)
        let favorites = store.favorites
        let progress = store.progress
        let settings = store.settings
        store.completeReadingGuide()
        store.completeReadingGuide()
        let restored = LibraryStore(books: books, defaults: defaults)
        XCTAssertTrue(restored.hasSeenReadingGuide)
        XCTAssertEqual(restored.favorites, favorites)
        XCTAssertEqual(restored.progress, progress)
        XCTAssertEqual(restored.settings, settings)
        restored.settings = .init()
        XCTAssertTrue(LibraryStore(books: books, defaults: defaults).hasSeenReadingGuide)
    }

    func testOpeningAnotherBookDoesNotConsumeFirstUseGuide() {
        let store = LibraryStore(books: books, defaults: defaults)
        store.read(books[0])
        store.read(books[1])
        XCTAssertFalse(store.hasSeenReadingGuide)
        XCTAssertFalse(LibraryStore(books: books, defaults: defaults).hasSeenReadingGuide)
        store.completeReadingGuide()
        store.read(books[2])
        XCTAssertTrue(store.hasSeenReadingGuide)
    }

}
