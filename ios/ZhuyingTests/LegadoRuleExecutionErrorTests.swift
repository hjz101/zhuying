import XCTest
@testable import Zhuying

final class LegadoRuleExecutionErrorTests: XCTestCase {
    private func summary(_ message: String) throws -> SourceDiagnosticJavaScriptSummary {
        try XCTUnwrap(SourceDiagnosticJavaScriptSummary.from(QuickJSScriptError.javascript(message)))
    }
    func testRuleLocationsAcceptOnlyFixedSchemaPathsAndDescriptionsOmitCause() throws {
        XCTAssertEqual(LegadoRuleExecutionError.Field(rawValue: "ruleBookInfo.init"), .bookInfoInit)
        XCTAssertEqual(LegadoRuleExecutionError.Field(rawValue: "ruleSearch.bookUrl"), .searchBookURL)
        XCTAssertNil(LegadoRuleExecutionError.Field(rawValue: "https://private.invalid/?token=secret"))
        let cause = QuickJSScriptError.javascript("TypeError: private-token-password-user")
        let error = LegadoRuleExecutionError(field: .bookInfoTOCURL, cause: cause)
        XCTAssertEqual(error.field.rawValue, "ruleBookInfo.tocUrl")
        XCTAssertEqual(error.cause as? QuickJSScriptError, cause)
        XCTAssertFalse(error.localizedDescription.contains("private"))
    }
    func testClassificationUnwrapsNativeRecoveryAndResourceFailures() throws {
        let auth = LegadoRuleExecutionError(field: .bookInfoInit, cause: ContentFailure.authenticationRequired)
        XCTAssertEqual(SourceDiagnosticIssue.classify(auth, authStatus: .expired).code, .loginExpired)
        XCTAssertEqual(SourceDiagnosticIssue.classify(LegadoRuleExecutionError(field: .content, cause: QuickJSScriptError.timedOut)).code, .timedOut)
        XCTAssertEqual(SourceDiagnosticIssue.classify(LegadoRuleExecutionError(field: .searchBookList, cause: QuickJSScriptError.memoryLimit)).code, .resourceLimit)
        XCTAssertNil(SourceDiagnosticJavaScriptSummary.from(auth))
        let script = LegadoRuleExecutionError(field: .bookInfoIntro, cause: QuickJSScriptError.javascript("TypeError: cannot read property 'private-user' of undefined"))
        XCTAssertEqual(SourceDiagnosticIssue.classify(script).code, .scriptFailure)
        XCTAssertEqual(SourceDiagnosticJavaScriptSummary.from(script)?.reason, .undefinedProperty)
        let host = LegadoRuleExecutionError(field: .bookInfoIntro, cause: LegadoRequestError.unsupported("脚本宿主方法 private-method"))
        XCTAssertEqual(SourceDiagnosticIssue.classify(host).code, .unsupportedHost)
    }
    func testFixedJavaScriptCategoriesDiscardPrivateDetailsAndStack() throws {
        let cases: [(String, SourceDiagnosticJavaScriptSummary.Kind, SourceDiagnosticJavaScriptSummary.Reason)] = [
            ("TypeError: private-user is not a function\n at https://private.invalid/?token=secret", .typeError, .notFunction),
            ("TypeError: cannot read property 'private-password' of undefined", .typeError, .undefinedProperty),
            ("SyntaxError: JSON.parse invalid input private-query", .syntaxError, .invalidJSON),
            ("SyntaxError: unexpected end of input private-body", .syntaxError, .other),
            ("RangeError: private-stack-overflow", .rangeError, .other), ("EvalError: private-script", .evalError, .other),
            ("URIError: private-url", .uriError, .other), ("private-user Error: arbitrary thrown value", .error, .other)
        ]
        for (message, kind, reason) in cases {
            let value = try summary(message)
            XCTAssertEqual(value.kind, kind); XCTAssertEqual(value.reason, reason); XCTAssertNil(value.missingGlobal)
            let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            for privateValue in ["private", "secret", "password", "https:", " at "] { XCTAssertFalse(encoded.contains(privateValue)) }
        }
    }
    func testOnlyAllowlistedMissingPublicGlobalsAreReported() throws {
        for name in ["URL", "URLSearchParams", "DOMParser", "TextDecoder", "TextEncoder", "atob", "btoa", "CryptoJS", "Jsoup", "document", "window", "Packages"] {
            let value = try summary("ReferenceError: '\(name)' is not defined\n at private-stack")
            XCTAssertEqual(value.kind, .referenceError); XCTAssertEqual(value.reason, .missingGlobal); XCTAssertEqual(value.missingGlobal, name)
        }
        for name in ["privateReader", "token", "URLPrivate", "password"] {
            let value = try summary("ReferenceError: '\(name)' is not defined")
            XCTAssertEqual(value.reason, .other); XCTAssertNil(value.missingGlobal)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains(name))
        }
        XCTAssertNil(try summary("ReferenceError: 'private' is not defined\n at URL is not defined").missingGlobal)
    }
    func testNestedCausesAreBoundedAndSummaryPreservesOnlySafeValues() throws {
        let original = QuickJSScriptError.javascript("ReferenceError: URL is not defined")
        let wrapped = LegadoRuleExecutionError(field: .bookInfoName, cause: LegadoRuleExecutionError(field: .bookInfoInit, cause: original))
        XCTAssertEqual(SourceDiagnosticJavaScriptSummary.from(wrapped)?.missingGlobal, "URL")
        var tooDeep: any Error = original
        for _ in 0..<100 { tooDeep = LegadoRuleExecutionError(field: .unknown, cause: tooDeep) }
        XCTAssertNil(SourceDiagnosticJavaScriptSummary.from(tooDeep))
        XCTAssertEqual(SourceDiagnosticIssue.classify(tooDeep).code, .invalidResponse)
        XCTAssertNil(SourceDiagnosticJavaScriptSummary.from(QuickJSScriptError.busy))
    }
    func testActualQuickJSExceptionsProduceSafeDiagnosticShapes() async throws {
        let scripts: [(String, SourceDiagnosticJavaScriptSummary.Kind, SourceDiagnosticJavaScriptSummary.Reason)] = [
            ("({}).missing()", .typeError, .notFunction), ("URL", .referenceError, .missingGlobal),
            ("(void 0).privateProperty", .typeError, .undefinedProperty), ("function {", .syntaxError, .other)
        ]
        for (script, kind, reason) in scripts {
            let value: SourceDiagnosticJavaScriptSummary? = await Task.detached {
                do {
                    _ = try QuickJSScriptRuntime.evaluate(script, bindings: [:]) { _, _ in NSNull() }
                    return nil
                } catch { return SourceDiagnosticJavaScriptSummary.from(error) }
            }.value
            XCTAssertEqual(value?.kind, kind); XCTAssertEqual(value?.reason, reason)
        }
    }
}
