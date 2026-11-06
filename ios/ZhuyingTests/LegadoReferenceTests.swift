import XCTest
@testable import Zhuying

final class LegadoReferenceTests: XCTestCase {
    static func inline(type: String = "qingtian", book: String = "book-1", chapter: String? = nil, route: String = "", title: String = "原稿") throws -> LegadoReference {
        var value = ["book_id": book, "sources": "原创来源", "tab": "小说", "url": route, "title": title]
        if let chapter { value["item_id"] = chapter }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try LegadoReference.parse("data:;base64," + bytes.base64EncodedString() + ",{\"type\":\"" + type + "\"}")
    }
    func testFrozenQingtianDescriptorShapeDecodesLosslesslyAndHasStableSemanticIdentity() throws {
        let first = try Self.inline(), routed = try Self.inline(route: "https://new-route.fixture.test/toc", title: "更正书名")
        XCTAssertEqual(try first.stableID(sourceIdentity: "source", role: "book"), try routed.stableID(sourceIdentity: "source", role: "book"))
        XCTAssertEqual(first.descriptor, first.resolvedDescriptor)
        XCTAssertTrue(try XCTUnwrap(first.inlineText).contains("book_id"))
        XCTAssertEqual(first.inlineHex, first.inlineData.map(StableContentID.hex))
        let toc = try Self.inline(type: "qingtian2")
        XCTAssertEqual(try first.stableID(sourceIdentity: "source", role: "book"), try toc.stableID(sourceIdentity: "source", role: "book"))
        let one = try Self.inline(type: "qingtian3", chapter: "one"), two = try Self.inline(type: "qingtian3", chapter: "two")
        XCTAssertNotEqual(try one.stableID(sourceIdentity: "source", role: "chapter"), try two.stableID(sourceIdentity: "source", role: "chapter"))
        XCTAssertTrue(first.isPortableIdentityPayload)
    }
    func testHTTPPreservesPOSTDescriptorAndQueriesWhileKnownCredentialHeadersDoNotChangeIdentity() throws {
        let first = try LegadoReference.parse(#"/chapter?id=1&ticket=old,{"method":"POST","body":"book=原稿","headers":{"Authorization":"Bearer old","Accept":"application/json"}}"#, baseURL: URL(string: "https://fixture.test/books/")!)
        let updated = try LegadoReference.parse(#"/chapter?id=1&ticket=old,{"method":"POST","body":"book=原稿","headers":{"Authorization":"Bearer new","Accept":"application/json"}}"#, baseURL: URL(string: "https://fixture.test/")!)
        XCTAssertEqual(first.requestURL?.absoluteString, "https://fixture.test/chapter?id=1&ticket=old")
        XCTAssertEqual(first.options["body"] as? String, "book=原稿")
        XCTAssertEqual(try first.stableID(sourceIdentity: "source", role: "chapter"), try updated.stableID(sourceIdentity: "source", role: "chapter"))
        let changedQuery = try LegadoReference.parse(first.resolvedDescriptor.replacingOccurrences(of: "ticket=old", with: "ticket=new"))
        XCTAssertNotEqual(try first.stableID(sourceIdentity: "source", role: "chapter"), try changedQuery.stableID(sourceIdentity: "source", role: "chapter"), "Unknown query fields cannot be stripped without evidence")
        XCTAssertFalse(first.isPortableIdentityPayload)
    }
    func testMalformedAndOversizedDataReferencesFailBeforeUse() throws {
        XCTAssertThrowsError(try LegadoReference.parse("data:;base64,not-base64,{\"type\":\"qingtian\"}"))
        XCTAssertThrowsError(try LegadoReference.parse("data:text/plain,unencoded"))
        XCTAssertThrowsError(try LegadoReference.parse("http://fixture.test/book"))
        XCTAssertThrowsError(try LegadoReference.parse("/book/relative"))
        XCTAssertThrowsError(try LegadoReference.parse("data:;base64," + Data(repeating: 65, count: 128 * 1024 + 1).base64EncodedString()))
    }
}
