import XCTest
@testable import Yueshan

final class ChapterMemoryCacheTests: XCTestCase {
    func testLeastRecentlyUsedEvictionAndOversizeCurrentChapter() {
        var cache = ChapterMemoryCache(maximumCount: 2, maximumBytes: 20)
        cache["a"] = .init(chapterID: "a", paragraphs: ["1234"])
        cache["b"] = .init(chapterID: "b", paragraphs: ["5678"])
        XCTAssertNotNil(cache["a"])
        cache["c"] = .init(chapterID: "c", paragraphs: ["abcd"])
        XCTAssertNil(cache["b"]); XCTAssertEqual(cache.count, 2)
        cache["long"] = .init(chapterID: "long", paragraphs: [String(repeating: "长", count: 30)])
        XCTAssertEqual(cache.count, 1); XCTAssertEqual(cache.bytes, 60)
        cache["small"] = .init(chapterID: "small", paragraphs: ["小"])
        XCTAssertEqual(cache.count, 1); XCTAssertNil(cache["long"])
    }

    func testMetadataBootstrapDoesNotReadProseAndOpeningChaptersHasBoundedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (1...20).map { "第\($0)章 山林\n这一章的真实正文与其他章节不同：\($0)。" }.joined(separator: "\n")
        let book = try BookImporter.prepare(data: Data(text.utf8), name: "长书.txt").book
        let writer = try ProductionLibraryPersistence(directory: root)
        _ = try await writer.bootstrap(legacySnapshot: nil, archiveURL: nil)
        _ = try await writer.importBook(book, group: "长书")
        let reopened = try ProductionLibraryPersistence(directory: root)
        let state = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(state.books.first, book.metadataOnly())
        let initialCount = await reopened.cachedChapterCount(); XCTAssertEqual(initialCount, 0)
        for chapter in try XCTUnwrap(state.catalogs[book.id]) {
            let loaded = try await reopened.document(chapterID: chapter.id)
            XCTAssertEqual(loaded?.paragraphs.map(\.text), book.content[chapter.order])
            let count = await reopened.cachedChapterCount(); XCTAssertLessThanOrEqual(count, 3)
        }
    }

    @MainActor func testDamagedChapterKeepsShelfAndHistoryAndCanRetryAfterFileRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try BookImporter.prepare(data: Data("第一章 来信\n已确认的阅读位置。\n第二章 山林\n即将损坏又被修复的正文。".utf8), name: "修复.txt").book
        let writer = try ProductionLibraryPersistence(directory: root)
        _ = try await writer.bootstrap(legacySnapshot: nil, archiveURL: nil)
        _ = try await writer.importBook(book, group: "待读")
        try await writer.saveState(.init(favorites: [book.id], progress: [book.id: .init(chapter: 0, paragraph: 0, updatedAt: Date())]))
        let catalog = try await SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite")).chapters(bookID: book.id)
        let objects = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("chapters/objects"), includingPropertiesForKeys: nil)
        let object = try XCTUnwrap(objects.first { url in (try? JSONDecoder().decode(ChapterDocument.self, from: Data(contentsOf: url)))?.chapterID == catalog[1].id })
        let original = try Data(contentsOf: object); try Data("corrupt chapter".utf8).write(to: object)
        let reopened = try ProductionLibraryPersistence(directory: root)
        let state = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        XCTAssertEqual(state.books.map(\.id), [book.id]); XCTAssertEqual(state.snapshot.progress[book.id]?.chapter, 0)
        let session = ReadingSessionController(repository: reopened)
        let first = await session.load(.init(bookID: book.id, chapter: catalog[0], anchor: state.anchors[book.id])); XCTAssertTrue(first)
        let confirmed = session.confirmed
        let failed = await session.load(.init(bookID: book.id, chapter: catalog[1])); XCTAssertFalse(failed)
        XCTAssertEqual(session.confirmed, confirmed)
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let preserved = try await records.progress(bookID: book.id); XCTAssertEqual(preserved, state.anchors[book.id])
        try original.write(to: object, options: .atomic)
        let retried = await session.retry(); XCTAssertTrue(retried); XCTAssertEqual(session.document?.paragraphs.map(\.text), book.content[1])
    }
}
