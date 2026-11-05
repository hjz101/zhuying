import XCTest
@testable import Yueshan

final class SQLiteLibraryRepositoryTests: XCTestCase {
    private func book(_ id: String = "b") -> LibraryBookRecord {
        .init(id: id, title: "真实书籍", author: "作者", summary: "简介", addedAt: Date(timeIntervalSince1970: 100))
    }
    private func chapter(_ id: String = "c", bookID: String = "b", order: Int = 0) -> ChapterRecord {
        .init(id: id, bookID: bookID, nativeChapterID: id, title: "章节", order: order, access: .readable)
    }
    private func anchor(_ chapterID: String = "c", bookID: String = "b") throws -> ReadingAnchor {
        try .init(bookID: bookID, document: .init(chapterID: chapterID, paragraphs: ["段落内容"]), paragraph: 0, offset: 2)
    }
    func testRecordsAndPreferencesSurviveReopeningWithoutEmbeddingWholeBook() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reader.sqlite")
        let repository = try SQLiteLibraryRepository(url: url)
        try await repository.save(book: book(), chapters: [chapter("c2", order: 1), chapter()])
        try await repository.save(progress: anchor())
        try await repository.setFavorite(bookID: "b", enabled: true)
        try await repository.setGroup(bookID: "b", name: "待读")
        try await repository.savePreference(Data("settings".utf8), key: "reader")
        let reopened = try SQLiteLibraryRepository(url: url)
        let books = try await reopened.books(), chapters = try await reopened.chapters(bookID: "b")
        let progress = try await reopened.progress(bookID: "b"), favorites = try await reopened.favoriteIDs()
        let groups = try await reopened.groups(), preference = try await reopened.preference(key: "reader")
        XCTAssertEqual(books, [book()])
        XCTAssertEqual(chapters.map(\.id), ["c", "c2"])
        XCTAssertEqual(progress?.chapterID, "c")
        XCTAssertEqual(favorites, ["b"])
        XCTAssertEqual(groups, ["b": "待读"])
        XCTAssertEqual(preference, Data("settings".utf8))
    }
    func testRemovingFavoriteRetainsProgressAndBookmarkAndDuplicateIsIdempotent() async throws {
        let repository = try SQLiteLibraryRepository()
        try await repository.save(book: book(), chapters: [chapter()])
        let saved = try anchor()
        let bookmark = LibraryBookmarkRecord(title: "记住这里", anchor: saved)
        try await repository.save(progress: saved)
        try await repository.setFavorite(bookID: "b", enabled: true)
        try await repository.setFavorite(bookID: "b", enabled: true)
        try await repository.save(bookmark: bookmark)
        try await repository.save(bookmark: bookmark)
        let before = try await repository.favoriteIDs()
        XCTAssertEqual(before, ["b"])
        try await repository.setFavorite(bookID: "b", enabled: false)
        let favorites = try await repository.favoriteIDs(), bookmarks = try await repository.bookmarks(bookID: "b")
        let progress = try await repository.progress(bookID: "b")
        XCTAssertTrue(favorites.isEmpty)
        XCTAssertEqual(bookmarks, [bookmark])
        XCTAssertEqual(progress, saved)
    }
    func testCatalogDeletionPreservesHistoricalLocationAndRejectsInvalidNewProgress() async throws {
        let repository = try SQLiteLibraryRepository()
        try await repository.save(book: book(), chapters: [chapter()])
        let saved = try anchor()
        try await repository.save(progress: saved)
        try await repository.save(book: book(), chapters: [chapter("replacement")])
        let progress = try await repository.progress(bookID: "b")
        XCTAssertEqual(progress, saved)
        do { try await repository.save(progress: saved); XCTFail("Missing chapter must not become new progress") }
        catch { XCTAssertEqual(error as? ContentFailure, .missingChapter) }
        let preserved = try await repository.progress(bookID: "b")
        XCTAssertEqual(preserved, saved)
    }
    func testConflictingSourceBindingRollsBackEntireBookAndCatalogTransaction() async throws {
        let repository = try SQLiteLibraryRepository()
        var original = book()
        original.source = .init(sourceID: "source", nativeBookID: "native", provider: "提供方", bookURL: "https://example.test/book")
        try await repository.save(book: original, chapters: [chapter()])
        var conflicting = book("other")
        conflicting.source = original.source
        do {
            try await repository.save(book: conflicting, chapters: [chapter("other-chapter", bookID: "other")])
            XCTFail("A source edition must not silently move to a different work")
        } catch {}
        let books = try await repository.books(), chapters = try await repository.chapters(bookID: "b")
        let absent = try await repository.chapters(bookID: "other")
        XCTAssertEqual(books, [original])
        XCTAssertEqual(chapters.map(\.id), ["c"])
        XCTAssertTrue(absent.isEmpty)
    }
    func testInvalidCatalogCannotOverwriteValidRecordsAndBooksCannotShareProgress() async throws {
        let repository = try SQLiteLibraryRepository()
        try await repository.save(book: book(), chapters: [chapter()])
        do { try await repository.save(book: book(), chapters: [chapter(), chapter()]); XCTFail("Duplicate chapter") }
        catch { XCTAssertEqual(error as? ContentFailure, .invalidResponse) }
        try await repository.save(book: book("other"), chapters: [chapter("d", bookID: "other")])
        try await repository.save(progress: anchor())
        try await repository.save(progress: anchor("d", bookID: "other"))
        let first = try await repository.progress(bookID: "b"), second = try await repository.progress(bookID: "other")
        XCTAssertEqual(first?.chapterID, "c")
        XCTAssertEqual(second?.chapterID, "d")
        let original = try await repository.chapters(bookID: "b")
        XCTAssertEqual(original.map(\.id), ["c"])
    }
    func testConcurrentFavoriteWritesAreSerializedWithoutDuplicates() async throws {
        let repository = try SQLiteLibraryRepository()
        try await repository.save(book: book(), chapters: [chapter()])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { try await repository.setFavorite(bookID: "b", enabled: true) } }
            try await group.waitForAll()
        }
        let result = try await repository.favoriteIDs()
        XCTAssertEqual(result, ["b"])
    }
}
