import Foundation
import Combine

enum LegadoLoginUIError: LocalizedError, Equatable {
    case invalid(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let field): "书源登录表单无效：\(field)"
        case .unsupported(let type): "此登录表单类型暂不支持：\(type)"
        }
    }
}

struct LegadoLoginItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case text, password, button }
    let id: String
    let name: String
    let kind: Kind
    let action: String
    let initialValue: String
}

struct LegadoLoginDefinition: Equatable, Sendable {
    let items: [LegadoLoginItem]
    static func parse(_ source: DemoSource) throws -> Self {
        guard let bytes = source.configuration, bytes.count <= 5 * 1024 * 1024,
              let package = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LegadoLoginUIError.invalid("书源配置") }
        guard let raw = package["loginUi"] ?? package["loginUI"] else { return .init(items: []) }
        let object: Any
        if let string = raw as? String {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .init(items: []) }
            guard string.utf8.count <= 256 * 1024 else { throw LegadoLoginUIError.invalid("表单超过 256 KiB") }
            object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        } else { object = raw }
        guard let rows = object as? [[String: Any]], rows.count <= 128 else { throw LegadoLoginUIError.invalid("最多 128 项表单控件") }
        var items: [LegadoLoginItem] = [], names = Set<String>()
        for (index, row) in rows.enumerated() {
            guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
                  let type = row["type"] as? String else { throw LegadoLoginUIError.invalid("第 \(index + 1) 项缺少名称或类型") }
            guard let kind = LegadoLoginItem.Kind(rawValue: type.lowercased()) else { throw LegadoLoginUIError.unsupported(type) }
            let action = row["action"] as? String ?? ""
            let value = row["value"] as? String ?? row["defaultValue"] as? String ?? ""
            guard action.utf8.count <= 64 * 1024, value.utf8.count <= 16 * 1024 else { throw LegadoLoginUIError.invalid("控件内容超过限制") }
            if kind == .button {
                guard !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LegadoLoginUIError.invalid("按钮缺少 action") }
            } else if !names.insert(name).inserted { throw LegadoLoginUIError.invalid("重复输入项：\(name)") }
            items.append(.init(id: StableContentID.make(String(index), name, type), name: name, kind: kind, action: action, initialValue: value))
        }
        return .init(items: items)
    }
}

struct LegadoLoginActionResult: Sendable {
    enum Authentication: Sendable { case unknown, verified, expired, loggedOut }
    var message: String
    var authentication: Authentication
    init(message: String = "操作已完成，登录状态尚未验证。", authentication: Authentication = .unknown) {
        self.message = message; self.authentication = authentication
    }
}

@MainActor final class LegadoLoginFormModel: ObservableObject {
    typealias Action = @Sendable (String, [String: String]) async throws -> LegadoLoginActionResult
    let source: DemoSource
    let state: LegadoPersistentState
    let definition: LegadoLoginDefinition
    @Published var values: [String: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var status: LegadoAuthStatus
    private let runAction: Action
    private var operation: Task<Void, Never>?
    private var revision = UUID()
    private var clearBrowserState: (@Sendable () async throws -> Void)?
    init(source: DemoSource, state: LegadoPersistentState, runAction: @escaping Action) throws {
        self.source = source; self.state = state; definition = try LegadoLoginDefinition.parse(source)
        self.runAction = runAction; status = state.authStatus
        let saved = try state.getLoginInfoMap()
        for item in definition.items where item.kind != .button { values[item.name] = saved[item.name] ?? item.initialValue }
    }
    func perform(_ item: LegadoLoginItem) {
        guard item.kind == .button, !busy else { return }
        operation?.cancel(); let token = UUID(); revision = token; busy = true; message = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { busy = false; operation = nil } }
            do {
                try Task.checkCancellation(); guard revision == token else { throw CancellationError() }
                guard values.values.allSatisfy({ $0.utf8.count <= 16 * 1024 }) else { throw LegadoLoginUIError.invalid("输入内容过长") }
                let merged = try state.getLoginInfoMap().merging(values) { _, value in value }
                try state.setLoginInfo(merged)
                let result = try await runAction(item.action, merged)
                try Task.checkCancellation(); guard revision == token else { return }
                switch result.authentication {
                case .verified:
                    if state.authStatus == .expired { throw LegadoInteractionError.expired }
                    if state.authStatus == .signedOut { throw LegadoInteractionError.loggedOut }
                    try state.markVerified()
                case .expired: try state.expire()
                case .loggedOut: try state.logout()
                case .unknown: break
                }
                refresh(); message = result.message
            } catch is CancellationError {
                if revision == token { message = "操作已取消，未确认登录成功。" }
            } catch { if revision == token { refresh(); message = error.localizedDescription } }
        }
    }
    func cancel() {
        operation?.cancel(); operation = nil; revision = UUID(); busy = false
        message = "操作已取消，未确认登录成功。"
    }
    func logout() {
        cancel()
        do {
            try state.logout()
            LegadoInteractionCoordinator.shared.cancel(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile, reason: .loggedOut)
            refresh()
            guard let clearBrowserState else { message = "此书源的本地登录信息与 Cookie 已清除。"; return }
            let token = UUID(); revision = token; busy = true; message = "正在清除网页登录会话…"
            operation = Task { [weak self] in
                guard let self else { return }
                defer { if revision == token { busy = false; operation = nil } }
                do {
                    try await clearBrowserState(); try Task.checkCancellation()
                    if revision == token { message = "此书源的本地登录信息、Cookie 与网页登录会话已清除。" }
                } catch { if revision == token { message = "登录信息已清除，网页会话清理未完成：\(error.localizedDescription)" } }
            }
        }
        catch { message = error.localizedDescription }
    }
    func useBrowserCleanup(_ action: @escaping @Sendable () async throws -> Void) { clearBrowserState = action }
    func disappeared() {
        let browser = LegadoInteractionCoordinator.shared.request
        if busy, browser?.sourceID != source.id || browser?.accountID != state.scope.accountID || browser?.libraryProfile != state.scope.libraryProfile { cancel() }
    }
    func refreshStatus() {
        let next = state.authStatus
        if next != status, next == .expired {
            cancel()
            LegadoInteractionCoordinator.shared.cancel(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile, reason: .expired)
        }
        status = next
    }
    func refresh() {
        status = state.authStatus
        if let saved = try? state.getLoginInfoMap() {
            for item in definition.items where item.kind != .button { values[item.name] = saved[item.name] ?? "" }
        }
    }
}
