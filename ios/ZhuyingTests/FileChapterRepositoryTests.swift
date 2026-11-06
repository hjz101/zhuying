import XCTest
@testable import Zhuying

final class FileChapterRepositoryTests: XCTestCase {
    private struct RejectSecondChapter: AtomicFileWriting {
        func write(_ data: Data, to url: URL) throws {
            if let document = try? JSONDecoder().decode(ChapterDocument.self, from: data), document.chapterID == "second-new" {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        }
    }
    private struct RejectManifest: AtomicFileWriting {
        func write(_ data: Data, to url: URL) throws {
            if url.lastPathComponent == "manifest.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }
    func testAtomicChapterWriteReopenAndUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileChapterRepository(directory: root)
        let original = ChapterDocument(chapterID: "chapter/../../unsafe-id", paragraphs: ["真实正文", "第二段"])
        try await repository.save(original)
        let reloaded = try FileChapterRepository(directory: root)
        let saved = try await reloaded.document(chapterID: original.chapterID)
        XCTAssertEqual(saved, original)
        let updated = ChapterDocument(chapterID: original.chapterID, paragraphs: ["更新后正文"])
        try await reloaded.save(updated)
        let reopened = try FileChapterRepository(directory: root)
        let current = try await reopened.document(chapterID: original.chapterID)
        XCTAssertEqual(current, updated)
        let objects = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: nil)
        XCTAssertEqual(objects.count, 1, "Unreferenced old version is reclaimed on reopen")
    }
    func testManifestFailureRetainsCommittedContentAndCleansNewObject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ChapterDocument(chapterID: "c", paragraphs: ["上次成功内容"])
        let repository = try FileChapterRepository(directory: root)
        try await repository.save(original)
        let failing = try FileChapterRepository(directory: root, writer: RejectManifest())
        do { try await failing.save(.init(chapterID: "c", paragraphs: ["写入失败的新版本"])); XCTFail("Must report failed commit") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let inMemory = try await failing.document(chapterID: "c")
        let reopened = try FileChapterRepository(directory: root)
        let onDisk = try await reopened.document(chapterID: "c")
        XCTAssertEqual(inMemory, original)
        XCTAssertEqual(onDisk, original)
        let objects = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: nil)
        XCTAssertEqual(objects.count, 1)
    }
    func testDamagedObjectIsReportedAndNeverReturnedAsValidContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileChapterRepository(directory: root)
        try await repository.save(.init(chapterID: "c", paragraphs: ["正文"] ))
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: url)
        do { _ = try await repository.document(chapterID: "c"); XCTFail("Checksum must fail") }
        catch { XCTAssertEqual(error as? ContentFailure, .storageFailure) }
    }
    func testInvalidManifestDoesNotDeleteExistingObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(repeating: "a", count: 64) + ".json"
        let preserved = folder.appendingPathComponent(name)
        try Data("keep".utf8).write(to: preserved)
        try Data("{\"version\":1,\"entries\":{\"c\":\"../outside.json\"}}".utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try FileChapterRepository(directory: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
    }

    func testBatchObjectFailureKeepsOldManifestAndRemovesEarlierNewObjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ChapterDocument(chapterID: "original", paragraphs: ["已提交正文"])
        let valid = try FileChapterRepository(directory: root)
        try await valid.save(original)
        let failing = try FileChapterRepository(directory: root, writer: RejectSecondChapter())
        do {
            try await failing.saveBatch([.init(chapterID: "first-new", paragraphs: ["第一份新正文"]), .init(chapterID: "second-new", paragraphs: ["失败正文"])])
            XCTFail("Second object must fail the complete batch")
        } catch {}
        let reopened = try FileChapterRepository(directory: root)
        let ids = await reopened.chapterIDs()
        let preserved = try await reopened.document(chapterID: "original")
        XCTAssertEqual(ids, ["original"])
        XCTAssertEqual(preserved, original)
        let objects = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: nil)
        XCTAssertEqual(objects.count, 1)
    }

    func testBatchDuplicateChapterIsRejectedBeforeChangingAnyContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileChapterRepository(directory: root)
        do { try await repository.saveBatch([.init(chapterID: "same", paragraphs: ["一"]), .init(chapterID: "same", paragraphs: ["二"])]); XCTFail("Duplicate chapter") }
        catch { XCTAssertEqual(error as? ContentFailure, .invalidResponse) }
        let ids = await repository.chapterIDs()
        XCTAssertTrue(ids.isEmpty)
    }
}
