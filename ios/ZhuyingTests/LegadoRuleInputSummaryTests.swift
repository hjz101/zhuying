import XCTest
@testable import Zhuying

final class LegadoRuleInputSummaryTests: XCTestCase {
    func testFixedFieldsDistinguishMissingNullAndEveryJSONTypeWithoutReadingCodeValue() {
        let samples: [(String,LegadoRuleInputSummary.JSONType)] = [
            ("null",.null),("true",.boolean),("false",.boolean),("0",.number),("1",.number),
            ("1.25",.number),(#""private text""#,.string),("[]",.array),("{}",.object)
        ]
        for (json,type) in samples {
            let summary = LegadoRuleInputSummary.from("{\"abstract\":" + json + ",\"data\":" + json + ",\"code\":" + json + "}")
            XCTAssertEqual(summary.root,.object)
            XCTAssertEqual(summary.abstract,type)
            XCTAssertEqual(summary.data,type)
            XCTAssertTrue(summary.hasCode)
        }
        let missing = LegadoRuleInputSummary.from(#"{"other":"private"}"#)
        XCTAssertEqual(missing.abstract,.missing); XCTAssertEqual(missing.data,.missing); XCTAssertFalse(missing.hasCode)
    }

    func testRootFragmentsAndInvalidInputHaveUnambiguousFixedClassification() {
        for (json,type) in [("null",LegadoRuleInputSummary.JSONType.null),("true",.boolean),("1",.number),(#""text""#,.string),("[]",.array)] {
            let summary = LegadoRuleInputSummary.from(json)
            XCTAssertEqual(summary.root,type)
            XCTAssertEqual(summary.abstract,.missing)
        }
        for text in ["", "not JSON", "{}\n{}", String(repeating:" ",count:2 * 1024 * 1024 + 1)] {
            XCTAssertEqual(LegadoRuleInputSummary.from(text),.init(root:.invalid,abstract:.missing,data:.missing,hasCode:false))
        }
    }

    func testEncodingContainsOnlyFixedTypesAndPresenceFlagsAndDoesNotTraverseNestedPayload() throws {
        let input = #"{"abstract":"private-abstract","data":{"abstract":"nested-private","private-dynamic-key":"private-token"},"code":"private-status","private-top-key":"private-body"}"#
        let summary = LegadoRuleInputSummary.from(input)
        XCTAssertEqual(summary,.init(root:.object,abstract:.string,data:.object,hasCode:true))
        let bytes = try JSONEncoder().encode(summary), object = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual(Set(object.keys),["root","abstract","data","hasCode"])
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("private"))
        XCTAssertEqual(try JSONDecoder().decode(LegadoRuleInputSummary.self,from:bytes),summary)
    }
}
