import SwiftUI
import UniformTypeIdentifiers

struct ProductionBackupView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @State private var exportFile: ExportFile?
    @State private var importing = false
    @State private var pending: LibraryBackup?
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "本地备份", subtitle: "完整校验后恢复 · 原有数据保留回滚版本", icon: "archivebox")
                AppSettingsCard("备份内容", icon: "doc.text") {
                    Text("书架、导入正文、稳定进度、书签、分组、阅读偏好、字体和主题。")
                    Text("不含登录凭据或近期缓存。恢复会替换当前书库，其他设备需重新登录在线来源。仅支持竹影原生备份格式，不兼容其他软件的同名文件。")
                        .foregroundStyle(appAppearance.palette.muted)
                }.font(.system(size: 12)).lineSpacing(6)
                if busy { ProgressView("正在校验与处理备份") }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("backupMessage") }
                Button("创建本地备份") {
                    Task { await perform {
                        let data = try await library.createBackup()
                        exportFile = try ExportFile.prepare(data, filename: "竹影_" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "_" + UUID().uuidString.prefix(8) + ".zhuyingbackup")
                        message = "备份已生成，请选择保存位置。"
                    } }
                }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("backupCreate")
                Button("选择备份恢复") { importing = true }.buttonStyle(PrimaryButtonStyle(filled: false)).disabled(busy).accessibilityIdentifier("backupChooseRestore")
            }.padding(22)
        }.appPageStyle().navigationTitle("本地备份").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $exportFile) { file in
                NativeFileExporter(file: file) { result in
                    exportFile = nil
                    switch result {
                    case .success: message = "备份已导出。"
                    case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                    }
                }
            }
            .nativeFileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    Task { await perform {
                        let data = try await Task.detached { try ImportedFileReader.read(url, maximumBytes: LibraryBackup.maximumBytes) }.value
                        pending = try await Task.detached { try LibraryBackup.decode(data) }.value
                    } }
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                }
            }
            .confirmationDialog("恢复已校验备份？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("恢复备份（替换当前书库）", role: .destructive) {
                    guard let backup = pending else { return }; pending = nil
                    Task { await perform { try await library.restoreBackup(backup); message = "备份已恢复，原书库保留为回滚版本。" } }
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: { Text("包含 \(pending?.database.books.count ?? 0) 本书、\(pending?.database.bookmarks.count ?? 0) 条书签。登录凭据不恢复。") }
    }
    @MainActor private func perform(_ body: () async throws -> Void) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do { try await body() } catch { message = "操作未完成，已有书库保留：\(error.localizedDescription)" }
    }
}
