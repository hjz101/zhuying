import XCTest
@testable import Zhuying

private actor DeferredImportLoader: BookImportLoading {
    private var pending: CheckedContinuation<PreparedBookImport, Error>?
    private let delayed: PreparedBookImport
    init(delayed: PreparedBookImport) { self.delayed = delayed }
    func waiting() -> Bool { pending != nil }
    func complete() { pending?.resume(returning: delayed); pending = nil }
    func load(_ input: BookImportInput, encoding: ImportEncoding) async throws -> PreparedBookImport {
        if case .text("delay") = input { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try await BookImporter.load(input, encoding: encoding)
    }
}

@MainActor final class BookImportQueueTests: XCTestCase {
    func testCancelKeepsCompletedPreviewsRejectsLateResultAndRetriesRemainingItems() async throws {
        let domain = "com.zhuying.cancel.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false)
        let delayed = try BookImporter.prepare(data: Data("第一章 延迟\n第二个真实文件的正文。".utf8), name: "延迟.txt")
        let loader = DeferredImportLoader(delayed: delayed), session = BookImportSession(loader: loader)
        let add = Task { await session.add([.text("第一章 来信\n第一个文件的正文。"), .text("delay"), .text("第一章 远山\n第三个文件的正文。")], encoding: .automatic, library: library) }
        try await wait(loader)
        session.cancel(); await loader.complete(); await add.value
        XCTAssertFalse(session.busy); XCTAssertEqual(session.items.map(\.status), [.ready, .cancelled, .cancelled])
        XCTAssertTrue(library.books.isEmpty); XCTAssertEqual(session.selection.count, 1)
        let retry = Task { await session.retry(encoding: .automatic, library: library) }
        try await wait(loader); await loader.complete(); await retry.value
        XCTAssertEqual(session.items.map(\.status), [.ready, .ready, .ready])
        let excluded = try XCTUnwrap(session.items.last?.id); session.selection.remove(excluded)
        await session.commit(library: library, group: "待读")
        XCTAssertEqual(session.items.map(\.status), [.imported, .imported, .ready])
        XCTAssertEqual(library.books.count, 2); XCTAssertEqual(session.readyCount, 0)
    }

    func testFailedSaveRetriesPreparedContentAfterOriginalIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("原件.txt")
        try Data("第一章 来信\n确认之后应使用已经解析的正文。".utf8).write(to: file)
        let domain = "com.zhuying.retry.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let archive = root.appendingPathComponent("blocked/books.json")
        try Data("blocks directory creation".utf8).write(to: archive.deletingLastPathComponent())
        let library = LibraryStore(books: [], defaults: defaults, importsURL: archive, seedDemoData: false)
        let session = BookImportSession()
        await session.add([.file(file)], encoding: .automatic, library: library)
        await session.commit(library: library, group: "待读")
        XCTAssertEqual(session.failedCount, 1); XCTAssertTrue(library.books.isEmpty)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        await session.retry(encoding: .automatic, library: library)
        XCTAssertEqual(session.readyCount, 1)
        await session.commit(library: library, group: "待读")
        XCTAssertEqual(session.items.map(\.status), [.imported]); XCTAssertEqual(library.books.count, 1)
    }
    private func wait(_ loader: DeferredImportLoader) async throws {
        for _ in 0..<2000 {
            if await loader.waiting() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Import did not reach suspended loader"); throw ContentFailure.unavailable
    }
}
