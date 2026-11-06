import XCTest
@testable import Yueshan

private final class SourceTransportProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(request.url!.path.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SourceSessionObserver: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    let invalidated = XCTestExpectation(description: "Released source invalidates its session")
    var count: Int { lock.lock(); defer { lock.unlock() }; return creations }
    func makeSession() -> URLSession {
        lock.lock(); creations += 1; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceTransportProtocol.self]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { invalidated.fulfill() }
}

final class SourceHTTPTransportTests: XCTestCase {
    func testIdleTransportCreatesNoSessionConcurrentReadsShareOneAndReleaseInvalidatesIt() async throws {
        let observer = SourceSessionObserver()
        var transport: SourceHTTPTransport? = .init(makeSession: { observer.makeSession() })
        XCTAssertEqual(observer.count, 0, "Constructing the login/source model must not start networking")
        try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<8 {
                let source = transport!
                group.addTask {
                    let (body, response) = try await source.send(URLRequest(url: URL(string: "https://transport.test/\(index)")!))
                    XCTAssertEqual(response.statusCode, 200)
                    return body
                }
            }
            var bodies = Set<String>()
            for try await bytes in group { bodies.insert(String(decoding: bytes, as: UTF8.self)) }
            XCTAssertEqual(bodies, Set((0..<8).map { "/\($0)" }))
        }
        XCTAssertEqual(observer.count, 1)
        transport = nil
        await fulfillment(of: [observer.invalidated], timeout: 3)
    }
    func testAlreadyCancelledRequestDoesNotCreateSession() async throws {
        let observer = SourceSessionObserver(), transport = SourceHTTPTransport(makeSession: { observer.makeSession() })
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await transport.send(URLRequest(url: URL(string: "https://transport.test/cancelled")!))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        XCTAssertEqual(observer.count, 0)
    }
}
