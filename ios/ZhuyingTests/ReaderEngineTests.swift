import XCTest
import UIKit
@testable import Zhuying

@MainActor
final class ReaderEngineTests: XCTestCase {
    private var book: Book { try! Book.load(bundle: Bundle(for: LibraryStore.self))[0] }
    private var oversizedTitleBook: Book {
        Book(id: "title-block-test", title: "标题测试", author: "作者", genre: "测试", category: "小说", status: "完结",
             words: "100", color: "green", subtitle: "", intro: "", tags: [],
             chapters: ["这是一个足以跨越多页的章节标题用于回归测试阅读位置"], content: [["第一段正文。", "第二段正文。"]])
    }

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

    func testPageStartingInsideOversizedTitleRestoresTheSamePage() {
        var settings = ReadingSettings(fontSize: 18, lineSpacing: 8)
        settings.preferences.titleCSS = ".chapter-title{font-size:48px;padding-top:60px;padding-bottom:60px;letter-spacing:8px}"
        let size = CGSize(width: 180, height: 200)
        let document = ReaderDocument(book: oversizedTitleBook, chapter: 0, settings: settings)
        let ranges = ReaderPaginator.ranges(document: document, size: size)
        let firstParagraph = document.paragraphRanges[0].location
        let titlePages = ranges.indices.filter { ranges[$0].location < firstParagraph }
        XCTAssertGreaterThan(titlePages.count, 1, "The title and attribution block must span more than one page")

        for page in titlePages {
            let anchor = document.anchor(at: ranges[page].location)
            XCTAssertEqual(anchor.paragraph, 0)
            XCTAssertLessThan(anchor.offset, 0, "A title-block page keeps a pre-paragraph offset")
            XCTAssertEqual(document.index(for: anchor), ranges[page].location, "Anchor must round-trip the page start exactly")
            XCTAssertEqual(ReaderPaginator.page(containing: anchor, document: document, ranges: ranges), page)
        }
        XCTAssertEqual(ReaderPaginator.page(containing: .init(), document: document, ranges: ranges), 0)

        // Rebuilding the same document is the path used after rotation and settings restore.
        let reflowed = ReaderDocument(book: oversizedTitleBook, chapter: 0, settings: settings)
        let reflowedRanges = ReaderPaginator.ranges(document: reflowed, size: size)
        XCTAssertEqual(reflowedRanges, ranges)
        for page in titlePages {
            let saved = document.anchor(at: ranges[page].location)
            XCTAssertEqual(ReaderPaginator.page(containing: saved, document: reflowed, ranges: reflowedRanges), page)
        }
    }

    func testNormalChapterPageStartsStillRoundTripThroughAnchors() {
        let document = ReaderDocument(book: book, chapter: 2, settings: .init(fontSize: 20))
        let ranges = ReaderPaginator.ranges(document: document, size: CGSize(width: 310, height: 430))
        XCTAssertGreaterThan(ranges.count, 2)
        for (page, range) in ranges.enumerated() {
            let anchor = document.anchor(at: range.location)
            XCTAssertEqual(document.index(for: anchor), range.location)
            XCTAssertEqual(ReaderPaginator.page(containing: anchor, document: document, ranges: ranges), page)
        }
        let paragraphAnchor = ReaderAnchor(paragraph: 3, offset: 5)
        XCTAssertEqual(document.anchor(at: document.index(for: paragraphAnchor)), paragraphAnchor)
        XCTAssertGreaterThanOrEqual(document.anchor(at: document.paragraphRanges[3].location).offset, 0)
    }
}
