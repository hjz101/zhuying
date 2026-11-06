import Foundation

actor SourceRequestLimiter {
    private var next: TimeInterval = 0
    let interval: TimeInterval
    init(interval: TimeInterval = 1) { self.interval = interval }
    func acquire() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let slot = max(now, next); next = slot + interval
        if slot > now { try await Task.sleep(for: .seconds(slot - now)) }
        try Task.checkCancellation()
    }
}

/// Only the fixed adapter's read endpoints are retried. Login and arbitrary
/// writes are never replayed. One source instance owns one ephemeral session.
struct ResilientSourceTransport: HTTPTransport {
    let base: any HTTPTransport
    let limiter: SourceRequestLimiter
    let maximumAttempts: Int
    let pause: @Sendable (TimeInterval) async throws -> Void
    init(base: any HTTPTransport = SourceHTTPTransport(), limiter: SourceRequestLimiter = .init(), maximumAttempts: Int = 3,
         pause: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.base = base; self.limiter = limiter; self.maximumAttempts = max(1, min(3, maximumAttempts)); self.pause = pause
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let retryable = ["search", "details", "catalog", "content"].contains(request.url?.lastPathComponent ?? "")
        let attempts = retryable ? maximumAttempts : 1
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try await limiter.acquire()
            do {
                let result = try await base.send(request)
                try Task.checkCancellation()
                if result.1.statusCode == 429 || [502, 503, 504].contains(result.1.statusCode) {
                    guard attempt + 1 < attempts else { throw result.1.statusCode == 429 ? ContentFailure.rateLimited : .unavailable }
                    let delay = result.1.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt))
                    // Long server delays become a visible retry state, not an
                    // unattended foreground wait or an immediate retry storm.
                    guard delay <= 10 else { throw ContentFailure.rateLimited }
                    try await pause(max(0, delay)); continue
                }
                return result
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if error.code == .notConnectedToInternet || error.code == .dataNotAllowed { throw ContentFailure.offline }
                let transient = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code)
                if transient && attempt + 1 < attempts { try await pause(pow(2, Double(attempt))); continue }
                throw error.code == .timedOut ? ContentFailure.timedOut : ContentFailure.unavailable
            }
        }
        throw ContentFailure.unavailable
    }
}
