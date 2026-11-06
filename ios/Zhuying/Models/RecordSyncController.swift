import Foundation
import Combine

enum RecordSyncError: LocalizedError, Equatable {
    case reading, disabled
    var errorDescription: String? { self == .reading ? "请先退出阅读页面，再同步记录。" : "请先启用当前 iCloud 账号的记录同步。" }
}

@MainActor final class RecordSyncController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var account: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var state: RecordSyncState?
    @Published private(set) var message: String?
    private weak var library: LibraryStore?
    private let transport: any CloudDocumentTransport
    private let records: CloudRecordStore
    private let defaults: UserDefaults
    private var operation: Task<Void,Never>?
    private var nextAttempt = Date.distantPast
    private var observer: NSObjectProtocol?
    init(library: LibraryStore,directory: URL,defaults: UserDefaults,transport: any CloudDocumentTransport = UbiquitousDocuments()) {
        self.library = library; self.transport = transport; self.defaults = defaults
        let device = defaults.string(forKey:"cloud.records.device.v1") ?? UUID().uuidString
        defaults.set(device,forKey:"cloud.records.device.v1")
        records = CloudRecordStore(directory:directory,device:device,transport:transport)
        enabled = defaults.bool(forKey:"cloud.records.enabled.v1"); account = defaults.string(forKey:"cloud.records.account.v1")
        observer = NotificationCenter.default.addObserver(forName:.NSUbiquityIdentityDidChange,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.accountChanged() } }
    }
    func prepareAccount() async throws -> String { try await transport.account() }
    func enable(account expected: String) async throws {
        guard try await transport.account() == expected else { throw CloudAccessError.accountChanged }
        account = expected; enabled = true; defaults.set(expected,forKey:"cloud.records.account.v1"); defaults.set(true,forKey:"cloud.records.enabled.v1"); message = nil; nextAttempt = .distantPast
    }
    func disable() { operation?.cancel(); enabled = false; defaults.set(false,forKey:"cloud.records.enabled.v1") }
    func accountChanged() { disable(); account = nil; defaults.removeObject(forKey:"cloud.records.account.v1"); state = nil; lastSync = nil; message = CloudAccessError.accountChanged.localizedDescription }
    func tick() {
        guard enabled,!busy,Date() >= nextAttempt,library?.loadState == .ready,library?.reader == nil else { return }
        synchronize()
    }
    func synchronize(resolving: [String:SyncEntry] = [:]) {
        guard enabled,!busy,let account else { message = RecordSyncError.disabled.localizedDescription; return }
        busy = true; message = nil; nextAttempt = Date().addingTimeInterval(30)
        operation = Task {
            defer { busy = false }
            do {
                guard try await transport.account() == account else { throw CloudAccessError.accountChanged }
                guard let library else { throw CloudAccessError.unavailable }
                let result = try await library.synchronizeRecords(records,account:account,transport:transport,resolutions:resolving)
                try Task.checkCancellation(); guard enabled,self.account == account else { throw CloudAccessError.accountChanged }
                state = result; lastSync = Date(); message = "记录已同步；正文与资源通过完整备份恢复。"
            } catch {
                if !Task.isCancelled {
                    message = error.localizedDescription
                    if case CloudAccessError.accountChanged = error { accountChanged() }
                }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; operation?.cancel() }
}
