import XCTest
@testable import Yueshan

private actor ScriptTransportProbe: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        return (Data("原创宿主响应".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/plain"])!)
    }
}
final class NativeScriptHostTests: XCTestCase {
    @MainActor func testActualWorkerUnicodeEncodingNativeExtractionDigestAndSourceCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let host = NativeScriptHost(cache:ScriptCache(directory:root)),policy = ScriptHostPolicy(sourceID:"original")
        let program = "await host.cachePut('book',input); const html = await host.extract({kind:'css',expression:'p'},'<p>Original</p>'); return {text:host.base64Decode(host.base64Encode(input)),cache:await host.cacheGet('book'),html,hash:await host.sha256(input),cookies:typeof document,fetch:typeof fetch};"
        let bytes = try await host.run(program,input:JSONEncoder().encode("山海😀"),policy:policy)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual(object["text"] as? String,"山海😀"); XCTAssertEqual(object["cache"] as? String,"山海😀"); XCTAssertEqual(object["html"] as? [String],["Original"]); XCTAssertEqual(object["hash"] as? String,StableContentID.version("山海😀")); XCTAssertEqual(object["cookies"] as? String,"undefined"); XCTAssertEqual(object["fetch"] as? String,"undefined")
        let other = try await host.run("return await host.cacheGet('book');",input:Data("null".utf8),policy:.init(sourceID:"another"))
        XCTAssertEqual(String(data:other,encoding:.utf8),"null")
    }
    @MainActor func testInfiniteLoopTimeoutCancellationAndFreshRunAreIndependent() async throws {
        let host = NativeScriptHost(),begin = ProcessInfo.processInfo.systemUptime
        do { _ = try await host.run("while(true) {}",input:Data("null".utf8),policy:.init(sourceID:"pure",timeout:0.15)); XCTFail("Loop must terminate") } catch ScriptHostError.timedOut {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin,10)
        let task = Task { try await host.run("await new Promise(()=>{});",input:Data("null".utf8),policy:.init(sourceID:"pure",timeout:5)) }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch is CancellationError {}
        let result = try await host.run("return input + 1;",input:Data("2".utf8),policy:.init(sourceID:"pure")); XCTAssertEqual(String(data:result,encoding:.utf8),"3")
    }
    @MainActor func testNetworkRequiresOptInAndStaysInSelectedOriginWithoutCredentials() async throws {
        let transport = ScriptTransportProbe(),host = NativeScriptHost(transport:transport)
        let rejected = try await host.run("try { await host.fetch({url:'https://other.test/book'}); return false; } catch(_) { return true; }",input:Data("null".utf8),policy:.init(sourceID:"one",origin:URL(string:"https://source.test"),network:true))
        XCTAssertEqual(String(data:rejected,encoding:.utf8),"true")
        let disabled = try await host.run("try { await host.fetch({url:'https://source.test/book'}); return false; } catch(_) { return true; }",input:Data("null".utf8),policy:.init(sourceID:"one",origin:URL(string:"https://source.test")))
        XCTAssertEqual(String(data:disabled,encoding:.utf8),"true")
        let result = try await host.run("return (await host.fetch({url:'/book?q=test'})).body;",input:Data("null".utf8),policy:.init(sourceID:"one",origin:URL(string:"https://source.test"),network:true))
        XCTAssertEqual(try JSONDecoder().decode(String.self,from:result),"原创宿主响应")
        let requests = await transport.requests; XCTAssertEqual(requests.count,1); XCTAssertEqual(requests.first?.url?.host,"source.test"); XCTAssertNil(requests.first?.value(forHTTPHeaderField:"Cookie")); XCTAssertNil(requests.first?.value(forHTTPHeaderField:"X-Api-Key"))
    }
    func testScriptCacheIsBoundedPersistentAndAccountIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let first = ScriptHostPolicy(sourceID:"s",origin:URL(string:"https://source.test"),accountID:"one"),second = ScriptHostPolicy(sourceID:"s",origin:URL(string:"https://source.test"),accountID:"two")
        let cache = ScriptCache(directory:root); try await cache.put(scope:first.scope,key:"key",value:"原创")
        let restarted = ScriptCache(directory:root),saved = try await restarted.get(scope:first.scope,key:"key"),other = try await restarted.get(scope:second.scope,key:"key")
        XCTAssertEqual(saved,"原创"); XCTAssertNil(other)
        do { try await cache.put(scope:first.scope,key:"large",value:String(repeating:"a",count:17000)); XCTFail("Quota") } catch {}
        for index in 0..<65 { try await cache.put(scope:first.scope,key:"\(index)",value:"value") }
        let evicted = try await cache.get(scope:first.scope,key:"0"); XCTAssertNil(evicted)
    }
}
