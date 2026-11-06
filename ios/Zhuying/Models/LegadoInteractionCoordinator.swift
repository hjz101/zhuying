import Foundation
import Combine

enum LegadoInteractionError: LocalizedError, Equatable {
    case cancelled, closed, timedOut, busy, expired, loggedOut, invalidRequest, navigationFailed(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: "网页操作已取消。"
        case .closed: "网页已关闭，未确认操作完成。"
        case .timedOut: "网页操作等待超时，请重新发起。"
        case .busy: "已有书源网页正在等待操作，请先完成或关闭。"
        case .expired: "书源登录已过期，本次网页操作已停止。"
        case .loggedOut: "已退出书源登录，本次网页操作已停止。"
        case .invalidRequest: "网页请求地址或参数无效。"
        case .navigationFailed(let message): "网页操作未完成：\(message)"
        case .unsupported(let capability): "此网页操作暂不支持：\(capability)"
        }
    }
}

struct LegadoBrowserRequest: Identifiable, Sendable {
    let id: UUID
    let sourceID: String
    let accountID: String
    let libraryProfile: String
    let url: URL
    let title: String
    let html: String?
    let javaScript: String?
    let allowedOrigins: [URL]
    let timeoutSeconds: TimeInterval
    init(id: UUID = UUID(), sourceID: String, accountID: String = "default", libraryProfile: String = "production", url: URL, title: String = "书源网页登录", html: String? = nil,
         javaScript: String? = nil, allowedOrigins: [URL] = [], timeoutSeconds: TimeInterval = 300) {
        self.id = id; self.sourceID = sourceID; self.accountID = accountID; self.libraryProfile = libraryProfile; self.url = url; self.title = title
        self.html = html; self.javaScript = javaScript; self.allowedOrigins = allowedOrigins; self.timeoutSeconds = timeoutSeconds
    }
    var browserScopeID: String { SourceBrowserSessions.legadoScope(sourceID: sourceID, accountID: accountID, libraryProfile: libraryProfile) }
    var isOffline: Bool { url.absoluteString == "about:blank" && html != nil }
    static func origin(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil else { throw LegadoInteractionError.invalidRequest }
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        guard let origin = parts.url else { throw LegadoInteractionError.invalidRequest }; return origin
    }
    func validate() throws {
        if !isOffline { _ = try Self.origin(url) }
        guard !sourceID.isEmpty, !accountID.isEmpty, !libraryProfile.isEmpty, sourceID.utf8.count <= 512, accountID.utf8.count <= 512, libraryProfile.utf8.count <= 512,
              title.utf8.count <= 1024, url.absoluteString.utf8.count <= 32 * 1024,
              (html?.utf8.count ?? 0) <= 2 * 1024 * 1024, (javaScript?.utf8.count ?? 0) <= 256 * 1024,
              timeoutSeconds.isFinite, (0.01...900).contains(timeoutSeconds), allowedOrigins.count <= 128 else { throw LegadoInteractionError.invalidRequest }
        for origin in allowedOrigins { _ = try Self.origin(origin) }
        if let javaScript, javaScript.range(of: #"\b(?:java|cookie|source|book|chapter)\s*(?:\.|\[)|=\s*java\b"#, options: .regularExpression) != nil {
            throw LegadoInteractionError.unsupported("网页内同步 Android 宿主桥")
        }
    }
}

struct LegadoBrowserResult: @unchecked Sendable {
    let finalURL: URL
    let html: String
    let title: String
    let cookiesByOrigin: [String: [HTTPCookie]]
}

@MainActor final class LegadoInteractionCoordinator: ObservableObject {
    static let shared = LegadoInteractionCoordinator()
    @Published private(set) var request: LegadoBrowserRequest?
    private var continuation: CheckedContinuation<LegadoBrowserResult, Error>?
    private var timeout: Task<Void, Never>?
    nonisolated func requestBrowser(_ value: LegadoBrowserRequest) async throws -> LegadoBrowserResult { try await present(value) }
    private func present(_ value: LegadoBrowserRequest) async throws -> LegadoBrowserResult {
        try Task.checkCancellation(); try value.validate()
        guard request == nil else { throw LegadoInteractionError.busy }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; request = value
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(value.timeoutSeconds)) } catch { return }
                    self?.complete(id: value.id, result: .failure(LegadoInteractionError.timedOut))
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.complete(id: value.id, result: .failure(CancellationError())) } })
    }
    func complete(id: UUID, result: Result<LegadoBrowserResult, Error>) {
        guard request?.id == id, let continuation else { return }
        var result = result
        if case .success(let value) = result, let request {
            let origins = [request.url] + request.allowedOrigins
            let allowedURL = request.isOffline && value.finalURL.absoluteString == "about:blank" || origins.contains(where: { SourceBrowserSessions.sameOrigin(value.finalURL, $0) })
            if !allowedURL || value.html.utf8.count > 2 * 1024 * 1024 || value.title.utf8.count > 1024 || request.isOffline && value.finalURL.absoluteString == "about:blank" && !value.cookiesByOrigin.isEmpty {
                result = .failure(LegadoInteractionError.invalidRequest)
            }
        }
        self.continuation = nil; request = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
    func dismiss(id: UUID) { complete(id: id, result: .failure(LegadoInteractionError.closed)) }
    func cancel(sourceID: String, accountID: String? = nil, libraryProfile: String? = nil, reason: LegadoInteractionError = .cancelled) {
        guard let request, request.sourceID == sourceID, accountID == nil || accountID == request.accountID,
              libraryProfile == nil || libraryProfile == request.libraryProfile else { return }
        complete(id: request.id, result: .failure(reason))
    }
}
