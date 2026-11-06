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
        XCTAssertTrue(fragment.hasPrefix("<a")); XCTAssertTrue(fragment.contains("<b>山间</b>"))
        XCTAssertEqual(try engine.text("article[data-note='a||b@c']@data-note", in: html), "a||b@c")
        XCTAssertEqual(try engine.list("class.book.0@tag.a@textNodes", in: html), ["来信"])
    }
    func testFallbackConcatenationAndInterleavingKeepPerRuleOrder() throws {
        let engine = LegadoRuleEngine()
        XCTAssertEqual(try engine.list(".missing@text||tag.a@text", in: html), ["山间来信", "竹下回声"])
        XCTAssertEqual(try engine.list("tag.a@text&&tag.i@text", in: html), ["山间来信", "竹下回声", "作者甲", "作者乙"])
        XCTAssertEqual(try engine.list("tag.a@text%%tag.i@text", in: html), ["山间来信", "作者甲", "竹下回声", "作者乙"])
        // fd026e0's AnalyzeByJSoup.getStringList interleaves over the first
        // successful group's indices, rather than the longest group.
        XCTAssertEqual(try engine.list("tag.a.0@text%%tag.i@text", in: html), ["山间来信", "作者甲"])
        XCTAssertEqual(try engine.list(".missing@text%%tag.i@text", in: html), ["作者甲", "作者乙"])
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
        XCTAssertEqual(try engine.text("$.literal", in: #"{"literal":"[1,2]"}"#), "[1,2]", "JSON strings are not reparsed as arrays")
    }
    func testRegexReplacementCaptureAndQuotedRegexDoNotBecomeRuleOperators() throws {
        let engine = LegadoRuleEngine()
        XCTAssertEqual(try engine.text("tag.a@text##山间##竹影", in: html), "竹影来信\n竹下回声")
        XCTAssertEqual(try engine.text("class.book.0@tag.a@text##(山间)(来信)##$2·$1", in: html), "来信·山间")
        XCTAssertEqual(try engine.text("@text##['\"]##", in: "<p>一'二\"三</p>"), "一二三")
        XCTAssertEqual(try engine.text("@text##甲|乙##丙", in: "<p>甲和乙</p>"), "丙和丙")
        XCTAssertEqual(try engine.text("@text##(来信)##$1###", in: "<p>山间来信和竹下来信</p>"), "来信")
        XCTAssertEqual(try engine.text("tag.a@text##来信\\n竹下##信封中的", in: html), "山间信封中的回声")
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
        let statementRegex = #"if (true) /[</js>]/.test(result); 'done'"#
        _ = try engine.list("<js>" + statementRegex + "</js>", in: "body")
        XCTAssertEqual(programs.last, statementRegex, "A regex statement after a control condition must not terminate its script")
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
    func testSequentialScriptStagesPreserveCompletionTypesAndApplyEachReplacementInOrder() throws {
        let context = LegadoRuleContext(); context.structuredInput = true
        context.evaluateJS = { script, bindings in
            switch script {
            case "encoded": return #"{"name":"encoded"}"#
            case "checkString":
                XCTAssertTrue(bindings["result"] is String, "Later JS string completions must not be decoded into JSON objects")
                return bindings["result"] ?? NSNull()
            case "transform":
                XCTAssertEqual(bindings["result"] as? String, "竹影来信")
                return "第二步"
            case "typedRows":
                let rows = bindings["result"] as? [[String: String]]
                XCTAssertEqual(rows?.first?["name"], "原稿")
                return rows?.map { $0["name"] ?? "" } ?? []
            default: throw LegadoCompatibilityError.invalid("unexpected test program")
            }
        }
        let engine = LegadoRuleEngine(context: context)
        XCTAssertEqual(try engine.text("<js>encoded</js><js>checkString</js>", in: #"{"name":"row"}"#), #"{"name":"encoded"}"#)
        XCTAssertEqual(try engine.text("class.book.0@tag.a@text##山间##竹影<js>transform</js>##第二##第3", in: html), "第3步")
        XCTAssertEqual(try engine.elements("$.books<js>typedRows</js>", in: #"{"books":[{"name":"原稿"}]}"#), ["原稿"])
    }
    func testHTMLProjectionCurrentElementAttributesAndTextNodesFollowReferenceBehavior() throws {
        let context = LegadoRuleContext(); context.structuredInput = true
        let engine = LegadoRuleEngine(context: context)
        let input = "<a href='/one'>前<b>嵌套</b>后<script>hidden()</script><style>.a{}</style></a>"
        XCTAssertEqual(try engine.text("href", in: input), "/one")
        XCTAssertEqual(try engine.list("textNodes", in: input), ["前\n后"])
        let HTML = try engine.text("html", in: input)
        XCTAssertTrue(HTML.hasPrefix("<a")); XCTAssertFalse(HTML.contains("script")); XCTAssertFalse(HTML.contains("style"))
        XCTAssertTrue(try engine.text("all", in: input).contains("<script>"))
    }
    func testPutVariableAggregateQuotaRejectsGrowthButAllowsReplacingExistingValue() throws {
        let context = LegadoRuleContext(variables: Dictionary(uniqueKeysWithValues: (0..<4).map { ("existing-\($0)", String(repeating: "a", count: 128 * 1024 - 32)) }))
        context.evaluateJS = { _, _ in String(repeating: "b", count: 256) }
        let engine = LegadoRuleEngine(context: context)
        XCTAssertThrowsError(try engine.text(#"@put:{"extra":"@js:value"}@get:{extra}"#, in: ""))
        XCTAssertNil(context.variables["extra"])
        XCTAssertNoThrow(try engine.text(#"@put:{"existing-0":"@js:value"}@get:{existing-0}"#, in: ""))
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
        let nested = String(repeating: "<div>", count: 80) + String(repeating: "x", count: 32 * 1024) + String(repeating: "</div>", count: 80)
        XCTAssertThrowsError(try engine.elements("tag.div", in: nested), "Repeated overlapping nodes must respect the aggregate bound during serialization")
        XCTAssertThrowsError(try engine.elements("tag.div@tag.div", in: nested), "Selector expansion must also bound intermediate node counts")
    }
}
