import XCTest
@testable import Zhuying

final class QuickJSScriptRuntimeTests: XCTestCase {
    private func evaluate(_ script: String, bindings: [String: Any] = [:], library: String = "",
                          policy: LegadoScriptPolicy = .init()) async throws -> Any {
        try await Task.detached {
            try QuickJSScriptRuntime.evaluate(script, bindings: bindings, library: library, policy: policy) { _, _ in NSNull() }
        }.value
    }

    func testActualJavaScriptCompletionBindingsAndLibraryShareOneScope() async throws {
        XCTAssertEqual(QuickJSScriptRuntime.version, "2026-06-04")
        let bindings: [String: Any] = ["key": "山海👩🏽‍🚀\n竹影\u{0000}正文", "page": 3, "book": ["title": "来信"]]
        let result = try await evaluate("counter += page; [decorate(key), counter, book.title]", bindings: bindings,
                                        library: "var counter = 2; function decorate(value) { return '《' + value + '》'; }") as? [Any]
        XCTAssertEqual(result?[0] as? String, "《山海👩🏽‍🚀\n竹影\u{0000}正文》")
        XCTAssertEqual(result?[1] as? Int, 5)
        XCTAssertEqual(result?[2] as? String, "来信")
        _ = try await evaluate("globalThis.sourceSecret = 'only this runtime'")
        let independent = try await evaluate("typeof sourceSecret") as? String
        XCTAssertEqual(independent, "undefined")
    }

