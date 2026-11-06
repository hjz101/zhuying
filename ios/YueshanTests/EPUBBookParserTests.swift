import XCTest
import UIKit
@testable import Yueshan

final class EPUBBookParserTests: XCTestCase {
    private func bytes(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name + ".epub")
        return try Data(contentsOf: url)
    }
    func testEPUBSpineOverridesManifestOrderAndRetainsMetadataImagesAndUnicode() throws {
        let result = try BookImporter.prepare(data: bytes("reflow-story"), name: "作品.epub").book
        XCTAssertEqual(result.title, "山间来信"); XCTAssertEqual(result.author, "阅山原创测试")
        XCTAssertEqual(result.chapters, ["第一章 来信", "第二章 回声"])
        XCTAssertTrue(result.content[0].contains { $0.contains("👩🏽‍🚀") })
        let image = try XCTUnwrap(result.content[0].first { $0.hasPrefix(ReaderInlineImage.prefix) })
        XCTAssertNotNil(ReaderInlineImage.image(image))
        let rendered = ReaderDocument(book: result, chapter: 0, settings: .init(), isDemo: false)
        XCTAssertFalse(rendered.text.string.contains(ReaderInlineImage.prefix))
        var attachments = 0
        rendered.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.text.length)) { value, _, _ in if value != nil { attachments += 1 } }
        XCTAssertEqual(attachments, 1)
    }
    func testLocalResourcesSurviveFileRepositoryRestartAndStableAnchor() async throws {
        let book = try BookImporter.prepare(data: bytes("reflow-story"), name: "作品.epub").book
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try ProductionLibraryPersistence(directory: root)
        _ = try await backend.bootstrap(legacySnapshot: nil, archiveURL: nil)
        _ = try await backend.importBook(book, group: "EPUB")
        let first = EmbeddedChapterRepository.chapter(book, index: 0)
        let originalValue = try await backend.document(chapterID: first.id)
        let original = try XCTUnwrap(originalValue)
        let anchor = try ReadingAnchor(bookID: book.id, document: original, paragraph: 1, offset: 3)
        let reopened = try ProductionLibraryPersistence(directory: root)
        _ = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
        let restoredValue = try await reopened.document(chapterID: first.id)
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(original, restored); XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: restored), .exact(paragraph: 1, offset: 3))
    }
    func testUnsafePathsEncryptedAndFixedLayoutEPUBAreRejectedWithoutFallbackSuccess() throws {
        for name in ["unsafe-path", "encrypted", "fixed-layout", "missing-resource", "external-entity"] {
            XCTAssertThrowsError(try BookImporter.prepare(data: bytes(name), name: name + ".epub"), name)
        }
        XCTAssertThrowsError(try EPUBBookParser.resolve("../../outside", relativeTo: "OPS/chapter.xhtml"))
        XCTAssertThrowsError(try EPUBBookParser.resolve("https://tracking.example/image.png", relativeTo: "OPS/a.xhtml"))
    }
}
