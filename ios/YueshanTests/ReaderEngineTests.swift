import XCTest
import UIKit
@testable import Yueshan

@MainActor
final class ReaderEngineTests: XCTestCase {
    private var book: Book { try! Book.load(bundle: Bundle(for: LibraryStore.self))[0] }

    func testPaginationCoversEveryCharacterWithoutOverlapAcrossLayouts() {
        for size in [CGSize(width: 310, height: 430), CGSize(width: 352, height: 550), CGSize(width: 740, height: 180)] {
            for font in [16.0, 20, 24] {
                let document = ReaderDocument(book: book, chapter: 2, settings: .init(fontSize: font, lineSpacing: 18))
                let ranges = ReaderPaginator.ranges(document: document, size: size)
                XCTAssertGreaterThan(ranges.count, 1)
                var end = 0
                for range in ranges {
                    XCTAssertEqual(range.location, end)
                    XCTAssertGreaterThan(range.length, 0)
                    end = NSMaxRange(range)
                    let page = document.pageText(in: range)
                    let storage = NSTextStorage(attributedString: page)
                    let manager = NSLayoutManager()
                    storage.addLayoutManager(manager)
                    let container = NSTextContainer(size: size)
                    container.lineFragmentPadding = 0
                    manager.addTextContainer(container)
                    manager.ensureLayout(for: container)
                    let visible = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
                    XCTAssertEqual(NSMaxRange(visible), page.length, "A rendered page must fit every character it was assigned")
                }
                XCTAssertEqual(end, document.text.length)
                let reconstructed = ranges.map { document.text.attributedSubstring(from: $0).string }.joined()
                XCTAssertEqual(reconstructed, document.text.string)
            }
        }
    }

    func testSemanticAnchorSurvivesFontAndOrientationChanges() {
        let anchor = ReaderAnchor(paragraph: 7, offset: 13)
        for size in [CGSize(width: 310, height: 430), CGSize(width: 740, height: 180)] {
            for font in [16.0, 24] {
                let document = ReaderDocument(book: book, chapter: 2, settings: .init(fontSize: font))
                XCTAssertEqual(document.anchor(at: document.index(for: anchor)), anchor)
                let ranges = ReaderPaginator.ranges(document: document, size: size)
                let page = ReaderPaginator.page(containing: anchor, document: document, ranges: ranges)
                XCTAssertTrue(NSLocationInRange(document.index(for: anchor), ranges[page]))
            }
        }
    }

    func testSmallLayoutIsSafeAndAnchorIsClamped() {
        let document = ReaderDocument(book: book, chapter: 0, settings: .init())
        XCTAssertTrue(ReaderPaginator.ranges(document: document, size: .zero).isEmpty)
        XCTAssertEqual(document.anchor(at: -10), ReaderAnchor())
        let index = document.index(for: .init(paragraph: 999, offset: 99999))
        XCTAssertLessThan(index, document.text.length)
    }

    func testBothEdgesAdvanceAndCenterControlsMenu() {
        var settings = ReadingSettings()
        XCTAssertEqual(ReaderInteraction.action(at: 0.95, settings: settings), .controls)
        settings.tapToTurn = true
        XCTAssertEqual(ReaderInteraction.action(at: 0.5, settings: settings), .controls)
        XCTAssertEqual(ReaderInteraction.action(at: 0.95, settings: settings), .next)
        XCTAssertEqual(ReaderInteraction.action(at: 0.05, settings: settings), .next)
        XCTAssertEqual(ReaderInteraction.action(at: 0.05, settings: settings), .next)
        XCTAssertEqual(ReaderInteraction.action(at: 0.95, settings: settings), .next)
    }
    func testProductionUsesActualChapterProseWithoutDemoCommentsAndKeepsUnicodeOffsetsSafe() {
        let text = "甲👩🏽‍🚀乙与真实正文。"
        let document = ReaderDocument(book: book, chapter: 0, settings: .init(), paragraphs: [text], isDemo: false)
        XCTAssertEqual(document.paragraphRanges.count, 1)
        XCTAssertEqual(document.text.attributedSubstring(from: document.paragraphRanges[0]).string, text)
        XCTAssertFalse(document.text.string.contains("原创示例"))
        XCTAssertFalse(document.text.string.contains("\u{FFFC}"), "Production prose must not contain synthetic comment attachments")
        let index = document.index(for: .init(paragraph: 0, offset: 4))
        XCTAssertEqual(document.anchor(at: index), .init(paragraph: 0, offset: 1))
    }
    func testLongUnicodeParagraphsCrossWindowAndPageBoundariesWithoutTruncation() {
        let text = String(repeating: "甲👩🏽‍🚀乙e\u{301}丙，文字连续。", count: 450)
        let document = ReaderDocument(book: book, chapter: 0, settings: .init(), paragraphs: [text], isDemo: false)
        for size in [CGSize(width: 230, height: 240), CGSize(width: 700, height: 200)] {
            let ranges = ReaderPaginator.ranges(document: document, size: size)
            XCTAssertGreaterThan(ranges.count, 3)
            XCTAssertEqual(ranges.map { document.pageText(in: $0).string }.joined(), document.text.string)
            for range in ranges.dropLast() {
                let end = NSMaxRange(range)
                XCTAssertEqual((document.text.string as NSString).rangeOfComposedCharacterSequence(at: end).location, end)
            }
        }
    }
}
