import XCTest
import UIKit
@testable import Zhuying

@MainActor
final class ReaderRenderingPreferencesTests: XCTestCase {
    private func book(_ paragraphs: [String]) -> Book {
        Book(id: "rendering-test", title: "排版测试", author: "作者", genre: "测试", category: "小说", status: "完结", words: "100", color: "green",
             subtitle: "", intro: "", tags: [], chapters: ["章首"], content: [paragraphs])
    }

    func testNativeBodyAndHeadingUseTheSamePreferencesAsEditor() throws {
        var settings = ReadingSettings(fontSize: 23, lineSpacing: 17)
        settings.preferences.paragraphSpacing = 31
        settings.preferences.firstLineIndent = false
        settings.preferences.fontName = "__serif__"
        settings.preferences.colors = ReaderColors(background: 0xE7EEEA, ink: 0x365449, accent: 0x637C69, name: "远山")
        settings.preferences.titleCSS = ".chapter-title{font-size:32px;text-align:right;color:#654321;letter-spacing:3px;padding-bottom:24px;border-bottom:1px solid #654321}"
        let document = ReaderDocument(book: book(["第一段文字。", "第二段文字。"]), chapter: 0, settings: settings)
        let bodyIndex = document.paragraphRanges[0].location
        let body = try XCTUnwrap(document.text.attribute(.paragraphStyle, at: bodyIndex, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(body.lineSpacing, 17)
        XCTAssertEqual(body.paragraphSpacing, 31)
        XCTAssertEqual(body.firstLineHeadIndent, 0)
        XCTAssertEqual((document.text.attribute(.font, at: bodyIndex, effectiveRange: nil) as? UIFont)?.pointSize, 23)
        let heading = try XCTUnwrap(document.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(heading.alignment, .right)
        XCTAssertEqual(heading.paragraphSpacing, 24)
        XCTAssertEqual((document.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 32)
        XCTAssertEqual(document.text.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(document.text.attribute(.foregroundColor, at: bodyIndex, effectiveRange: nil) as? UIColor, UIColor(readerHex: 0x365449))
    }

    func testStableFurnitureRegionsAndAsymmetricMarginsReserveActualBodySpace() {
        var settings = ReadingSettings()
        settings.preferences.leftMargin = 36; settings.preferences.rightMargin = 12
        settings.preferences.headerEnabled = true; settings.preferences.footerEnabled = true
        settings.preferences.headerHeight = 64; settings.preferences.headerGap = 12
        settings.preferences.footerHeight = 72; settings.preferences.footerGap = 16
        let layout = ReaderLayout(settings: settings, size: CGSize(width: 390, height: 700))
        XCTAssertEqual(layout.textFrame.minX, 36)
        XCTAssertEqual(layout.textFrame.width, 342)
        XCTAssertEqual(layout.textFrame.minY, 24 + 64 + 12)
        XCTAssertEqual(layout.footerFrame.minY - layout.textFrame.maxY, 16)
        XCTAssertEqual(layout.scrollFrame.minY, 76)
        let tiny = ReaderLayout(settings: settings, size: CGSize(width: 120, height: 160))
        XCTAssertGreaterThanOrEqual(tiny.textFrame.width, 40)
        XCTAssertGreaterThanOrEqual(tiny.textFrame.height, 40)
        XCTAssertGreaterThanOrEqual(tiny.headerFrame.minY, 0)
        XCTAssertLessThanOrEqual(tiny.footerFrame.maxY, 160)
    }

    func testRulePriorityAndUnicodeAnchorsSurviveCommentAttachmentsAndReflow() throws {
        let paragraphs = ["她说：「你好，🌿山海。」", "第二段包含更多正文，不应被评论挤乱索引。"]
        var settings = ReadingSettings()
        settings.preferences.rules = [
            ReaderStyleRule(name: "对话", color: 0xA12345, enabled: true),
            ReaderStyleRule(name: "后续同类", match: "关键词", pattern: "山海", color: 0x112233, enabled: true)
        ]
        settings.preferences.showCommentBubbles = true
        settings.preferences.showGodComments = true
        let document = ReaderDocument(book: book(paragraphs), chapter: 0, settings: settings)
        for (index, paragraph) in paragraphs.enumerated() {
            let range = document.paragraphRanges[index]
            XCTAssertEqual(document.text.attributedSubstring(from: range).string, paragraph)
            let expected = ReaderAnchor(paragraph: index, offset: 3)
            XCTAssertEqual(document.anchor(at: document.index(for: expected)), expected)
        }
        let mountain = (document.text.string as NSString).range(of: "山海", options: [], range: document.paragraphRanges[0])
        XCTAssertEqual(document.text.attribute(.foregroundColor, at: mountain.location, effectiveRange: nil) as? UIColor, UIColor(readerHex: 0xA12345))
        var attachments = 0
        document.text.enumerateAttribute(.readerCommentParagraph, in: NSRange(location: 0, length: document.text.length)) { value, range, _ in
            if let paragraph = value as? Int {
                attachments += 1
                XCTAssertEqual(document.anchor(at: range.location).paragraph, paragraph)
            }
        }
        XCTAssertEqual(attachments, paragraphs.count * 2)
        let pages = ReaderPaginator.ranges(document: document, size: CGSize(width: 260, height: 230))
        XCTAssertFalse(pages.isEmpty)
        XCTAssertEqual(pages.reduce(0) { $0 + $1.length }, document.text.length)
    }

    func testCommentsAreOnlyHitInsideTheirRenderedAttachment() throws {
        var settings = ReadingSettings()
        settings.preferences.showCommentBubbles = true
        let document = ReaderDocument(book: book(["短短一段。"]), chapter: 0, settings: settings)
        let storage = NSTextStorage(attributedString: document.text), manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let size = CGSize(width: 300, height: 600)
        let container = NSTextContainer(size: size); container.lineFragmentPadding = 0
        manager.addTextContainer(container); manager.ensureLayout(for: container)
        var badge: NSRange?
        document.text.enumerateAttribute(.readerCommentParagraph, in: NSRange(location: 0, length: document.text.length)) { value, range, _ in if value != nil { badge = range } }
        let range = try XCTUnwrap(badge)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertEqual(ReaderDocument.comment(at: CGPoint(x: rect.midX, y: rect.midY), text: document.text, size: size), 0)
        XCTAssertNil(ReaderDocument.comment(at: CGPoint(x: 299, y: 599), text: document.text, size: size))
    }
    func testCommentAttachmentShrinksWithNarrowTextWithoutChangingItsCharacterIdentity() {
        let attachment = ReaderResponsiveCommentAttachment()
        attachment.bounds = CGRect(x: 0, y: -2, width: 180, height: 47)
        let actual = attachment.attachmentBounds(for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 100, height: 400), glyphPosition: .zero, characterIndex: 0)
        XCTAssertEqual(actual.width, 100)
        XCTAssertEqual(actual.height, 47 * 100 / 180, accuracy: 0.001)
        XCTAssertEqual(actual.minY, -2)
    }

    func testChapterStartRuleDoesNotApplyToEveryParagraphAndArtIsCachedByCustomStyle() {
        var settings = ReadingSettings()
        settings.preferences.rules = [ReaderStyleRule(name: "章首", match: "章节首段", color: 0xFF0000, enabled: true)]
        let document = ReaderDocument(book: book(["第一段。", "第二段。"]), chapter: 0, settings: settings)
        XCTAssertEqual(document.text.attribute(.foregroundColor, at: document.paragraphRanges[0].location, effectiveRange: nil) as? UIColor, UIColor(readerHex: 0xFF0000))
        XCTAssertNotEqual(document.text.attribute(.foregroundColor, at: document.paragraphRanges[1].location, effectiveRange: nil) as? UIColor, UIColor(readerHex: 0xFF0000))
        let first = ReaderCommentArtwork.bubble(settings: settings)
        XCTAssertTrue(first === ReaderCommentArtwork.bubble(settings: settings))
        settings.preferences.bubbleFollowsTheme = false
        settings.preferences.bubbleStyle = "自定义"
        settings.preferences.bubbleColor = 0
        XCTAssertFalse(first === ReaderCommentArtwork.bubble(settings: settings))
    }

    func testChapterStartKeepsLargeCustomTitleVisibleInsteadOfSkippingToBody() {
        var settings = ReadingSettings()
        settings.preferences.titleCSS = ".chapter-title{font-size:48px;padding-top:60px;padding-bottom:60px;letter-spacing:8px}"
        let document = ReaderDocument(book: book(["第一段正文不应让章首被跳过。"]), chapter: 0, settings: settings)
        let ranges = ReaderPaginator.ranges(document: document, size: CGSize(width: 180, height: 160))
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ReaderPaginator.page(containing: .init(), document: document, ranges: ranges), 0)
    }

}
