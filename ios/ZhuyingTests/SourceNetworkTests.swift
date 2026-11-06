import XCTest
import Network
@testable import Zhuying

private final class TestDNSListener: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label:"original-dns-test")
    let lock = NSLock()
    var received = 0
    let respond: Bool
    init(respond: Bool = true) throws {
        self.respond = respond
        let parameters = NWParameters.udp; parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any); listener = try NWListener(using:parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }; connection.start(queue:queue)
            connection.receiveMessage { [weak self] data,_,_,_ in
                guard let self,let data else { connection.cancel(); return }; lock.lock(); received += 1; lock.unlock()
                if respond { let answer = Self.answer(data); connection.send(content:answer,completion:.contentProcessed{_ in connection.cancel()}) }
            }
        }
    }
    static func answer(_ question: Data) -> Data {
        var bytes = question; bytes[2] = 0x81; bytes[3] = 0x80; bytes[6] = 0; bytes[7] = 1
        bytes.append(contentsOf:[0xc0,0x0c,0,1,0,1,0,0,0,60,0,4,192,0,2,55]); return bytes
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in guard let self else { return }; switch state { case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning:listener.port!.rawValue); case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing:error); default: break } }
            listener.start(queue:queue)
        }
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return received }
    deinit { listener.cancel() }
}
private final class BoundedSourceURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/plain"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:Data(repeating:65,count:4096)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
final class SourceNetworkTests: XCTestCase {
    @MainActor func testNetworkProfilesAreBoundToSourceAndHostAndResetExplicitly() throws {
        let domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!; defer { defaults.removePersistentDomain(forName:domain) }
        let store = SourceNetworkProfiles(defaults:defaults),origin = URL(string:"https://source.test")!,profile = SourceNetworkProfile(mode:.fixedIP,server:"192.0.2.1")
        try store.save(profile,sourceID:"A",origin:origin)
        XCTAssertEqual(try SourceNetworkProfiles(defaults:defaults).profile(sourceID:"A",origin:origin),profile)
        XCTAssertEqual(try store.profile(sourceID:"B",origin:origin).mode,.system); XCTAssertEqual(try store.profile(sourceID:"A",origin:URL(string:"https://other.test")!).mode,.system)
        store.reset(sourceID:"A",origin:origin); XCTAssertEqual(try store.profile(sourceID:"A",origin:origin).mode,.system)
        XCTAssertThrowsError(try SourceNetworkProfile(mode:.dns,server:"not-an-ip").validate()); XCTAssertThrowsError(try SourceNetworkProfile(mode:.proxy,server:"user:password@proxy.test").validate())
        XCTAssertThrowsError(try SourceNetworkProfile(mode:.proxy,server:"127.0.0.1:7890").validate())
    }
    func testDNSWireValidatesTransactionQuestionCompressionAndAddressRecords() throws {
        let query = try DNSWire.query(host:"books.source.test",type:1,id:901),response = TestDNSListener.answer(query)
        XCTAssertEqual(try DNSWire.answers(response,host:"books.source.test",type:1,id:901),[.init(address:"192.0.2.55",ttl:60)])
        XCTAssertThrowsError(try DNSWire.answers(response,host:"books.source.test",type:1,id:902)); XCTAssertThrowsError(try DNSWire.answers(response,host:"other.test",type:1,id:901))
        var loop = response; loop[12] = 0xc0; loop[13] = 0x0c; XCTAssertThrowsError(try DNSWire.answers(loop,host:"books.source.test",type:1,id:901))
        var opcode = response; opcode[2] |= 8; XCTAssertThrowsError(try DNSWire.answers(opcode,host:"books.source.test",type:1,id:901))
        var truncated = response; truncated[2] |= 2; XCTAssertThrowsError(try DNSWire.answers(truncated,host:"books.source.test",type:1,id:901))
        XCTAssertThrowsError(try DNSWire.query(host:"bad/host",type:1,id:1))
    }
    func testActualNativeUDPDNSUsesSelectedServerCachesAndCancels() async throws {
        let server = try TestDNSListener(),port = try await server.start(),resolver = SourceDNSResolver()
        let first = try await resolver.resolve(host:"books.source.test",server:"127.0.0.1",port:port),second = try await resolver.resolve(host:"books.source.test",server:"127.0.0.1",port:port)
        XCTAssertEqual(first,"192.0.2.55"); XCTAssertEqual(second,first); XCTAssertEqual(server.count(),1)
        let silent = try TestDNSListener(respond:false),silentPort = try await silent.start()
        let task = Task { try await resolver.resolve(host:"books.source.test",server:"127.0.0.1",port:silentPort) }; try await Task.sleep(for:.milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled DNS must not fall back") } catch is CancellationError {}
    }
    func testConfiguredSourceTransportBoundsUnknownLengthAndRejectsAnotherOrigin() async throws {
        let transport = SourceHTTPTransport(makeSession:{ let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BoundedSourceURLProtocol.self]; return URLSession(configuration:config) },maximumResponseBytes:1024)
        do { _ = try await transport.send(URLRequest(url:URL(string:"https://bounded.test/body")!)); XCTFail("Body bound") } catch ContentFailure.invalidResponse {}
        let source = try SourceNetworkTransport(origin:URL(string:"https://one.test")!,profile:.init())
        do { _ = try await source.send(URLRequest(url:URL(string:"https://another.test")!)); XCTFail("Source origin") } catch ContentFailure.sourceDisabled {}
    }
}