    func testSynchronousNestedHostCallsAndResponseMethodsWithoutSourceRewriting() async throws {
        let result = try await Task.detached {
            var variables: [String: String] = [:]
            var sequence: [String] = []
            let result = try QuickJSScriptRuntime.evaluate(#"""
                function fetchNested() { return [1,2].map(n => java.ajax('chapter-' + n)).join('|'); }
                java.put('position', '第二章👩🏽‍🚀');
                const response = java.connect('https://source.test/chapter');
                [fetchNested(), java.get('position'), response.body(), response.code(), response.header('x-title'),
                 response.url(), source.getVariable(), book.getVariable('reader'), cookie.getCookie('source.test')];
                """#, bindings: ["book": ["title": "山海"]]) { method, arguments in
                sequence.append(method)
                switch method {
                case "java.ajax": return "同步:" + (arguments[0] as! String)
                case "java.connect": return ["body": "章节正文", "statusCode": 200, "headers": ["X-Title": "竹影"], "url": "https://source.test/chapter"] as [String: Any]
                case "java.put": variables[arguments[0] as! String] = arguments[1] as? String; return NSNull()
                case "java.get": return variables[arguments[0] as! String] ?? ""
                case "source.getVariable": return "source-variable"
                case "book.getVariable": return "book-variable"
                case "cookie.getCookie": return "reader=local-test"
                default: throw QuickJSScriptError.invalidInput
                }
            }
            return (result as? [Any], sequence)
        }.value
        XCTAssertEqual(result.0?[0] as? String, "同步:chapter-1|同步:chapter-2")
        XCTAssertEqual(result.0?[1] as? String, "第二章👩🏽‍🚀")
        XCTAssertEqual(result.0?[2] as? String, "章节正文")
        XCTAssertEqual(result.0?[3] as? Int, 200)
        XCTAssertEqual(result.0?[4] as? String, "竹影")
        XCTAssertEqual(result.0?[6] as? String, "source-variable")
        XCTAssertEqual(result.0?[7] as? String, "book-variable")
        XCTAssertEqual(result.1, ["java.put", "java.connect", "java.ajax", "java.ajax", "java.get", "source.getVariable", "book.getVariable", "cookie.getCookie"])
    }

    func testHostFailureIsCatchableByJavaScriptAndUnhandledErrorsAreReported() async throws {
        let caught = try await Task.detached {
            try QuickJSScriptRuntime.evaluate("try { java.ajax('x') } catch(e) { 'caught:' + e.message }", bindings: [:]) { _, _ in
                throw NSError(domain: "Zhuying.QuickJS.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试服务未响应"])
            }
        }.value as? String
        XCTAssertTrue(caught?.contains("测试服务未响应") == true)
        do { _ = try await evaluate("throw new Error('章节👩🏽‍🚀无法打开')"); XCTFail("Expected a real JavaScript exception") }
        catch QuickJSScriptError.javascript(let message) { XCTAssertTrue(message.contains("章节👩🏽‍🚀无法打开")) }
    }

    func testInfiniteLoopIsInterruptedUsingPublicQuickJSInterruptCallback() async throws {
        var policy = LegadoScriptPolicy(); policy.timeoutSeconds = 0.03
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await evaluate("while (true) {}", policy: policy); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testThrownMessageCannotBecomeAnUnboundedNativeOutputBuffer() async throws {
        do { _ = try await evaluate("throw new Error('章👩🏽‍🚀'.repeat(10000))"); XCTFail("Expected script exception") }
        catch QuickJSScriptError.javascript(let message) { XCTAssertLessThanOrEqual(message.utf8.count, 16_384) }
    }

    func testRuntimeHeapLimitRejectsAllocationAndCannotBeCaughtToEscapeBudget() async throws {
        var policy = LegadoScriptPolicy(); policy.memoryLimitBytes = 2 * 1024 * 1024
        do { _ = try await evaluate("try { new ArrayBuffer(64 * 1024 * 1024) } catch(e) {}; 'ignored allocation failure'", policy: policy); XCTFail("Expected memory limit") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .memoryLimit) }
        let healthy = try await evaluate("1 + 2") as? Int
        XCTAssertEqual(healthy, 3, "An exhausted runtime must not poison a later evaluation")
    }

    func testStackLimitAndBlockingAtomicsDoNotBypassTermination() async throws {
        var policy = LegadoScriptPolicy(); policy.stackLimitBytes = 64 * 1024
        do { _ = try await evaluate("function recurse(){return recurse()+1}; recurse()", policy: policy); XCTFail("Expected stack exhaustion") }
        catch QuickJSScriptError.javascript(let message) { XCTAssertTrue(message.contains("stack")) }
        let blocked = try await evaluate("try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0); 'blocked' } catch(e) { 'rejected' }") as? String
        XCTAssertEqual(blocked, "rejected")
    }

    func testExternalCancellationAndSwiftTaskCancellationStopRunningLoops() async throws {
        let cancellation = LegadoScriptCancellation()
        var policy = LegadoScriptPolicy(); policy.cancelled = { cancellation.isCancelled }
        let worker = Task.detached { try QuickJSScriptRuntime.evaluate("while(true){}", bindings: [:], policy: policy) { _, _ in NSNull() } }
        try await Task.sleep(for: .milliseconds(30)); cancellation.cancel()
        do { _ = try await worker.value; XCTFail("Expected external cancellation") } catch is CancellationError {}
        let task = Task.detached { try QuickJSScriptRuntime.evaluate("while(true){}", bindings: [:]) { _, _ in NSNull() } }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected Swift task cancellation") } catch is CancellationError {}
    }

    func testBridgeCallsAndOutputHaveIndependentHardQuotas() async throws {
        var calls = LegadoScriptPolicy(); calls.maximumHostCalls = 0
        do { _ = try await evaluate("try { java.get('x') } catch(e) {}; 42", policy: calls); XCTFail("Expected host-call quota") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .bridgeLimit) }
        var output = LegadoScriptPolicy(); output.maximumOutputBytes = 8
        do { _ = try await evaluate("'long result string'", policy: output); XCTFail("Expected output quota") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .bridgeLimit) }
        var bridge = LegadoScriptPolicy(); bridge.maximumBridgeBytes = 128
        do { _ = try await evaluate("java.get('x'.repeat(1024))", policy: bridge); XCTFail("Expected argument quota") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .bridgeLimit) }
    }

    func testPromisesAndInvalidBindingsAreRejectedWithoutExposingOperatingSystem() async throws {
        do { _ = try await evaluate("Promise.resolve('later')"); XCTFail("The host must preserve synchronous semantics") }
        catch QuickJSScriptError.javascript(let message) { XCTAssertTrue(message.contains("Asynchronous")) }
        do { _ = try await evaluate("1", bindings: ["JSON": "replaced"]); XCTFail("Expected intrinsic-name rejection") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .invalidInput) }
        let globals = try await evaluate("[typeof std,typeof os,typeof require,typeof fetch]") as? [String]
        XCTAssertEqual(globals, ["undefined", "undefined", "undefined", "undefined"])
    }
}
