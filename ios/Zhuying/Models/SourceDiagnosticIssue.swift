import Foundation

struct SourceDiagnosticIssue: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case loginRequired, loginExpired, hostNotAllowed, unsupportedRule, unsupportedHost, scriptFailure, timedOut, cancelled
        case noSearchResults, emptyCatalog, emptyContent, restricted, unavailable, invalidResponse, sourceDisabled, stateUnavailable, incompleteAcceptance, resourceLimit, busy, duplicateContent
    }
    enum Recovery: String, Codable, Sendable { case login, network, rules, retry }
    let code: Code
    let origin: String?
    init(code: Code, origin: URL? = nil) {
        self.code = code
        self.origin = origin.flatMap { try? LegadoSourcePolicy.canonicalOrigin($0).absoluteString }
    }
    private enum CodingKeys: String, CodingKey { case code, origin }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decode(Code.self, forKey: .code)
        let origin = try values.decodeIfPresent(String.self, forKey: .origin)
        self.init(code: code, origin: origin.flatMap(URL.init(string:)))
    }
    var message: String {
        switch code {
        case .loginRequired: "需要登录此书源。请完成登录后重新调试。"
        case .loginExpired: "此书源的登录已过期。请重新登录后重试。"
        case .hostNotAllowed: "请求主机尚未允许。请到该书源的网络配置添加需要使用的 HTTP(S) 主机。"
        case .unsupportedRule: "当前规则包含尚未支持的解析能力。请检查书源规则或选择其他来源。"
        case .unsupportedHost: "脚本调用了尚未支持的宿主能力。请查看规则兼容测试结果。"
        case .scriptFailure: "规则脚本执行失败。请检查规则与返回内容后重新调试。"
        case .timedOut: "此步骤等待超时。可检查网络或调整超时后重新调试。"
        case .cancelled: "调试已取消。已完成步骤保留，未把本次运行标记为成功。"
        case .noSearchResults: "没有搜索结果。请换一个关键词或检查搜索规则。"
        case .emptyCatalog: "目录没有可读章节。请检查目录规则、访问权限或重新登录。"
        case .emptyContent: "没有取得非空正文。请检查正文规则和当前书源权限。"
        case .restricted: "当前章节不可阅读。请检查账号权限或选择可读章节。"
        case .unavailable: "书源请求未完成。请检查网络配置后重试。"
        case .invalidResponse: "返回内容与书源规则不匹配。请通过规则兼容测试检查解析步骤。"
        case .sourceDisabled: "此书源已停用或移除。请在书源管理中启用后重试。"
        case .stateUnavailable: "此账号的本地会话暂不可用。原记录已保留，请重试。"
        case .incompleteAcceptance: "完整验收证据不足，需要两本书各三章、实际联网请求和真正重启后的复核。"
        case .duplicateContent: "验收章节返回了重复的正文或版本，不能作为六个独立章节的证据。请检查章节规则或更换作品；共用前言不能替代三章正文。"
        case .resourceLimit: "此步骤超过脚本或数据资源额度。请缩小输入或检查规则后重试。"
        case .busy: "此书源的执行资源正在使用，请稍后重新调试。"
        }
    }
    var recoveries: [Recovery] {
        switch code {
        case .loginRequired, .loginExpired, .restricted: [.login, .retry]
        case .hostNotAllowed, .unavailable, .timedOut: [.network, .retry]
        case .unsupportedRule, .unsupportedHost, .scriptFailure, .invalidResponse, .emptyContent, .emptyCatalog: [.rules, .login, .retry]
        case .duplicateContent: [.rules, .retry]
        default: [.retry]
        }
    }
    static func classify(_ error: Error, authStatus: LegadoAuthStatus? = nil) -> Self {
        let error = LegadoRuleExecutionError.unwrapped(error)
        if let failure = error as? SourceDiagnosticFailure { return failure.issue }
        if error is CancellationError { return .init(code: .cancelled) }
        if let error = error as? ContentFailure {
            switch error {
            case .authenticationRequired: return .init(code: authStatus == .expired || authStatus == .verified ? .loginExpired : .loginRequired)
            case .timedOut: return .init(code: .timedOut)
            case .restricted: return .init(code: .restricted)
            case .missingChapter: return .init(code: .emptyContent)
            case .sourceDisabled: return .init(code: .sourceDisabled)
            case .storageFailure: return .init(code: .stateUnavailable)
            case .invalidResponse: return .init(code: .invalidResponse)
            default: return .init(code: .unavailable)
            }
        }
        if let error = error as? LegadoInteractionError {
            switch error {
            case .expired: return .init(code: .loginExpired)
            case .loggedOut: return .init(code: .loginRequired)
            case .cancelled, .closed: return .init(code: .cancelled)
            case .timedOut: return .init(code: .timedOut)
            case .unsupported: return .init(code: .unsupportedHost)
            default: return .init(code: .unavailable)
            }
        }
        if let error = error as? LegadoCompatibilityError {
            switch error {
            case .unsupported(let feature):
                // Classification only: never copy imported exception strings,
                // which may contain credentials, into the report or export.
                if feature.hasPrefix("尚未允许主机") { return .init(code: .hostNotAllowed) }
                return .init(code: .unsupportedRule)
            case .limit: return .init(code: .resourceLimit)
            default: return .init(code: .invalidResponse)
            }
        }
        if let error = error as? LegadoRequestError {
            if [.limit, .searchResultLimit, .scriptEvaluationLimit].contains(error) { return .init(code: .resourceLimit) }
            if case .unsupported(let feature) = error {
                return .init(code: feature.hasPrefix("脚本宿主方法") ? .unsupportedHost : .unsupportedRule)
            }
            return .init(code: .invalidResponse)
        }
        if let error = error as? QuickJSScriptError {
            switch error {
            case .timedOut, .memoryBudgetTimedOut: return .init(code: .timedOut)
            case .memoryLimit, .bridgeLimit: return .init(code: .resourceLimit)
            case .busy: return .init(code: .busy)
            case .javascript: return .init(code: .scriptFailure)
            case .invalidInput, .mainThread: return .init(code: .invalidResponse)
            }
        }
        if error is LegadoStateError { return .init(code: .stateUnavailable) }
        if error is RuleExtractionError || error is SourceImportError { return .init(code: .unsupportedRule) }
        if let error = error as? URLError { return .init(code: error.code == .timedOut ? .timedOut : error.code == .cancelled ? .cancelled : .unavailable) }
        return .init(code: .invalidResponse)
    }
}

struct SourceDiagnosticFailure: Error, LocalizedError, Sendable {
    let issue: SourceDiagnosticIssue
    init(issue: SourceDiagnosticIssue) { self.issue = issue }
    var errorDescription: String? { issue.message }
}

struct SourceDiagnosticNetworkEvidence: Codable, Equatable, Sendable {
    var successfulFetches: Int
    var failedFetches: Int
    var bytes: Int
    init(successfulFetches: Int = 0, failedFetches: Int = 0, bytes: Int = 0) {
        self.successfulFetches = max(0, successfulFetches); self.failedFetches = max(0, failedFetches); self.bytes = max(0, bytes)
    }
    func delta(since earlier: Self) -> Self {
        .init(successfulFetches: successfulFetches - earlier.successfulFetches, failedFetches: failedFetches - earlier.failedFetches, bytes: bytes - earlier.bytes)
    }
}
protocol SourceDiagnosticEvidenceProvider: BookSource {
    func diagnosticNetworkEvidence() async -> SourceDiagnosticNetworkEvidence
}
