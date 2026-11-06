import XCTest
@testable import Zhuying

private final class BackendTestVault: ServiceKeyVault {
    var values: [String:String] = [:]
    func save(_ key: String,id: String) throws { values[id] = key }
    func read(id: String) throws -> String? { values[id] }
    func remove(id: String) throws { values[id] = nil }
    func ids() throws -> [String] { Array(values.keys) }
}
private struct BackendMockTransport: HTTPTransport {
    let action: @Sendable (URLRequest) throws -> (Data,HTTPURLResponse)
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) { try action(request) }
}
final class RemoteBackendTests: XCTestCase {
    @MainActor func testBackendProfileAndKeysRemainSourceHostAndEndpointScoped() throws {
        let domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!,vault = BackendTestVault(); defer { defaults.removePersistentDomain(forName:domain) }
        let store = RemoteBackendProfiles(defaults:defaults,vault:vault),origin = URL(string:"https://source.test")!,profile = RemoteBackendProfile(enabled:true,endpoint:"https://gateway.test")
        try store.save(profile,key:"synthetic-backend-token",sourceID:"A",origin:origin)
        XCTAssertEqual(try store.key(sourceID:"A",origin:origin,profile:profile),"synthetic-backend-token")
        XCTAssertFalse(try store.profile(sourceID:"B",origin:origin).enabled)
        XCTAssertThrowsError(try store.key(sourceID:"B",origin:origin,profile:profile))
        XCTAssertThrowsError(try store.key(sourceID:"A",origin:origin,profile:.init(enabled:true,endpoint:"https://different.test")))
        let bytes = try XCTUnwrap(defaults.dictionaryRepresentation().values.compactMap{$0 as? Data}.first)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("synthetic-backend-token"))
        try store.reset(sourceID:"A",origin:origin); XCTAssertTrue(vault.values.isEmpty); XCTAssertFalse(try store.profile(sourceID:"A",origin:origin).enabled)
        for url in ["http://gateway.test","https://user:secret@gateway.test","https://gateway.test?token=secret","https://gateway.test/path"] { XCTAssertThrowsError(try RemoteBackendProfile(enabled:true,endpoint:url).validatedURL()) }
    }
    func testGatewayEnvelopePreservesOriginalURLAndStatusWithoutLeakingBackendKeyUpstream() async throws {
        let origin = URL(string:"https://source.test")!,url = URL(string:"https://source.test/search?q=%E4%B8%AD%E6%96%87")!
        let mock = BackendMockTransport { request in
            XCTAssertEqual(request.url?.absoluteString,"https://gateway.test/v1/forward"); XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer backend-token")
            let object = try JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as! [String:Any]
            XCTAssertEqual(object["sourceID"] as? String,"original"); XCTAssertEqual(object["sourceOrigin"] as? String,"https://source.test"); XCTAssertEqual(object["path"] as? String,"/search?q=%E4%B8%AD%E6%96%87")
            XCTAssertEqual((object["headers"] as? [String:String])?["x-api-key"],"source-token"); XCTAssertFalse((object["headers"] as! [String:String]).values.contains("backend-token"))
            return (try JSONSerialization.data(withJSONObject:["version":1,"status":429,"headers":["content-type":"text/plain"],"bodyBase64":Data("限流".utf8).base64EncodedString()]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let transport = RemoteBackendTransport(sourceID:"original",origin:origin,profile:.init(enabled:true,endpoint:"https://gateway.test"),key:"backend-token",transport:mock)
        var request = URLRequest(url:url); request.setValue("source-token",forHTTPHeaderField:"X-Api-Key")
        let (data,response) = try await transport.send(request); XCTAssertEqual(String(data:data,encoding:.utf8),"限流"); XCTAssertEqual(response.statusCode,429); XCTAssertEqual(response.url,url)
        do { _ = try await transport.send(URLRequest(url:URL(string:"https://other.test")!)); XCTFail("Origin gate") } catch RemoteBackendError.invalid {}
    }
    func testFallbackRequiresExplicitOptInAndOnlyConnectionErrors() async throws {
        let origin = URL(string:"https://source.test")!,request = URLRequest(url:origin)
        let direct = BackendMockTransport { request in (Data("direct".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
        let down = BackendMockTransport { _ in throw URLError(.timedOut) }
        var transport = RemoteBackendTransport(sourceID:"A",origin:origin,profile:.init(enabled:true,endpoint:"https://gateway.test"),key:"token",transport:down,direct:direct)
        do { _ = try await transport.send(request); XCTFail("Default must not bypass backend") } catch RemoteBackendError.unavailable {}
        transport = .init(sourceID:"A",origin:origin,profile:.init(enabled:true,endpoint:"https://gateway.test",directFallback:true),key:"token",transport:down,direct:direct)
        let (bytes,_) = try await transport.send(request); XCTAssertEqual(String(data:bytes,encoding:.utf8),"direct")
        for code in [401,403,502] {
            let refused = BackendMockTransport { request in (Data(),HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!) }
            let noFallback = RemoteBackendTransport(sourceID:"A",origin:origin,profile:.init(enabled:true,endpoint:"https://gateway.test",directFallback:true),key:"token",transport:refused,direct:direct)
            do { _ = try await noFallback.send(request); XCTFail("HTTP status must never fall back") } catch {}
        }
        let tls = BackendMockTransport { _ in throw URLError(.serverCertificateUntrusted) }
        let noTrustBypass = RemoteBackendTransport(sourceID:"A",origin:origin,profile:.init(enabled:true,endpoint:"https://gateway.test",directFallback:true),key:"token",transport:tls,direct:direct)
        do { _ = try await noTrustBypass.send(request); XCTFail("TLS must never fall back") } catch RemoteBackendError.unavailable {}
    }
    func testBackendConnectionProbeUsesDedicatedEndpointAndVerifiesSourceBinding() async throws {
        let origin = URL(string:"https://source.test")!
        for returnedOrigin in ["https://source.test","https://other.test"] {
            let mock = BackendMockTransport { request in
                XCTAssertEqual(request.url?.path,"/v1/status"); XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer backend-token")
                return (try JSONSerialization.data(withJSONObject:["version":1,"ready":true,"sourceID":"original","sourceOrigin":returnedOrigin]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }
            let transport = RemoteBackendTransport(sourceID:"original",origin:origin,profile:.init(enabled:true,endpoint:"https://gateway.test"),key:"backend-token",transport:mock)
            do { try await transport.checkConnection(); XCTAssertEqual(returnedOrigin,origin.absoluteString) }
            catch { XCTAssertNotEqual(returnedOrigin,origin.absoluteString) }
        }
    }

    @MainActor func testBackendAndSourceNetworkRoutingAreExclusiveAndSystemResetRestoresForwarding() throws {
        let domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!,vault = BackendTestVault(); defer { defaults.removePersistentDomain(forName:domain) }
        let library = LibraryStore(books:[],defaults:defaults,seedDemoData:false),source = DemoSource(id:"route-test",name:"原创",detail:"",url:"https://source.test"),origin = URL(string:"https://source.test")!
        library.backendProfiles = RemoteBackendProfiles(defaults:defaults,vault:vault)
        try library.backendProfiles.save(.init(enabled:true,endpoint:"https://gateway.test"),key:"synthetic-backend-token",sourceID:source.id,origin:origin)
        try library.networkProfiles.save(.init(mode:.fixedIP,server:"192.0.2.1"),sourceID:source.id,origin:origin)
        XCTAssertThrowsError(try library.requestTransport(for:source)) { XCTAssertEqual($0 as? RemoteBackendError,.conflictingRoute) }
        library.networkProfiles.reset(sourceID:source.id,origin:origin); XCTAssertTrue(try library.requestTransport(for:source) is RemoteBackendTransport)
        try library.backendProfiles.save(.init(enabled:false),key:"",sourceID:source.id,origin:origin)
        XCTAssertTrue(try library.requestTransport(for:source) is SourceNetworkTransport)
    }

}
