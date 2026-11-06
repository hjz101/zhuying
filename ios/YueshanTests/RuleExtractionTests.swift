import XCTest
@testable import Yueshan

final class RuleExtractionTests: XCTestCase {
    func testCSSAndXPathUseActualDOMTextHTMLAndAttributes() throws {
        let html = "<!doctype html><html><body><section class='books'><a data-id='b1' href='/b/1'><b>原</b>创 &amp; 山海</a><a data-id='b2'>第二本</a></section></body></html>"
        XCTAssertEqual(try RuleExtraction.extract(.init(kind:.css,expression:"section.books > a",projection:.attribute,attribute:"data-id"),from:html),["b1","b2"])
        XCTAssertEqual(try RuleExtraction.extract(.init(kind:.xpath,expression:"//section/a[1]"),from:html),["原创 & 山海"])
        XCTAssertTrue(try RuleExtraction.extract(.init(kind:.css,expression:"a",projection:.html),from:html)[0].contains("<b>原</b>"))
    }
    func testJSONPathTraversesObjectsListsUnicodeKeysAndScalars() throws {
        let json = #"{"data":{"书籍":[{"title":"原创","count":2},{"title":"山海","count":null}]}}"#
        XCTAssertEqual(try RuleExtraction.extract(.init(kind:.jsonPath,expression:#"$.data["书籍"][*].title"#),from:json),["原创","山海"])
        XCTAssertEqual(try RuleExtraction.extract(.init(kind:.jsonPath,expression:#"$.data["书籍"][1].count"#),from:json),["null"])
        XCTAssertTrue(try RuleExtraction.extract(.init(kind:.jsonPath,expression:"$.missing"),from:json).isEmpty)
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.jsonPath,expression:"$..title"),from:json))
    }
    func testRegexUsesUTF16CapturesAndStopsPathologicalMatching() throws {
        XCTAssertEqual(try RuleExtraction.extract(.init(kind:.regex,expression:"书名：(.*?)。",capture:1),from:"书名：山海😀。书名：原创。"),["山海😀","原创"])
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.regex,expression:"^(a+)+$"),from:String(repeating:"a",count:20000) + "!"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin,2)
    }
    func testVersionEntitiesUnsupportedSyntaxAndOutputLimitsAreRejected() throws {
        XCTAssertThrowsError(try RuleExtraction.extract(.init(version:2,kind:.css,expression:"a"),from:"<a>x</a>"))
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.css,expression:"a:has(b)"),from:"<a>x</a>"))
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.xpath,expression:"document('file:///etc/passwd')"),from:"<a>x</a>"))
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.css,expression:"a"),from:"<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>"))
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.jsonPath,expression:"$[*]"),from:"[" + Array(repeating:"1",count:2001).joined(separator:",") + "]"))
        XCTAssertThrowsError(try RuleExtraction.extract(.init(kind:.regex,expression:".",capture:3),from:"x"))
    }
}
