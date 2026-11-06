import XCTest
@testable import Zhuying

final class LegadoRuleEngineTests: XCTestCase {
    private let html = """
    <html><body><section id='books'><article class='book' data-note='a||b@c'>
      <a href='/one'><b>山间</b>来信</a><i>作者甲</i><p>第一段<br/>第二行</p></article>
      <article class='book'><a href='/two'>竹下回声</a><i>作者乙</i></article></section></body></html>
    """
    func testDefaultSelectorsIndicesNestedElementsAndTextVersusHTML() throws {
        let engine = LegadoRuleEngine()
        let rows = try engine.elements("id.books@class.book", in: html)
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first)
        XCTAssertTrue(first.contains("data-note"))
        XCTAssertEqual(try engine.text("tag.a@text", in: first), "山间来信")
        XCTAssertEqual(try engine.text("class.book.-1@tag.a@href", in: html), "/two")
        XCTAssertEqual(try engine.list("class.book@tag.a.0@href", in: html), ["/one", "/two"])
        XCTAssertEqual(try engine.text("class.book.0@tag.a@ownText", in: html), "来信")
        XCTAssertEqual(try engine.text("class.book.0@tag.p@text", in: html), "第一段 第二行")
        let fragment = try engine.text("class.book.0@tag.a@html", in: html)
        XCTAssertTrue(fragment.hasPrefix("<b>")); XCTAssertFalse(fragment.contains("<a"))
        XCTAssertEqual(try engine.text("article[data-note='a||b@c']@data-note", in: html), "a||b@c")
        XCTAssertEqual(try engine.list("class.book.0@tag.a@textNodes", in: html), ["来信"])
    }
    func testFallbackConcatenationAndInterleavingKeepPerRuleOrder() throws {
        let engine = LegadoRuleEngine()
        XCTAssertEqual(try engine.list(".missing@text||tag.a@text", in: html), ["山间来信", "竹下回声"])
        XCTAssertEqual(try engine.list("tag.a@text&&tag.i@text", in: html), ["山间来信", "竹下回声", "作者甲", "作者乙"])
        XCTAssertEqual(try engine.list("tag.a@text%%tag.i@text", in: html), ["山间来信", "作者甲", "竹下回声", "作者乙"])
    }
    func testJSONElementsFlattenArrayAndXPathSharesBoundedExtraction() throws {
        let engine = LegadoRuleEngine(), json = #"{"books":[{"name":"山间来信","url":"/one"},{"name":"竹下回声","url":"/two"}]}"#
        let rows = try engine.elements("$.books", in: json)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try engine.text("$.name", in: XCTUnwrap(rows.first)), "山间来信")
        XCTAssertEqual(try engine.list("@Json:$.books[*].url", in: json), ["/one", "/two"])
        XCTAssertEqual(try engine.list("//article/a/@href", in: html), ["/one", "/two"])
        XCTAssertThrowsError(try engine.text("$..name", in: json))
        XCTAssertThrowsError(try engine.text("//article[contains(@class,'book')]", in: html))
    }
    func testRegexReplacementCaptureAndQuotedRegexDoNotBecomeRuleOperators() throws {
        let engine = LegadoRuleEngine()
        XCTAssertEqual(try engine.text("tag.a@text##山间##竹影", in: html), "竹影来信\n竹下回声")
        XCTAssertEqual(try engine.text("class.book.0@tag.a@text##(山间)(来信)##$2·$1", in: html), "来信·山间")
        XCTAssertEqual(try engine.text("@text##['\"]##", in: "<p>一'二\"三</p>"), "一二三")
        XCTAssertEqual(try engine.text("@text##甲|乙##丙", in: "<p>甲和乙</p>"), "丙和丙")
        XCTAssertEqual(try engine.text("@text##(来信)##$1###", in: "<p>山间来信和竹下来信</p>"), "来信")
    }
    func testVariablesPutGetAndTemplateExpressionsUseRequestContext() throws {
        let context = LegadoRuleContext(variables: ["category": "小说"], bindings: ["key": "山间", "page": 2])
        context.evaluateJS = { script, _ in XCTAssertEqual(script, "page + 1"); return 3 }
        let engine = LegadoRuleEngine(context: context)
        XCTAssertEqual(try engine.text(#"@put:{"title":"class.book.0@tag.a@text"}@get:{title}"#, in: html), "山间来信")
        XCTAssertEqual(context.variables["title"], "山间来信")
        XCTAssertEqual(try engine.template("/search?q={{key}}&page={{page + 1}}&kind=@get:{category}"), "/search?q=山间&page=3&kind=小说")
        XCTAssertEqual(try engine.text("{{$.name}}", in: #"{"name":"竹影"}"#), "竹影")
        XCTAssertEqual(try engine.text("{{@get:{title}}}", in: ""), "山间来信")
    }
    func testScriptMarkersAndCombinatorsInsideJavaScriptAreKeptIntact() throws {
        let context = LegadoRuleContext()
        var programs: [String] = []
        context.evaluateJS = { program, bindings in
            programs.append(program)
            if program == "result.trim()" { XCTAssertEqual(bindings["result"] as? String, "山间来信"); return "处理后的来信" }
            return ["a||b", "c&&d", "##保留"]
        }
        let engine = LegadoRuleEngine(context: context)
        let code = #"const marker='</js>'; /* </js> */ ['a||b', 'c&&d', '##保留']"#
        XCTAssertEqual(try engine.list("<js>" + code + "</js>", in: "body"), ["a||b", "c&&d", "##保留"])
        XCTAssertEqual(programs.last, code)
        let regexProgram = #"result.replace(/[\"']/g, '')"#
        _ = try engine.list("<js>" + regexProgram + "</js>", in: "body")
        XCTAssertEqual(programs.last, regexProgram)
        XCTAssertEqual(try engine.list("@js:" + code, in: "body"), ["a||b", "c&&d", "##保留"])
        XCTAssertEqual(try engine.text("class.book.0@tag.a@text@js:result.trim()", in: html), "处理后的来信")
        XCTAssertThrowsError(try engine.list("<js>'unfinished'", in: ""))
    }
    func testResponseBodiesAndStructuredJSONRowsKeepDifferentResultTypes() throws {
        let context = LegadoRuleContext()
        context.evaluateJS = { _, bindings in
            if let value = bindings["result"] as? [String: String] { return value["name"] ?? "" }
            return bindings["result"] as? String ?? "unexpected"
        }
        let engine = LegadoRuleEngine(context: context), json = #"{"name":"原稿"}"#
        XCTAssertEqual(try engine.text("@js:result", in: json), json)
        context.structuredInput = true
        XCTAssertEqual(try engine.text("@js:result.name", in: json), "原稿")
    }
    func testUnknownSyntaxMalformedRulesAndOversizedResultsFailExplicitly() throws {
        let engine = LegadoRuleEngine()
        XCTAssertThrowsError(try engine.text("tag.a:nth-child(1)@text", in: html))
        XCTAssertThrowsError(try engine.text("text.山间@text", in: html))
        XCTAssertThrowsError(try engine.text("tag.a[", in: html))
        XCTAssertThrowsError(try engine.template("{{key"))
        XCTAssertThrowsError(try engine.text("@js:result", in: html))
        XCTAssertThrowsError(try engine.elements("tag.a", in: String(repeating: "<a>x</a>", count: 2001)))
        XCTAssertThrowsError(try engine.text("@text", in: String(repeating: "a", count: 2 * 1024 * 1024 + 1)))
    }
}
