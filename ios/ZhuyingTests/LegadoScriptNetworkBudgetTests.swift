import XCTest
@testable import Zhuying

private actor ScriptBudgetSlowTransport: HTTPTransport {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(delay))
        return (Data("慢网络返回的原创正文。".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "text/plain; charset=utf-8"])!)
    }
}

final class LegadoScriptNetworkBudgetTests: XCTestCase {
    func testRealHTTPWaitCanExceedJavaScriptExecutionBudgetWithinOperationDeadline() async throws {
        let value = try await Task.detached {
            let origin = URL(string: "https://script-budget.fixture/")!
            let control = LegadoOperationControl(timeout: 0.5)
            let http = LegadoHTTPExecutor(origin: origin, transport: ScriptBudgetSlowTransport(delay: 0.08), control: control, cookies: LegadoCookieJar())
            var policy = LegadoScriptPolicy(); policy.timeoutSeconds = 0.025
            policy.cancelled = { do { try control.check(); return false } catch { return true } }
            let result = try QuickJSScriptRuntime.evaluate("[java.get('https://script-budget.fixture/prose').body(),1+2]", bindings: [:], policy: policy) { method,args in
                XCTAssertEqual(method, "java.get")
                return try http.request(args[0] as! String).bridgeValue
            }
            try control.check()
            return result
        }.value as? [Any]
        XCTAssertEqual(value?[0] as? String, "慢网络返回的原创正文。")
        XCTAssertEqual(value?[1] as? Int, 3)
    }

    func testRealHTTPWallDeadlineStillCancelsScriptEvenIfJavaScriptCatchesTheHostError() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let failure = await Task.detached { () -> (Bool,Bool) in
            let origin = URL(string: "https://script-budget.fixture/")!
            let control = LegadoOperationControl(timeout: 0.06)
            let http = LegadoHTTPExecutor(origin: origin, transport: ScriptBudgetSlowTransport(delay: 0.3), control: control, cookies: LegadoCookieJar())
            var policy = LegadoScriptPolicy(); policy.timeoutSeconds = 0.025
            policy.cancelled = { do { try control.check(); return false } catch { return true } }
            do {
                _ = try QuickJSScriptRuntime.evaluate("try{java.ajax('https://script-budget.fixture/prose')}catch(e){};'must not complete'", bindings: [:], policy: policy) { _,args in
                    try http.request(args[0] as! String).text
                }
                return (false,false)
            } catch {
                let cancelled = error is CancellationError
                do { try control.check(); return (cancelled,false) }
                catch { return (cancelled,error as? ContentFailure == .timedOut) }
            }
        }.value
        XCTAssertTrue(failure.0, "The runtime must observe the operation cancellation after its controlled wait")
        XCTAssertTrue(failure.1, "The enclosing source operation retains its wall-clock timeout")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }
}
