import XCTest
import Darwin
import ZhuyingScriptCore
@testable import Zhuying

private final class IdentityHostFailure: Error { let id: Int; init(_ id: Int) { self.id = id } }
private final class WeakHostFailure: @unchecked Sendable { weak var value: IdentityHostFailure? }
private final class HostIdentityCalls { var count = 0 }

final class QuickJSHostErrorIdentityTests: XCTestCase {
    private func evaluate(_ script: String, session: QuickJSScriptSession = .init(), library: String = "", restore: Bool = true,
                          calls: Int = 128, host: @escaping (String, [Any]) throws -> Any) async throws -> Any {
        var policy = LegadoScriptPolicy(); policy.restoreHostErrors = restore; policy.maximumHostCalls = calls
        return try await Task.detached { try session.evaluate(script, bindings: [:], library: library, policy: policy, host: host) }.value
    }
    func testUncaughtHostErrorRestoresOriginalNativeIdentityOnlyWhenEnabled() async throws {
        let original = IdentityHostFailure(1)
        do { _ = try await evaluate("java.get('fixture')") { _, _ in throw original }; XCTFail("Expected original host failure") }
        catch { XCTAssertTrue(error as? IdentityHostFailure === original) }
        do { _ = try await evaluate("java.get('fixture')", restore: false) { _, _ in throw original }; XCTFail("Expected legacy JS failure") }
        catch { guard let failure = error as? QuickJSScriptError, case .javascript = failure else { return XCTFail("Default behavior remains a JavaScript exception") } }
    }
    func testCaughtHostFailureDoesNotBecomeCauseOfLaterIndependentScriptFailure() async throws {
        for script in ["try{java.get('fixture')}catch(e){};throw new TypeError('independent')", "try{java.get('fixture')}catch(e){throw new Error(e.message)}"] {
            do { _ = try await evaluate(script) { _, _ in throw ContentFailure.authenticationRequired }; XCTFail("Expected script failure") }
            catch {
                XCTAssertTrue(error is QuickJSScriptError)
                XCTAssertEqual(SourceDiagnosticIssue.classify(error).code, .scriptFailure)
            }
        }
    }
    func testRethrowingSameErrorKeepsNativeCauseDespiteMessageAndNameMutation() async throws {
        let original = IdentityHostFailure(2)
        do {
            _ = try await evaluate("try{java.get('fixture')}catch(e){e.message='changed';e.name='TypeError';throw e}") { _, _ in throw original }
            XCTFail("Expected exact native cause")
        } catch { XCTAssertTrue(error as? IdentityHostFailure === original) }
    }
    func testMultipleCaughtFailuresRestoreTheRethrownObjectRatherThanLastHostFailure() async throws {
        let first = IdentityHostFailure(1), second = IdentityHostFailure(2)
        do {
            _ = try await evaluate("let first;try{java.get('first')}catch(e){first=e};try{java.get('second')}catch(e){};throw first") { _, args in
                throw args.first as? String == "first" ? first : second
            }
            XCTFail("Expected first cause")
        } catch { XCTAssertTrue(error as? IdentityHostFailure === first) }
    }
    func testSuccessfulCatchKeepsLibraryAndReleasesNativeCauseAtCallBoundary() async throws {
        let session = QuickJSScriptSession(), weak = WeakHostFailure(), library = "var count=0;"
        let first = try await evaluate("try{java.get('fixture')}catch(e){globalThis.saved=e};++count", session: session, library: library) { _, _ in
            let error = IdentityHostFailure(3); weak.value = error; throw error
        } as? Int
        XCTAssertEqual(first, 1); XCTAssertNil(weak.value)
        let second = try await evaluate("++count", session: session, library: library) { _, _ in NSNull() } as? Int
        XCTAssertEqual(second, 2)
        // A stored JS Error from a completed evaluation has no current native
        // cause association, even when this evaluation allocates ID 1 again.
        do {
            _ = try await evaluate("try{java.get('another')}catch(e){};throw saved", session: session, library: library) { _, _ in throw ContentFailure.restricted }
            XCTFail("Old JS error is still an exception")
        } catch { XCTAssertTrue(error is QuickJSScriptError) }
    }
    func testHostQuotaStillWinsOverCaughtNativeErrorsAndTheirAssociations() async throws {
        do {
            _ = try await evaluate("for(let n=0;n<3;n++){try{java.get('fixture')}catch(e){}};42", calls: 2) { _, _ in throw ContentFailure.authenticationRequired }
            XCTFail("Caught exceptions cannot bypass native host quotas")
        } catch { XCTAssertEqual(error as? QuickJSScriptError, .bridgeLimit) }
    }
    func testCBridgeReportsOnlyFinalExceptionObjectIdentityAndClearsEachEvaluation() async throws {
        try await Task.detached {
            let scripts: [(String, ZYQJSStatus, UInt32)] = [
                ("java.get('first')", ZYQJS_SCRIPT_EXCEPTION, 41),
                ("try{java.get('first')}catch(e){throw e}", ZYQJS_SCRIPT_EXCEPTION, 41),
                ("try{java.get('first')}catch(e){throw new Error(e.message)}", ZYQJS_SCRIPT_EXCEPTION, 0),
                ("try{java.get('first')}catch(e){};42", ZYQJS_OK, 0),
                ("throw new Error('identical fixture message')", ZYQJS_SCRIPT_EXCEPTION, 0),
                ("let first;try{java.get('first')}catch(e){first=e};try{java.get('second')}catch(e){};throw first", ZYQJS_SCRIPT_EXCEPTION, 41)
            ]
            let session = try XCTUnwrap(ZYQuickJSCreateSession()); defer { ZYQuickJSDestroySession(session) }
            for (script, status, id) in scripts {
                let calls = HostIdentityCalls(), opaque = Unmanaged.passUnretained(calls).toOpaque()
                let limits = ZYQJSLimits(memory_limit_bytes: 16 * 1024 * 1024, stack_limit_bytes: 512 * 1024, timeout_milliseconds: 1000,
                                        maximum_output_bytes: 64 * 1024, maximum_host_calls: 4, maximum_bridge_bytes: 64 * 1024)
                var result = script.withCString { program in
                    ZYQuickJSSessionEvaluate(session, program, script.utf8.count, "", 0, "{}", 2, limits, { context, _, _, errorID in
                        guard let context, let errorID else { return nil }
                        let calls = Unmanaged<HostIdentityCalls>.fromOpaque(context).takeUnretainedValue(); calls.count += 1
                        errorID.pointee = Int32(40 + calls.count)
                        return strdup("identical fixture message")
                    }, nil, opaque)
                }
                defer { ZYQuickJSFreeResult(&result) }
                XCTAssertEqual(result.status, status); XCTAssertEqual(result.host_error_id, id)
            }
        }.value
    }
}
