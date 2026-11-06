import XCTest
@testable import Zhuying

final class QuickJSScriptSessionTests: XCTestCase {
    private let counterLibrary = "var count=0; function next(){return ++count;}"

    private func evaluate(_ session: QuickJSScriptSession, _ script: String, bindings: [String: Any] = [:],
                          library: String = "", policy: LegadoScriptPolicy = .init(),
                          host: @escaping (String, [Any]) throws -> Any = { _, _ in NSNull() }) async throws -> Any {
        try await Task.detached { try session.evaluate(script, bindings: bindings, library: library, policy: policy, host: host) }.value
    }

    func testLibraryInitializesOnceAndAccountsKeepIndependentGlobals() async throws {
        let first = QuickJSScriptSession(), second = QuickJSScriptSession()
        let library = "java.put('initialized','yes'); var count=0; function next(){return ++count;}"
        let output = try await Task.detached {
            var initializations = 0
            let host: (String, [Any]) throws -> Any = { _, _ in initializations += 1; return NSNull() }
            let a = try first.evaluate("next()", bindings: [:], library: library, host: host)
            let b = try first.evaluate("globalThis.extra='saved';next()", bindings: [:], library: library, host: host)
            let c = try second.evaluate("[next(),typeof extra]", bindings: [:], library: library, host: host)
            let d = try first.evaluate("[next(),extra]", bindings: [:], library: library, host: host)
            return ([a,b,c,d], initializations)
        }.value
        XCTAssertEqual(output.0[0] as? Int, 1)
        XCTAssertEqual(output.0[1] as? Int, 2)
        XCTAssertEqual((output.0[2] as? [Any])?[0] as? Int, 1)
        XCTAssertEqual((output.0[2] as? [Any])?[1] as? String, "undefined")
        XCTAssertEqual((output.0[3] as? [Any])?[0] as? Int, 3)
        XCTAssertEqual((output.0[3] as? [Any])?[1] as? String, "saved")
        XCTAssertEqual(output.1, 2)
    }

    func testRulesHaveFreshChildScopesAndCannotShadowTheNextRequestsBindings() async throws {
        let session = QuickJSScriptSession()
        let library = "const data='library data'; var current='library current'; const names='library names';"
        let first = try await evaluate(session, "var result='rule result'; let local=2; const value=3; [result,local+value,data,current,names]",
                                       bindings: ["result": "first", "obsolete": true], library: library) as? [Any]
        XCTAssertEqual(first?[0] as? String, "rule result")
        XCTAssertEqual(first?[1] as? Int, 5)
        XCTAssertEqual(first?[2] as? String, "library data")
        XCTAssertEqual(first?[3] as? String, "library current")
        XCTAssertEqual(first?[4] as? String, "library names")
        let second = try await evaluate(session, "let local=4; const value=5; [result,typeof obsolete,typeof localOnly,local+value]",
                                        bindings: ["result": "second"], library: library) as? [Any]
        XCTAssertEqual(second?[0] as? String, "second")
        XCTAssertEqual(second?[1] as? String, "undefined")
        XCTAssertEqual(second?[2] as? String, "undefined")
        XCTAssertEqual(second?[3] as? Int, 9)
        let third = try await evaluate(session, "[typeof local,typeof value,typeof result]", library: library) as? [String]
        XCTAssertEqual(third, ["undefined", "undefined", "undefined"])
    }

    func testCachedSourceObjectsReadNewBindingsAndNewHeaderHostEachTime() async throws {
        let session = QuickJSScriptSession()
        let library = "const savedSource=source,savedBook=book,savedChapter=chapter; function snapshot(){return [savedSource.name,savedBook.title,savedChapter.index,source.getHeaderMap()];}"
        for number in 1...2 {
            let result = try await evaluate(session, "snapshot()", bindings: ["source": ["name": "source\(number)"], "book": ["title": "book\(number)"], "chapter": ["index": number]],
                                            library: library) { method, _ in
                XCTAssertEqual(method, "source.getHeaderMap")
                return ["Authorization": "token\(number)"]
            } as? [Any]
            XCTAssertEqual(result?[0] as? String, "source\(number)")
            XCTAssertEqual(result?[1] as? String, "book\(number)")
            XCTAssertEqual(result?[2] as? Int, number)
            XCTAssertEqual((result?[3] as? [String: String])?["Authorization"], "token\(number)")
        }
        let empty = try await evaluate(session, "[Object.keys(source).length,typeof book.title,typeof chapter.index]", library: library) as? [Any]
        XCTAssertEqual(empty?[0] as? Int, 0)
        XCTAssertEqual(empty?[1] as? String, "undefined")
        XCTAssertEqual(empty?[2] as? String, "undefined")
    }

