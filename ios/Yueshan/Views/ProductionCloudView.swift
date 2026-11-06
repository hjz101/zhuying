import SwiftUI

struct ProductionCloudView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var files: [CloudFile] = []
    @State private var account: String?
    @State private var message: String?
    @State private var busy = false
    @State private var pending: LibraryBackup?
    @State private var pendingAccount: String?
    @State private var deleting: CloudFile?
    @State private var operation: Task<Void,Never>?
    private let store = CloudBackupStore()
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"iCloud",subtitle:"云端备份 · 校验下载 · 恢复书库",icon:"icloud")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Text(account == nil ? "尚未连接 iCloud" : "已连接当前设备 iCloud 账号").font(.system(size:13)).accessibilityIdentifier("cloudAccountStatus")
                    Button("刷新云端备份") { refresh() }.disabled(busy).accessibilityIdentifier("cloudRefresh")
                    Button("备份到 iCloud") { save() }.disabled(account == nil || busy).accessibilityIdentifier("cloudSave")
                }
                AppSettingsCard("备份记录",icon:"archivebox") {
                    if files.isEmpty { Text("当前没有已读取的云端备份。").font(.system(size:12)) }
                    ForEach(files) { file in
                        VStack(alignment:.leading,spacing:10) {
                            Text(file.modified,style:.date).font(.system(size:14))
                            Text("\(ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file)) · \(file.downloaded ? "可读取" : "待下载")").font(.system(size:11)).foregroundStyle(Palette.muted)
                            HStack { Button("下载并校验") { prepare(file) }.disabled(busy); Spacer(); Button("删除",role:.destructive) { deleting = file }.disabled(busy) }
                        }.padding(.vertical,7)
                    }
                }
                if busy { ProgressView("正在处理云端文件"); Button("取消") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("cloudMessage") }
                NavigationLink { ProductionBackupView() } label: { Label("本地备份与恢复",systemImage:"externaldrive") }
                Text("备份包含正文、页面资源、书架、进度、书签、主题与字体，不包含登录凭据和服务密钥。下载完成并通过完整校验后，仍需确认才替换本地书库；旧书库保留为回滚版本。记录同步单独开关，正文和资源通过显式备份恢复。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("iCloud").navigationBarTitleDisplayMode(.inline)
            .onAppear { refresh() }.onDisappear { operation?.cancel() }
            .onReceive(NotificationCenter.default.publisher(for:NSNotification.Name.NSUbiquityIdentityDidChange)) { _ in operation?.cancel(); account = nil; files = []; pending = nil; pendingAccount = nil; busy = false; message = CloudAccessError.accountChanged.localizedDescription }
            .confirmationDialog("恢复已校验云端备份？",isPresented:Binding(get:{pending != nil},set:{if !$0 { pending = nil; pendingAccount = nil }}),titleVisibility:.visible) {
                Button("恢复备份（替换当前书库）",role:.destructive) {
                    guard let backup = pending,let expected = pendingAccount else { return }; pending = nil; pendingAccount = nil
                    perform {
                        guard try await store.transport.account() == expected else { throw CloudAccessError.accountChanged }
                        try await library.restoreBackup(backup); message = "云端备份已恢复。"
                    }
                }
                Button("取消",role:.cancel) { pending = nil; pendingAccount = nil }
            } message: { Text("包含 \(pending?.database.books.count ?? 0) 本作品；当前书库将在确认后替换。") }
            .confirmationDialog("删除此云端备份？",isPresented:Binding(get:{deleting != nil},set:{if !$0 { deleting = nil }}),titleVisibility:.visible) {
                Button("删除云端备份",role:.destructive) { guard let file = deleting,let account else { return }; deleting = nil; perform { try await store.delete(file.id,account:account); try await list(); message = "云端备份已删除，本地书库保留。" } }
                Button("取消",role:.cancel) { deleting = nil }
            }
    }
    private func refresh() { perform { account = nil; files = []; try await list() } }
    private func list() async throws { let result = try await store.list(); try Task.checkCancellation(); account = result.account; files = result.files }
    private func save() {
        guard let account else { return }
        perform { let bytes = try await library.createBackup(); try Task.checkCancellation(); _ = try await store.save(LibraryBackup.decode(bytes),account:account); try await list(); message = "备份文件已写入 iCloud Drive，上传状态由系统继续处理。" }
    }
    private func prepare(_ file: CloudFile) { guard let account else { return }; perform { let value = try await store.restore(file.id,account:account); try Task.checkCancellation(); pendingAccount = account; pending = value; message = "下载校验通过，等待恢复确认。" } }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        operation = Task { defer { if !Task.isCancelled { busy = false } }; do { try await body() } catch { if !Task.isCancelled { message = error.localizedDescription } } }
    }
}
