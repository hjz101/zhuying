import XCTest
@testable import Yueshan

private actor SequencedHTTPTransport: HTTPTransport {
    var statuses: [Int]
    var error: URLError?
    private(set) var count = 0
    init(_ statuses: [Int], error: URLError? = nil) { self.statuses = statuses; self.error = error }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        if let error { throw error }
        let status = statuses.removeFirst()
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "0"])!)
    }
}

final class ResilientSourceTransportTests: XCTestCase {
    private func request(_ path: String = "content") -> URLRequest { URLRequest(url: URL(string: "https://source.example.test/\(path)")!) }
    private func transport(_ base: SequencedHTTPTransport) -> ResilientSourceTransport {
        .init(base: base, limiter: .init(interval: 0), pause: { _ in try Task.checkCancellation() })
    }
    func testOnlyReadEndpointsRetryTransientFailuresAndAuthenticationNeverRetries() async throws {
        let base = SequencedHTTPTransport([503, 429, 200])
        let result = try await transport(base).send(request())
        XCTAssertEqual(result.1.statusCode, 200)
        let count = await base.count; XCTAssertEqual(count, 3)
        for path in ["login", "search"] {
            let base = SequencedHTTPTransport([path == "login" ? 503 : 401])
            if path == "login" {
                do { _ = try await transport(base).send(request(path)); XCTFail("Unavailable login") } catch {}
            } else { _ = try await transport(base).send(request(path)) }
            let count = await base.count; XCTAssertEqual(count, 1)
        }
    }
    func testOfflineTimeoutRateLimitAndCancellationHaveSeparateResults() async throws {
        for (code, expected) in [(URLError.notConnectedToInternet, ContentFailure.offline), (.timedOut, .timedOut)] {
            let base = SequencedHTTPTransport([], error: URLError(code))
            do { _ = try await transport(base).send(request()); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? ContentFailure, expected) }
            let count = await base.count; XCTAssertEqual(count, code == .timedOut ? 3 : 1)
        }
        let base = SequencedHTTPTransport([429, 429, 429])
        do { _ = try await transport(base).send(request()); XCTFail("Rate limit") }
        catch { XCTAssertEqual(error as? ContentFailure, .rateLimited) }
        let cancelled = SequencedHTTPTransport([], error: URLError(.cancelled))
        do { _ = try await transport(cancelled).send(request()); XCTFail("Cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