    func testResetLibraryChangeAndHeapPolicyChangeRebuildTheScope() async throws {
        let session = QuickJSScriptSession()
        let first = try await evaluate(session, "next()", library: counterLibrary) as? Int
        let second = try await evaluate(session, "next()", library: counterLibrary) as? Int
        XCTAssertEqual(first, 1); XCTAssertEqual(second, 2)
        session.reset()
        let reset = try await evaluate(session, "next()", library: counterLibrary) as? Int
        XCTAssertEqual(reset, 1)
        let changed = try await evaluate(session, "next()", library: "var count=100;function next(){return ++count}") as? Int
        XCTAssertEqual(changed, 101)
        var policy = LegadoScriptPolicy(); policy.memoryLimitBytes = 8 * 1024 * 1024
        let resized = try await evaluate(session, "next()", library: "var count=100;function next(){return ++count}", policy: policy) as? Int
        XCTAssertEqual(resized, 101)
    }

    func testExceptionTimeoutAndHeapExhaustionDiscardThePersistentScope() async throws {
        let session = QuickJSScriptSession()
        var timeout = LegadoScriptPolicy(); timeout.timeoutSeconds = 0.02
        var memory = LegadoScriptPolicy(); memory.memoryLimitBytes = 2 * 1024 * 1024
        for (script, policy, expected) in [("next();throw new Error('bad rule')", LegadoScriptPolicy(), QuickJSScriptError.javascript("Error: bad rule")),
                                            ("next();while(true){}", timeout, .timedOut),
                                            ("next();try{new ArrayBuffer(64*1024*1024)}catch(e){};42", memory, .memoryLimit)] {
            do { _ = try await evaluate(session, script, library: counterLibrary, policy: policy); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? QuickJSScriptError, expected) }
            let rebuilt = try await evaluate(session, "next()", library: counterLibrary) as? Int
            XCTAssertEqual(rebuilt, 1)
        }
    }

    func testCancellationDiscardsScopeAndSuccessfulCallsResetTheirQuotaCounters() async throws {
        let session = QuickJSScriptSession(), cancellation = LegadoScriptCancellation()
        var policy = LegadoScriptPolicy(); policy.cancelled = { cancellation.isCancelled }
        let worker = Task.detached { try session.evaluate("next();while(true){}", bindings: [:], library: self.counterLibrary, policy: policy) { _, _ in NSNull() } }
        try await Task.sleep(for: .milliseconds(25)); cancellation.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        var oneCall = LegadoScriptPolicy(); oneCall.maximumHostCalls = 1
        for number in 1...2 {
            let result = try await evaluate(session, "java.get('key');next()", library: counterLibrary, policy: oneCall) as? Int
            XCTAssertEqual(result, number)
        }
    }

    func testSerializedMigrationBetweenDifferentThreadStacksKeepsLibraryState() async throws {
        let session = QuickJSScriptSession()
        let library = counterLibrary
        for (number, stack) in [2 * 1024 * 1024, 4 * 1024 * 1024, 1024 * 1024].enumerated() {
            let result: Any = try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    do { continuation.resume(returning: try session.evaluate("next()", bindings: [:], library: library) { _, _ in NSNull() }) }
                    catch { continuation.resume(throwing: error) }
                }
                thread.stackSize = stack
                thread.start()
            }
            XCTAssertEqual(result as? Int, number + 1)
        }
    }

    func testHostReentryFailsPromptlyWithoutDestroyingTheActiveVM() async throws {
        let session = QuickJSScriptSession()
        let result = try await evaluate(session, "java.get('nested');next()", library: counterLibrary) { _, _ in
            do { _ = try session.evaluate("999", bindings: [:]) { _, _ in NSNull() }; XCTFail("Expected busy") }
            catch { XCTAssertEqual(error as? QuickJSScriptError, .busy) }
            return NSNull()
        } as? Int
        XCTAssertEqual(result, 1)
        let stillHealthy = try await evaluate(session, "next()", library: counterLibrary) as? Int
        XCTAssertEqual(stillHealthy, 2)
    }

    func testConcurrentCallIsRejectedAndResetCancelsAnInFlightHostWithoutWaiting() async throws {
        let session = QuickJSScriptSession(), entered = expectation(description: "host entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = Task.detached {
            try session.evaluate("java.get('wait');next()", bindings: [:], library: self.counterLibrary) { _, _ in
                entered.fulfill()
                guard release.wait(timeout: .now() + 2) == .success else { throw QuickJSScriptError.timedOut }
                return NSNull()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await evaluate(session, "42"); XCTFail("Expected concurrent rejection") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .busy) }
        let started = ProcessInfo.processInfo.systemUptime
        session.reset()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        release.signal()
        do { _ = try await worker.value; XCTFail("Expected reset cancellation") } catch is CancellationError {}
        let next = try await evaluate(session, "next()", library: counterLibrary) as? Int
        XCTAssertEqual(next, 1)
    }

    func testInteractiveWaitDoesNotConsumeScriptBudgetButNetworkWaitDoes() async throws {
        let session = QuickJSScriptSession()
        var policy = LegadoScriptPolicy(); policy.timeoutSeconds = 0.025
        let interaction = try await evaluate(session, "java.startBrowserAwait('https://source.test').body();next()", library: counterLibrary, policy: policy) { method, _ in
            XCTAssertEqual(method, "java.startBrowserAwait")
            Thread.sleep(forTimeInterval: 0.06)
            return ["body": "reader finished", "statusCode": 200, "headers": [:], "url": "https://source.test"] as [String: Any]
        } as? Int
        XCTAssertEqual(interaction, 1)
        do {
            _ = try await evaluate(session, "java.ajax('https://source.test');next()", library: counterLibrary, policy: policy) { _, _ in
                Thread.sleep(forTimeInterval: 0.06); return "network"
            }
            XCTFail("Network waits remain inside the script deadline")
        } catch { XCTAssertEqual(error as? QuickJSScriptError, .timedOut) }
        let rebuilt = try await evaluate(session, "next()", library: counterLibrary) as? Int
        XCTAssertEqual(rebuilt, 1)
    }

    func testInteractionCancellationAndHostErrorCannotBeCaughtToReuseScope() async throws {
        let session = QuickJSScriptSession(), cancellation = LegadoScriptCancellation()
        var policy = LegadoScriptPolicy(); policy.cancelled = { cancellation.isCancelled }
        do {
            _ = try await evaluate(session, "try{java.showBrowser('https://source.test')}catch(e){};next()", library: counterLibrary, policy: policy) { _, _ in
                cancellation.cancel(); return NSNull()
            }
            XCTFail("Expected interaction cancellation")
        } catch is CancellationError {}
        do {
            _ = try await evaluate(session, "try{java.showBrowser('https://source.test')}catch(e){};next()", library: counterLibrary) { _, _ in
                throw NSError(domain: "Zhuying.QuickJS.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Interaction expired"])
            }
            XCTFail("Expected interaction error")
        } catch QuickJSScriptError.javascript {}
        let rebuilt = try await evaluate(session, "next()", library: counterLibrary) as? Int
        XCTAssertEqual(rebuilt, 1)
    }

    func testLoginCacheAndDeviceMethodsDelegateWithAccurateCapabilityDetection() async throws {
        let result = try await Task.detached {
            var calls: [String] = []
            let value = try QuickJSScriptSession().evaluate(#"""
                source.putLoginInfo('credentials');source.setLoginHeader({'Authorization':'token'});cache.put('chapter','text',30);
                [source.getLoginInfo(),source.getLoginInfoMap(),source.getLoginHeader(),source.getHeaderMap(),cache.get('chapter'),
                 java.deviceID(),String(java.deviceID),java.androidId(),typeof java.reLoginView,typeof java.qread,typeof java.noSuchMethod,
                 typeof java.startBrowserAwait,JSON.stringify(java.deviceID),java.getCookie('https://source.test'),java.getWebViewUA()];
                """#, bindings: [:]) { method, _ in
                calls.append(method)
                switch method {
                case "source.getLoginInfo": return "credentials"
                case "source.getLoginInfoMap": return ["account": "reader"]
                case "source.getLoginHeader", "source.getHeaderMap": return ["Authorization": "token"]
                case "cache.get": return "text"
                case "java.deviceID": return "stable-device"
                case "java.androidId": return "stable-android"
                case "java.getCookie": return "sid=fixture"
                case "java.getWebViewUA": return "Zhuying fixture UA"
                default: return NSNull()
                }
            }
            return (value as? [Any], calls)
        }.value
        XCTAssertEqual(result.0?[0] as? String, "credentials")
        XCTAssertEqual((result.0?[1] as? [String: String])?["account"], "reader")
        XCTAssertEqual((result.0?[3] as? [String: String])?["Authorization"], "token")
        XCTAssertEqual(result.0?[4] as? String, "text")
        XCTAssertEqual(result.0?[5] as? String, "stable-device")
        XCTAssertEqual(result.0?[6] as? String, "stable-device")
        XCTAssertEqual(result.0?[7] as? String, "stable-android")
        XCTAssertEqual(Array((result.0 ?? []).dropFirst(8).prefix(4)) as? [String], ["undefined", "undefined", "undefined", "function"])
        XCTAssertEqual(result.0?[12] as? String, "\"stable-device\"")
        XCTAssertEqual(result.0?[13] as? String, "sid=fixture")
        XCTAssertEqual(result.0?[14] as? String, "Zhuying fixture UA")
        XCTAssertTrue(result.1.contains("source.putLoginInfo")); XCTAssertTrue(result.1.contains("cache.put"))
    }

    func testCryptoChainPreservesStringCiphertextAndMatchesFrozenAndroidBase64CallShape() async throws {
        let result = try await Task.detached {
            var calls: [(String, [Any])] = []
            let output = try QuickJSScriptSession().evaluate(#"""
                const aes=java.createSymmetricCrypto('AES','0123456789abcdef');
                const wrapped=Packages.android.util.Base64.encodeToString(aes.encrypt('登录👩🏽‍🚀'),2);
                aes.setIv(new Uint8Array([1,2]));
                [wrapped,aes.encryptBase64('text'),aes.encryptHex('text'),aes.decrypt('00ff'),aes.decryptStr('AP8='),
                 aes.decryptBase64('AP8='),aes.decryptHex('00ff'),Packages.android.util.Base64.NO_WRAP];
                """#, bindings: [:]) { method, args in
                calls.append((method,args))
                switch method {
                case "crypto.encrypt", "crypto.decrypt": return [0,255]
                case "android.base64Encode": return "AP8="
                case "android.base64Decode": return [0,255]
                case "crypto.decodeText": return "解密正文"
                default: throw QuickJSScriptError.invalidInput
                }
            }
            return (output as? [Any], calls)
        }.value
        XCTAssertEqual(result.0?[0] as? String, "AP8=")
        XCTAssertEqual(result.0?[1] as? String, "AP8=")
        XCTAssertEqual(result.0?[2] as? String, "00ff")
        XCTAssertEqual(result.0?[3] as? [Int], [0,255])
        XCTAssertEqual(result.0?[4] as? String, "解密正文")
        XCTAssertEqual(result.0?[5] as? [Int], [0,255])
        XCTAssertEqual(result.0?[6] as? [Int], [0,255])
        XCTAssertEqual(result.0?[7] as? Int, 2)
        let first = result.1[0]
        XCTAssertEqual(first.0, "crypto.encrypt")
        XCTAssertEqual((first.1[0] as? [String: Any])?["algorithm"] as? String, "AES")
        XCTAssertTrue((first.1[0] as? [String: Any])?["iv"] is NSNull)
        XCTAssertEqual(first.1[1] as? String, "登录👩🏽‍🚀")
        let decrypts = result.1.filter { $0.0 == "crypto.decrypt" }
        XCTAssertEqual(decrypts[0].1[1] as? String, "00ff")
        XCTAssertEqual(decrypts[1].1[1] as? String, "AP8=")
        XCTAssertEqual((decrypts[0].1[0] as? [String: Any])?["iv"] as? [Int], [1,2])
        XCTAssertTrue(result.1.filter { $0.0 == "android.base64Encode" }.allSatisfy { $0.1[1] as? Int == 2 })
    }

    func testUnknownSourceAndJavaPackagesFailExplicitly() async throws {
        let session = QuickJSScriptSession()
        do {
            _ = try await evaluate(session, "source.getMissingVariable()") { method, _ in
                throw NSError(domain: "Zhuying.QuickJS.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported: \(method)"])
            }
            XCTFail("Unknown source API must not silently return empty data")
        } catch QuickJSScriptError.javascript(let message) { XCTAssertTrue(message.contains("source.getMissingVariable")) }
        do { _ = try await evaluate(session, "Packages.java.lang.Runtime.getRuntime()"); XCTFail("No Java reflection") }
        catch QuickJSScriptError.javascript(let message) { XCTAssertTrue(message.contains("Unsupported Java package")) }
    }

    func testDateFormatMethodsPassDateMillisecondsAndPreserveNumericArguments() async throws {
        let result = try await Task.detached {
            var calls: [(String,[Any])] = []
            let value = try QuickJSScriptSession().evaluate("[java.timeFormat(new Date(1234567)),java.timeFormatUTC(9876543,'yyyy-MM-dd',3600000)]", bindings: [:]) { method,args in
                calls.append((method,args)); return "formatted"
            }
            return (value as? [String],calls)
        }.value
        XCTAssertEqual(result.0, ["formatted","formatted"])
        XCTAssertEqual(result.1.map(\.0), ["java.timeFormat","java.timeFormatUTC"])
        XCTAssertEqual(result.1[0].1[0] as? Int, 1234567)
        XCTAssertEqual(result.1[1].1[0] as? Int, 9876543)
        XCTAssertEqual(result.1[1].1[1] as? String, "yyyy-MM-dd")
        XCTAssertEqual(result.1[1].1[2] as? Int, 3600000)
    }

    func testEmptyJavaImporterSupportsOnlyTheImplementedBase64ClassInWithScope() async throws {
        let value = try await evaluate(QuickJSScriptSession(), "[importedResult,typeof importedScope.String,Object.keys(new JavaImporter()).length]",
                                        library: "var importedScope=new JavaImporter();importedScope.importClass(Packages.android.util.Base64);var importedResult;with(importedScope){importedResult=Base64.encodeToString([1,2,3],Base64.NO_WRAP);}") { method,args in
            XCTAssertEqual(method, "android.base64Encode")
            XCTAssertEqual(args[0] as? [Int], [1,2,3]); XCTAssertEqual(args[1] as? Int, 2)
            return "AQID"
        } as? [Any]
        XCTAssertEqual(value?[0] as? String, "AQID")
        XCTAssertEqual(value?[1] as? String, "undefined")
        XCTAssertEqual(value?[2] as? Int, 0)
        for script in ["new JavaImporter(Packages.android.util.Base64)","new JavaImporter().importClass({})"] {
            do { _ = try await evaluate(QuickJSScriptSession(), script); XCTFail("Only the explicitly supported empty importer and Base64 class are allowed") }
            catch QuickJSScriptError.javascript(let message) { XCTAssertTrue(message.contains("Unsupported JavaImporter")) }
        }
    }

    func testReplaceRuleSetterUpdatesCurrentBookDataOnlyAfterNativeSuccess() async throws {
        let value = try await Task.detached {
            var enabled = true
            return try QuickJSScriptSession().evaluate("var before=book.readConfig.useReplaceRule;book.setUseReplaceRule(false);var after=book.readConfig.useReplaceRule;book.setUseReplaceRule(true);[before,after,book.getUseReplaceRule(),book.readConfig.useReplaceRule]",
                                                      bindings: ["book": ["readConfig": ["useReplaceRule": true]]]) { method,args in
                switch method {
                case "book.setUseReplaceRule": enabled = args[0] as! Bool; return NSNull()
                case "book.getUseReplaceRule": return enabled
                default: throw QuickJSScriptError.invalidInput
                }
            }
        }.value as? [Bool]
        XCTAssertEqual(value, [true,false,true,true])
        let failed = try await Task.detached {
            try QuickJSScriptSession().evaluate("try{book.setUseReplaceRule(false)}catch(e){};book.readConfig.useReplaceRule",
                                                bindings: ["book": ["readConfig": ["useReplaceRule": true]]]) { _,_ in
                throw NSError(domain: "Zhuying.QuickJS.Test", code: 1)
            }
        }.value as? Bool
        XCTAssertEqual(failed, true)
    }
}
