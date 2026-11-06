import XCTest
@testable import Zhuying

final class LegadoSourceDefinitionTests: XCTestCase {
    private func row() -> [String: Any] {
        ["bookSourceName": "竹影原创规则", "bookSourceUrl": "https://SOURCE.test/api", "searchUrl": "/search?q={{key}}",
         "jsLib": "function original(value) { return value; }", "header": "{\"User-Agent\":\"Zhuying\"}",
         "ruleSearch": ["bookList": "class.book", "name": "tag.a@text", "bookUrl": "tag.a@href"],
         "ruleToc": ["chapterList": "tag.li", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
         "ruleContent": ["content": "id.content@html"]]
    }
    private func definition(_ row: [String: Any]) throws -> LegadoSourceDefinition {
        var source = DemoSource(id: "legado-test", name: "竹影原创规则", detail: "", url: row["bookSourceUrl"] as? String ?? "")
        source.configuration = try JSONSerialization.data(withJSONObject: row)
        return try LegadoSourceDefinition.decode(source)
    }
    func testDecodesOriginalFieldsAndCanonicalOriginWithoutChangingRawRules() throws {
        let value = try definition(row())
        XCTAssertEqual(value.name, "竹影原创规则"); XCTAssertEqual(value.baseURL.absoluteString, "https://source.test/")
        XCTAssertEqual(value.sourceURL, "https://SOURCE.test/api")
        XCTAssertEqual(value.search["bookList"], "class.book")
        XCTAssertEqual(value.content["content"], "id.content@html")
        XCTAssertEqual(value.raw["jsLib"] as? String, "function original(value) { return value; }")
        XCTAssertTrue(value.bookInfo.isEmpty)
    }
    func testOpaqueIdentityNeedsExplicitStaticHTTPSRequestOrigin() throws {
        var value = row(); value["bookSourceUrl"] = "原创规则ID"
        value["searchUrl"] = "https://fixture.test/search?q={{key}}"
        XCTAssertEqual(try definition(value).baseURL.absoluteString, "https://fixture.test/")
        value["searchUrl"] = "<js>source.getVariable()</js>"
        XCTAssertThrowsError(try definition(value))
        value["bookSourceUrl"] = "http://fixture.test"; value["searchUrl"] = "/search"
        XCTAssertThrowsError(try definition(value))
    }
    func testMissingRequiredPipelineFieldsAndWrongTypesCannotBeLabelledRunnable() throws {
        for key in ["searchUrl", "ruleSearch", "ruleToc", "ruleContent"] {
            var value = row(); value.removeValue(forKey: key)
            XCTAssertThrowsError(try definition(value), key)
        }
        var value = row(); value["ruleToc"] = ["chapterList": "li", "chapterName": "a@text"]
        XCTAssertThrowsError(try definition(value))
        value = row(); value["ruleSearch"] = ["bookList": ["unsupported-object"]]
        XCTAssertThrowsError(try definition(value))
        value = row(); value["adapter"] = "json-v1"
        XCTAssertThrowsError(try definition(value))
    }
}
