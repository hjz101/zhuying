import XCTest
@testable import Zhuying

final class LegadoInitializedContentTests: XCTestCase {
    func testJSONSelectedObjectAndScalarTypesRetainStructuredInputForFollowingFields() throws {
        let context = LegadoRuleContext(), engine = LegadoRuleEngine(context:context)
        for value in [#"{"abstract":"保留简介","name":"书籍"}"#, "42", "false", "null"] {
            let initialized = try engine.initializedContent("$.data",in:"{\"data\":" + value + "}")
            XCTAssertTrue(initialized.structured)
            let expected = try JSONSerialization.jsonObject(with:Data(value.utf8),options:.fragmentsAllowed)
            context.structuredInput = initialized.structured
            context.evaluateJS = { _,bindings in
                let input = try XCTUnwrap(bindings["result"])
                XCTAssertEqual(try JSONSerialization.data(withJSONObject:input,options:[.fragmentsAllowed,.sortedKeys]),try JSONSerialization.data(withJSONObject:expected,options:[.fragmentsAllowed,.sortedKeys]))
                return "kept"
            }
            XCTAssertEqual(try engine.text("@js:result",in:initialized.text),"kept")
        }
    }

    func testStringsThatLookLikeJSONRemainStringsRatherThanBeingGuessedIntoObjects() throws {
        let context = LegadoRuleContext(), engine = LegadoRuleEngine(context:context)
        let json = #"{"abstract":"原样字符串"}"#
        context.evaluateJS = { _,_ in json }
        let fromJS = try engine.initializedContent("@js:fixture",in:"input")
        XCTAssertEqual(fromJS.text,json); XCTAssertFalse(fromJS.structured)
        let fromJSON = try engine.initializedContent("$.data",in:String(decoding:JSONSerialization.data(withJSONObject:["data":json]),as:UTF8.self))
        XCTAssertEqual(fromJSON.text,json); XCTAssertFalse(fromJSON.structured)
        context.structuredInput = fromJS.structured
        context.evaluateJS = { _,bindings in XCTAssertEqual(bindings["result"] as? String,json); return "string" }
        XCTAssertEqual(try engine.text("@js:typeof result",in:fromJS.text),"string")
    }

    func testOnlyFirstElementBecomesInitializedContentAndNoMatchHasNoStructuredValue() throws {
        let engine = LegadoRuleEngine()
        let initialized = try engine.initializedContent("$.data",in:#"{"data":[{"abstract":"第一本"},{"abstract":"第二本"}]}"#)
        XCTAssertTrue(initialized.structured)
        XCTAssertEqual(try engine.text("$.abstract",in:initialized.text),"第一本")
        let none = try engine.initializedContent(".missing",in:"<p>正文</p>")
        XCTAssertEqual(none.text,""); XCTAssertFalse(none.structured)
        let html = try engine.initializedContent("tag.p",in:"<p>第一项</p><p>第二项</p>")
        XCTAssertFalse(html.structured); XCTAssertTrue(html.text.contains("第一项")); XCTAssertFalse(html.text.contains("第二项"))
    }

    func testJavaScriptObjectsAndSequentialTransformsPreserveTheirActualCompletionType() throws {
        let context = LegadoRuleContext(), engine = LegadoRuleEngine(context:context)
        context.evaluateJS = { script,bindings in
            switch script {
            case "makeObject": return ["abstract":"简介"]
            case "readObject": XCTAssertEqual((bindings["result"] as? [String:String])?["abstract"],"简介"); return ["abstract":"下一步"]
            case "makeNumber": return 7
            default: return true
            }
        }
        let object = try engine.initializedContent("<js>makeObject</js><js>readObject</js>",in:"")
        XCTAssertTrue(object.structured)
        XCTAssertEqual(try engine.text("$.abstract",in:object.text),"下一步")
        let number = try engine.initializedContent("@js:makeNumber",in:"")
        XCTAssertEqual(number.text,"7"); XCTAssertTrue(number.structured)
        let boolean = try engine.initializedContent("@js:makeBoolean",in:"")
        XCTAssertEqual(boolean.text,"true"); XCTAssertTrue(boolean.structured)
        // A response body stays a string until an explicit JSON selector
        // produces the object used by the subsequent detail fields.
        context.evaluateJS = { _,_ in #"{"data":{"abstract":"从响应选出的对象"}}"# }
        let selected = try engine.initializedContent("<js>makeResponse</js>$.data",in:"inline hex")
        XCTAssertTrue(selected.structured)
        XCTAssertEqual(try engine.text("$.abstract",in:selected.text),"从响应选出的对象")
        context.evaluateJS = { _,_ in ["abstract":"简介"] }
        let replaced = try engine.initializedContent("<js>makeObject</js>##简介##替换",in:"")
        XCTAssertFalse(replaced.structured)
        XCTAssertEqual(try engine.text("$.abstract",in:replaced.text),"替换")
    }

    func testRegexAndTextProjectionProduceStringsEvenWhenTheirTextContainsJSON() throws {
        let engine = LegadoRuleEngine()
        let replaced = try engine.initializedContent("$.data##简介##替换",in:#"{"data":{"abstract":"简介"}}"#)
        XCTAssertFalse(replaced.structured)
        XCTAssertEqual(try engine.text("$.abstract",in:replaced.text),"替换")
        let text = try engine.initializedContent("tag.p@text",in:#"<p>{"abstract":"文本"}</p>"#)
        XCTAssertFalse(text.structured)
        XCTAssertEqual(text.text,#"{"abstract":"文本"}"#)
    }

    func testTypedInitializationStillEnforcesAllElementAndByteBounds() throws {
        let context = LegadoRuleContext(), engine = LegadoRuleEngine(context:context)
        context.evaluateJS = { _,_ in Array(repeating:["abstract":"简介"],count:2001) }
        XCTAssertThrowsError(try engine.initializedContent("@js:large",in:""))
        context.evaluateJS = { _,_ in ["abstract":String(repeating:"字",count:800000)] }
        XCTAssertThrowsError(try engine.initializedContent("@js:large",in:""))
        context.evaluateJS = { script,_ in
            if script == "large" { return ["abstract":String(repeating:"x",count:2 * 1024 * 1024 + 1)] }
            return "small"
        }
        XCTAssertThrowsError(try engine.initializedContent("<js>large</js><js>small</js>",in:""))
    }
}
