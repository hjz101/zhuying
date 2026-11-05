import XCTest
import UIKit
import CoreFoundation
import PDFKit
@testable import Yueshan

@MainActor
final class BookImportTests: XCTestCase {
    func testParserRegistryPreservesTextContractAndRejectsEncryptedPDF() throws {
        XCTAssertEqual(Set(BookFormatParsers.parsers.flatMap(\.extensions)), ["txt", "pdf"])
        let parsed = try BookFormatParsers.parse(data: Data("Unicode 👩🏽‍🚀正文".utf8), extension: "TXT", encoding: .automatic)
        XCTAssertEqual(parsed.text, "Unicode 👩🏽‍🚀正文"); XCTAssertEqual(parsed.encoding, "UTF-8")
        XCTAssertThrowsError(try BookFormatParsers.parse(data: Data("unrelated".utf8), extension: "epub", encoding: .automatic))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500))
        let bytes = renderer.pdfData { context in
            context.beginPage()
            ("Encrypted original text." as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        let encrypted = try XCTUnwrap(pdf.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "test-user", PDFDocumentWriteOption.ownerPasswordOption: "test-owner"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: encrypted)).isLocked)
        XCTAssertThrowsError(try BookImporter.prepare(data: encrypted, name: "locked.pdf"))
    }
    private var directory: URL!
    private var defaults: UserDefaults!
    private var domain: String!
    private var library: LibraryStore!
    private let text = "第一章 来信\n这是从文件中导入的真实正文。\n\n第二章 回声\n山谷中的回声来自远方。"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        domain = "yueshan.import.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        library = LibraryStore(books: try Book.load(bundle: Bundle(for: LibraryStore.self)), defaults: defaults,
                               importsURL: directory.appendingPathComponent("archive/books.json"))
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }

    func testTXTUsesActualContentAndRecognizesChapterBoundaries() throws {
        let result = try BookImporter.prepare(data: Data(text.utf8), name: "来信.TXT")
        XCTAssertEqual(result.book.title, "来信")
        XCTAssertEqual(result.book.chapters, ["第一章 来信", "第二章 回声"])
        XCTAssertEqual(result.book.content, [["这是从文件中导入的真实正文。"], ["山谷中的回声来自远方。"]])
        XCTAssertEqual(result.book.chapterTitle(0), "第一章 来信")
        XCTAssertEqual(result.encoding, "UTF-8")
        XCTAssertTrue(result.book.id.hasPrefix("local-"))
        let renamed = try BookImporter.prepare(data: Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8), name: "副本.txt")
        XCTAssertEqual(renamed.book.id, result.book.id)
    }

    func testEncodingAndLongParagraphsRemainReadable() throws {
        let utf16 = try BookImporter.prepare(data: text.data(using: .utf16)!, name: "来信.txt")
        XCTAssertEqual(utf16.encoding, "UTF-16")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let result = try BookImporter.prepare(data: text.data(using: gb)!, name: "来信.txt", encoding: .gb18030)
        XCTAssertEqual(result.book.content, utf16.book.content)
        let long = String(repeating: "山", count: 3100)
        let paragraphs = try BookImporter.prepare(data: Data(long.utf8), name: "长段落.txt").book.content[0]
        XCTAssertEqual(paragraphs.map(\.count), [1200, 1200, 700])
        XCTAssertEqual(paragraphs.joined(), long)
    }

    func testInvalidEmptyUnsupportedAndOversizedFilesDoNotBecomeBooks() {
        for (data, name) in [(Data(), "空.txt"), (Data(" \n".utf8), "空白.txt"), (Data([0, 1, 2, 3]), "二进制.txt"),
                             (Data("fake".utf8), "假.epub"), (Data("fake".utf8), "损坏.pdf"),
                             (Data("第一章 只有标题".utf8), "标题.txt")] {
            XCTAssertThrowsError(try BookImporter.prepare(data: data, name: name))
        }
        XCTAssertThrowsError(try BookImporter.validateSize(BookImporter.maximumBytes + 1))
        XCTAssertThrowsError(try BookImporter.remoteURL("qireader://import"))
        XCTAssertThrowsError(try BookImporter.remoteURL("file:///private/test.txt"))
        XCTAssertThrowsError(try BookImporter.remoteURL("not a url"))
        XCTAssertEqual(try? BookImporter.remoteURL(" https://example.com/book.txt ").host, "example.com")
    }

    func testPDFExtractsActualTextAndRejectsImageOnlyDocument() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("A real PDF paragraph." as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let result = try BookImporter.prepare(data: data, name: "实际文件.pdf")
        XCTAssertTrue(result.book.content.flatMap { $0 }.joined().contains("A real PDF paragraph."))
        XCTAssertEqual(result.encoding, "PDF 文字提取")
        let empty = renderer.pdfData { $0.beginPage() }
        XCTAssertThrowsError(try BookImporter.prepare(data: empty, name: "扫描.pdf"))
    }

    func testLocalFileQueueDuplicatesAndExplicitSelection() async throws {
        let first = directory.appendingPathComponent("来信.txt")
        let copy = directory.appendingPathComponent("副本.txt")
        let second = directory.appendingPathComponent("另一封.txt")
        try Data(text.utf8).write(to: first); try Data(text.utf8).write(to: copy)
        try Data("另一封信，只有这一段正文。".utf8).write(to: second)
        let session = BookImportSession()
        await session.add([.file(first), .file(copy), .file(second)], encoding: .automatic, library: library)
        XCTAssertEqual(session.items.map(\.status), [.ready, .duplicate, .ready])
        XCTAssertEqual(session.readyCount, 2)
        session.selection.remove(session.items[2].id)
        await session.commit(library: library, group: "待读")
        XCTAssertEqual(session.items.map(\.status), [.imported, .duplicate, .ready])
        XCTAssertEqual(library.books.count, 9)
        XCTAssertEqual(library.importedGroups[session.items[0].prepared!.book.id], "待读")
        await session.add([.text(text)], encoding: .automatic, library: library)
        XCTAssertTrue(session.finished, "Adding a duplicate after success must keep the result and shelf action available")
        session.remove(session.items[2].id, library: library)
        XCTAssertEqual(session.items[1].status, .duplicate, "Removing unrelated items must not reactivate an existing library duplicate")
    }

    func testRemovingQueuedOriginalMakesDuplicateSelectableWithoutTouchingLibrary() async {
        let session = BookImportSession()
        await session.add([.text(text), .text(text)], encoding: .automatic, library: library)
        session.remove(session.items[0].id, library: library)
        XCTAssertEqual(session.items.map(\.status), [.ready])
        XCTAssertEqual(session.readyCount, 1)
        XCTAssertEqual(library.favorites.count, 6)
    }

    func testFailedFileRetryAndEmptySelectionDoNotImportFixedDemoBook() async throws {
        let url = directory.appendingPathComponent("稍后可用.txt")
        let session = BookImportSession()
        await session.add([.file(url)], encoding: .automatic, library: library)
        XCTAssertEqual(session.failedCount, 1)
        XCTAssertEqual(session.readyCount, 0)
        await session.commit(library: library, group: "未分组")
        XCTAssertEqual(library.favorites.count, 6)
        try Data(text.utf8).write(to: url)
        await session.retry(encoding: .automatic, library: library)
        XCTAssertEqual(session.failedCount, 0)
        XCTAssertEqual(session.readyCount, 1)
        await session.commit(library: library, group: "未分组")
        XCTAssertTrue(session.summary.contains("成功 1 项"))
        XCTAssertFalse(library.favorites.contains("cloud"))
    }

    func testImportedBookAndProgressSurviveRestartAndRemovingOriginalFile() throws {
        let book = try BookImporter.prepare(data: Data(text.utf8), name: "真实作品.txt").book
        XCTAssertTrue(try library.importBook(book, group: "待读"))
        XCTAssertFalse(try library.importBook(book))
        library.record(book, chapter: 1)
        library.moveImportedBook(book.id, group: "追更中")
        let restored = LibraryStore(books: try Book.load(bundle: Bundle(for: LibraryStore.self)), defaults: defaults,
                                    importsURL: directory.appendingPathComponent("archive/books.json"))
        XCTAssertEqual(restored.books.count, 9)
        XCTAssertEqual(restored.search("真实作品").first?.content, book.content)
        XCTAssertEqual(restored.progress[book.id]?.chapter, 1)
        XCTAssertEqual(restored.importedGroups[book.id], "追更中")
        XCTAssertTrue(restored.isFavorite(book))
        XCTAssertNil(restored.storageMessage)
    }

    func testWriteFailureCannotReportSuccessOrChangeShelf() async throws {
        let badURL = directory.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        let store = LibraryStore(books: library.books, defaults: defaults, importsURL: badURL)
        let session = BookImportSession()
        await session.add([.text(text)], encoding: .automatic, library: store)
        let before = store.favorites
        await session.commit(library: store, group: "未分组")
        XCTAssertEqual(session.failedCount, 1)
        XCTAssertTrue(session.summary.contains("成功 0 项"))
        XCTAssertEqual(store.favorites, before)
        XCTAssertEqual(store.books.count, 8)
    }
}
