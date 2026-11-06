import XCTest
@testable import Zhuying

private actor ControlledChapterRepository: ChapterContentRepository {
    private var requests: [String: CheckedContinuation<ChapterDocument?, Error>] = [:]
    func document(chapterID: String) async throws -> ChapterDocument? {
        try await withCheckedThrowingContinuation { requests[chapterID] = $0 }
    }
    func save(_ document: ChapterDocument) {}
    func isWaiting(_ id: String) -> Bool { requests[id] != nil }
    func complete(_ id: String, result: Result<ChapterDocument?, Error>) { requests.removeValue(forKey: id)?.resume(with: result) }
}

@MainActor final class ReadingSessionControllerTests: XCTestCase {
    private func request(_ id: String, anchor: ReadingAnchor? = nil) -> ReadingChapterRequest {
        .init(bookID: "b", chapter: .init(id: id, bookID: "b", nativeChapterID: id, title: id, order: 0, access: .readable), anchor: anchor)
    }
    private func wait(_ id: String, repository: ControlledChapterRepository) async throws {
        for _ in 0..<2000 {
            if await repository.isWaiting(id) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Chapter request did not start"); throw ContentFailure.unavailable
    }
    func testLateResultCannotReplaceNewChapterAndFailureCannotAdvanceConfirmedLocation() async throws {
        let repository = ControlledChapterRepository(), session = ReadingSessionController(repository: repository)
        let first = Task { await session.load(request("a")) }; try await wait("a", repository: repository)
        let second = Task { await session.load(request("b")) }; try await wait("b", repository: repository)
        await repository.complete("b", result: .success(.init(chapterID: "b", paragraphs: ["正确的新章节"])))
        let accepted = await second.value; XCTAssertTrue(accepted)
        let confirmed = session.confirmed
        await repository.complete("a", result: .success(.init(chapterID: "a", paragraphs: ["晚到的旧章节"])))
        let stale = await first.value; XCTAssertFalse(stale); XCTAssertEqual(session.confirmed, confirmed)
        let failing = Task { await session.load(request("c")) }; try await wait("c", repository: repository)
        XCTAssertEqual(session.confirmed, confirmed); XCTAssertEqual(session.phase, .loading)
        await repository.complete("c", result: .failure(ContentFailure.storageFailure))
        let failed = await failing.value; XCTAssertFalse(failed); XCTAssertEqual(session.confirmed, confirmed)
        XCTAssertEqual(session.pending?.chapter.id, "c")
        let retry = Task { await session.retry() }; try await wait("c", repository: repository)
        await repository.complete("c", result: .success(.init(chapterID: "c", paragraphs: ["重试成功"])))
        let retried = await retry.value; XCTAssertTrue(retried); XCTAssertEqual(session.confirmed?.chapterID, "c")
    }
    func testCancelAndWrongChapterResponseNeverCreateProgress() async throws {
        let repository = ControlledChapterRepository(), session = ReadingSessionController(repository: repository)
        let task = Task { await session.load(request("a")) }; try await wait("a", repository: repository)
        session.cancel()
        await repository.complete("a", result: .success(.init(chapterID: "a", paragraphs: ["取消后仍返回"])))
        let accepted = await task.value; XCTAssertFalse(accepted); XCTAssertNil(session.confirmed); XCTAssertEqual(session.phase, .idle)
        let wrong = Task { await session.load(request("b")) }; try await wait("b", repository: repository)
        await repository.complete("b", result: .success(.init(chapterID: "other-book", paragraphs: ["错章"])))
        let mismatched = await wrong.value; XCTAssertFalse(mismatched); XCTAssertNil(session.confirmed)
    }
    func testSavedUnicodeAnchorRecoversAndUncertainContentIsNotSilentlyReset() async throws {
        let repository = ControlledChapterRepository(), session = ReadingSessionController(repository: repository)
        let old = ChapterDocument(chapterID: "a", paragraphs: ["原来的段落👩🏽‍🚀与长久保存的阅读位置。"])
        let anchor = try ReadingAnchor(bookID: "b", document: old, paragraph: 0, offset: 7)
        let changed = ChapterDocument(chapterID: "a", paragraphs: ["插入的新段落", old.paragraphs[0].text])
        let task = Task { await session.load(request("a", anchor: anchor)) }; try await wait("a", repository: repository)
        await repository.complete("a", result: .success(changed))
        let recovered = await task.value; XCTAssertTrue(recovered); XCTAssertEqual(session.confirmed?.paragraphIndex, 1)
        let confirmed = session.confirmed
        let uncertain = Task { await session.load(request("a", anchor: anchor)) }; try await wait("a", repository: repository)
        await repository.complete("a", result: .success(.init(chapterID: "a", paragraphs: ["完全不同的内容，无法推断位置。"])))
        let accepted = await uncertain.value; XCTAssertFalse(accepted); XCTAssertEqual(session.confirmed, confirmed)
    }
    func testRestrictedChapterShowsAccessFailureWithoutRequestingAMissingDocument() async {
        let repository = ControlledChapterRepository(), session = ReadingSessionController(repository: repository)
        let chapter = ChapterRecord(id: "paid", bookID: "b", nativeChapterID: "paid", title: "受限章节", order: 0, access: .restricted)
        let accepted = await session.load(.init(bookID: "b", chapter: chapter))
        XCTAssertFalse(accepted); XCTAssertEqual(session.phase, .failed(ContentFailure.restricted.localizedDescription))
        let requested = await repository.isWaiting(chapter.id); XCTAssertFalse(requested)
    }
}


private actor RefreshingReaderRepository: ChapterDocumentLoading {
    let original = ChapterDocument(chapterID: "a", paragraphs: ["保留的阅读位置与正文。"])
    private(set) var refreshed = false
    func document(chapterID: String) -> ChapterDocument? { original }
    func refreshedDocument(chapterID: String) -> ChapterDocument? {
        refreshed = true
        return .init(chapterID: chapterID, paragraphs: ["新加入的前置段落。", original.paragraphs[0].text])
    }
}

extension ReadingSessionControllerTests {
    func testExplicitRefreshPassesThroughPurificationAndRecoversReadingAnchor() async throws {
        let repository = RefreshingReaderRepository()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = ContentProcessingStore(directory: root)
        try await processor.save([.init(name: "净化", pattern: "正文", replacement: "故事", enabled: true)])
        let session = ReadingSessionController(repository: ProcessedChapterRepository(base: repository, processor: processor, bookID: "b", sourceID: nil))
        let loaded = await session.load(request("a")); XCTAssertTrue(loaded)
        let original = try XCTUnwrap(session.document)
        let saved = try ReadingAnchor(bookID: "b", document: original, paragraph: 0, offset: 4)
        var refreshing = request("a", anchor: saved); refreshing.refresh = true
        let accepted = await session.load(refreshing)
        XCTAssertTrue(accepted)
        let forwarded = await repository.refreshed; XCTAssertTrue(forwarded)
        XCTAssertEqual(session.confirmed?.paragraphIndex, 1); XCTAssertEqual(session.confirmed?.utf16Offset, 4)
        XCTAssertEqual(session.document?.paragraphs.last?.text, "保留的阅读位置与故事。")
        XCTAssertEqual(session.phase, .readable)
    }
}
