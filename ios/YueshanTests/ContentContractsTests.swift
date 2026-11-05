import XCTest
@testable import Yueshan

final class ContentContractsTests: XCTestCase {
    func testHexEncodingKeepsExistingSHA256IdentifiersByteForByte() {
        XCTAssertEqual(StableContentID.hex([UInt8(0), 1, 15, 16, 255]), "00010f10ff")
        XCTAssertEqual(StableContentID.version("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testStableIDsDoNotCollideForDelimitedComponentsOrAcrossSources() {
        XCTAssertNotEqual(StableContentID.make("a:b", "c"), StableContentID.make("a", "b:c"))
        XCTAssertNotEqual(StableContentID.make("source-a", "book"), StableContentID.make("source-b", "book"))
        XCTAssertEqual(StableContentID.make("a", "b"), StableContentID.make("a", "b"))
    }
    func testParagraphIDsSurviveInsertionAndKeepIdenticalParagraphsDistinct() {
        let original = ChapterDocument(chapterID: "chapter", paragraphs: ["第一段", "相同段落", "相同段落", "最后一段"])
        let changed = ChapterDocument(chapterID: "chapter", paragraphs: ["新增", "第一段", "相同段落", "相同段落", "最后一段"])
        XCTAssertEqual(Set(original.paragraphs.map(\.id)).count, 4)
        XCTAssertEqual(original.paragraphs.map(\.id), changed.paragraphs.dropFirst().map(\.id))
        XCTAssertNotEqual(original.version, changed.version)
    }
    func testAnchorRestoresAfterParagraphInsertionAndDoesNotSplitUnicode() throws {
        let document = ChapterDocument(chapterID: "c", paragraphs: ["开头", "甲👩🏽‍🚀乙，一个新的段落。"])
        let anchor = try ReadingAnchor(bookID: "b", document: document, paragraph: 1, offset: 4)
        XCTAssertEqual(anchor.utf16Offset, 1)
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: document), .exact(paragraph: 1, offset: 1))
        let updated = ChapterDocument(chapterID: "c", paragraphs: ["插入", "开头", "甲👩🏽‍🚀乙，一个新的段落。"])
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: updated), .recovered(paragraph: 2, offset: 1))
        let restored = try JSONDecoder().decode(ReadingAnchor.self, from: JSONEncoder().encode(anchor))
        XCTAssertEqual(restored, anchor)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(anchor)) as? [String: Any])
        legacy.removeValue(forKey: "paragraphCount")
        let old = try JSONDecoder().decode(ReadingAnchor.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.paragraphCount)
        XCTAssertEqual(ReadingAnchorResolver.resolve(old, in: document), .exact(paragraph: 1, offset: 1))
    }
    func testChangedParagraphUsesUniqueQuoteAndAmbiguousMatchPreservesHistory() throws {
        let text = "这是原来的阅读段落，其中包含需要恢复的文字位置。"
        let document = ChapterDocument(chapterID: "c", paragraphs: [text])
        let anchor = try ReadingAnchor(bookID: "b", document: document, paragraph: 0, offset: 8)
        let updated = ChapterDocument(chapterID: "c", paragraphs: ["前文", "新增前缀：" + text + "，新增后缀。"])
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: updated), .recovered(paragraph: 1, offset: 8 + ("新增前缀：" as NSString).length))
        let ambiguous = ChapterDocument(chapterID: "c", paragraphs: ["前缀：" + text, "另一个前缀：" + text])
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: ambiguous), .unresolved)
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: .init(chapterID: "deleted", paragraphs: [text])), .missingChapter)
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: .init(chapterID: "c", paragraphs: [])), .unresolved)
    }
    func testInvalidParagraphDoesNotCreateProgress() {
        XCTAssertThrowsError(try ReadingAnchor(bookID: "b", document: .init(chapterID: "c", paragraphs: []), paragraph: 0, offset: 0))
    }
    func testInsertedIdenticalParagraphDoesNotGuessWhichOccurrenceWasRead() throws {
        let old = ChapterDocument(chapterID: "c", paragraphs: ["重复内容", "重复内容"])
        let anchor = try ReadingAnchor(bookID: "b", document: old, paragraph: 1, offset: 2)
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: old), .exact(paragraph: 1, offset: 2))
        let changed = ChapterDocument(chapterID: "c", paragraphs: ["重复内容", "重复内容", "重复内容"])
        XCTAssertEqual(ReadingAnchorResolver.resolve(anchor, in: changed), .unresolved)
    }
}
