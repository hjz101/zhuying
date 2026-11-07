import XCTest
import UIKit
@testable import Zhuying

final class LegadoReaderContentTests: XCTestCase {
    private let origin = URL(string: "https://comments.fixture.test")!
    private func parse(_ html: String) throws -> LegadoReaderContent {
        try LegadoReaderContent.parse(html, baseURL: origin, allowedOrigins: [origin])
    }
    private func image(_ labels: [String], style: String, action: String) throws -> String {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'>" + labels.map { "<text>\($0)</text>" }.joined() + "</svg>"
        let metadata = try JSONSerialization.data(withJSONObject: ["style": style, "click": action], options: .sortedKeys)
        return "<img src=\"data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString() + "," + String(decoding: metadata, as: UTF8.self) + "\">"
    }
    func testIOSParagraphCountsAndGodCardsStayOutOfProseAndHaveWorkingTargets() throws {
        let god = try image(["神评论", "这一段的伏笔很巧妙。"], style: "FULL", action: "showCmt('https://comments.fixture.test/paragraph?para=1','段评')")
        let result = try parse("<div rs-native>原创第一段🌿<comment count='42' onPress=\"java.showReadingBrowser('https://comments.fixture.test/paragraph?para=1&amp;sort=hot','段评')\"></div>" + god + "<div rs-native>原创第二段</div>")
        XCTAssertEqual(result.paragraphs, ["原创第一段🌿", "原创第二段"])
        XCTAssertEqual(result.comments[0]?.count, 42)
        XCTAssertEqual(result.comments[0]?.hotComment?.text, "这一段的伏笔很巧妙。")
        XCTAssertEqual(result.comments[0]?.url?.path, "/paragraph")
        XCTAssertNil(result.comments[1])
    }
    func testAndroidImageBubbleAndRawNoteProtocolsMapToTheirOwnParagraphs() throws {
        let bubble = try image(["99+"], style: "text", action: "showCmt('https://comments.fixture.test/paragraph?para=2', '番茄', '段评')")
        let result = try parse("<p>第一段<comment ident='/paragraph?para=1' count='3' /></p><p>第二段\(bubble)</p><note ident='/paragraph?para=2' text='源返回的神评 &amp; 原文'></note>")
        XCTAssertEqual(result.paragraphs, ["第一段", "第二段"])
        XCTAssertEqual(result.comments[0]?.count, 3)
        XCTAssertEqual(result.comments[1]?.count, 99)
        XCTAssertEqual(result.comments[1]?.hotComment?.text, "源返回的神评 & 原文")
        XCTAssertEqual(result.comments[1]?.url?.query, "para=2")
    }
    func testUntrustedActionsAndChapterDiscussionsCannotBecomeParagraphNavigation() throws {
        let chapter = try image(["本章说", "另一个讨论"], style: "FULL", action: "showFanqieComment('https://comments.fixture.test/chapter','本章说')")
        let result = try parse("<script>doNotShow()</script><p>正文<comment count='7' ident='https://other.fixture.test/steal'/></p>\(chapter)<p>续文<note text='文字内容' ident='https://account:secret@comments.fixture.test/p'/></p>")
        XCTAssertEqual(result.paragraphs, ["正文", "续文"])
        XCTAssertNil(result.comments[0]?.url)
        XCTAssertNil(result.comments[0]?.hotComment)
        XCTAssertNil(result.comments[1]?.url)
        XCTAssertNil(LegadoReaderContent.actionURL("evil('https://comments.fixture.test/p')"))
        XCTAssertNil(LegadoReaderContent.actionURL("run();showCmt('https://comments.fixture.test/p')"))
        XCTAssertEqual(LegadoReaderContent.actionURL(#"showCmt('https:\/\/comments.fixture.test\/p','段评')"#), "https://comments.fixture.test/p")
    }
    func testOldCacheDecodesAndCommentMetadataDoesNotChangeProseIdentity() throws {
        let old = ChapterDocument(chapterID: "one", paragraphs: ["相同正文"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "sourceComments")
        let decoded = try JSONDecoder().decode(ChapterDocument.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sourceComments)
        let annotated = ChapterDocument(chapterID: "one", paragraphs: ["相同正文"], sourceComments: [0: .init(count: 4, url: origin)])
        XCTAssertEqual(old.version, annotated.version)
        XCTAssertEqual(old.paragraphs, annotated.paragraphs)
        XCTAssertEqual(try JSONDecoder().decode(ChapterDocument.self, from: JSONEncoder().encode(annotated)), annotated)
    }
    func testRemoteGodSVGUsesOnlyDeclaredSourceAndDoesNotRunSVGCode() throws {
        var requests: [URL] = []
        let html = #"<p>正文。</p><img src="https://comments.fixture.test/god.svg,{"style":"FULL","js":"showCmt('https://comments.fixture.test/p','段评')"}"><img src="https://other.fixture.test/blocked.svg,{"style":"FULL","js":"showCmt('https://comments.fixture.test/p','段评')"}">"#
        let parsed = try LegadoReaderContent.parse(html, baseURL: origin, allowedOrigins: [origin]) { url in
            requests.append(url)
            return "<svg><script>neverExecute()</script><text>神评论</text><text>服务器返回的原创神评</text></svg>"
        }
        XCTAssertEqual(requests.map(\.path), ["/god.svg"])
        XCTAssertEqual(parsed.paragraphs, ["正文。"])
        XCTAssertEqual(parsed.comments[0]?.hotComment?.text, "服务器返回的原创神评")
    }
    func testPurificationKeepsOnlyAnnotationsWhoseOriginalParagraphSurvives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let processing = ContentProcessingStore(directory: directory, previewRules: [ContentProcessingRule(name: "删除广告", pattern: "^广告$", enabled: true)])
        let raw = ChapterDocument(chapterID: "chapter", paragraphs: ["首段", "广告", "末段"], sourceComments: [0: .init(count: 2), 1: .init(count: 8), 2: .init(count: 5)])
        let result = try await processing.process(raw, bookID: "book", sourceID: "source")
        XCTAssertEqual(result.document.paragraphs.map(\.text), ["首段", "末段"])
        XCTAssertEqual(result.document.sourceComments?.count, 2)
        XCTAssertEqual(result.document.sourceComments?[result.document.paragraphs[1].id]?.count, 5)
    }
    func testImportedAnnotationsRenderClickableBubblesAndGodCommentsWithoutDemoData() throws {
        let parsed = try parse("<p>原文🌿<comment ident='/p' count='12'/></p><note text='真实来源文字' ident='/p'/>")
        let book = Book(id: "remote-original-comments", title: "原创评论测试", author: "竹影", genre: "小说", category: "小说", status: "完结", words: "", color: "#667766", subtitle: "", intro: "", tags: [], chapters: ["第一章"], content: [])
        var settings = ReadingSettings()
        settings.preferences.showCommentBubbles = true; settings.preferences.showGodComments = true
        let document = ReaderDocument(book: book, chapter: 0, settings: settings, paragraphs: parsed.paragraphs, isDemo: false, commentCounts: [0: parsed.comments[0]!.count], hotComments: [0: parsed.comments[0]!.hotComment!])
        var ranges: [NSRange] = []
        document.text.enumerateAttribute(.readerCommentParagraph, in: NSRange(location: 0, length: document.text.length)) { value, range, _ in if value != nil { ranges.append(range) } }
        XCTAssertEqual(ranges.count, 2)
        for range in ranges { XCTAssertEqual(document.anchor(at: range.location).paragraph, 0) }
        XCTAssertEqual(document.text.attributedSubstring(from: document.paragraphRanges[0]).string, "原文🌿")
    }
}
