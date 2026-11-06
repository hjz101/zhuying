import SwiftUI

struct ProductionCacheView: View {
    var bookID: String? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var bytes = 0
    @State private var chapters = 0
    @State private var audioBytes = 0
    @State private var message: String?
    @State private var confirming = false
    @State private var clearingAudio = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "缓存管理", subtitle: "近期正文与一章预取 · 可重建内容", icon: "internaldrive")
                AppSettingsCard("空间占用", icon: "chart.pie") {
                    HStack { Label("章节", systemImage: "doc.text"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }.accessibilityIdentifier("actualCacheUsage")
                    HStack { Text("已缓存章节"); Spacer(); Text("\(chapters)") }
                    HStack { Label("图片", systemImage: "photo"); Spacer(); Text("未缓存") }
                    HStack { Label("音频", systemImage: "waveform"); Spacer(); Text(ByteCountFormatter.string(fromByteCount:Int64(audioBytes),countStyle:.file)) }.accessibilityIdentifier("actualAudioCacheUsage")
                }.font(.system(size: 12))
                Text("近期缓存最多 60 章、32 MiB；联网时超过 24 小时尝试更新，断网仍可读已缓存正文。当前章优先，预取失败不阻塞阅读。清理近期缓存会保留主动下载、导入正文、进度、收藏、书签、字体和主题。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                NavigationLink { ProductionDownloadView(bookID:bookID) } label: { Label("管理主动下载",systemImage:"arrow.down.circle") }.font(.system(size:13))
                Button(bookID == nil ? "清理近期章节缓存" : "清理当前作品缓存") { clearingAudio = false; confirming = true }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("clearRecentCache")
                Button("停止朗读并清理音频缓存") { clearingAudio = true; confirming = true }.buttonStyle(PrimaryButtonStyle(filled:false)).accessibilityIdentifier("clearAudioCache")
                if let message { Text(message).font(.system(size: 12)).accessibilityIdentifier("cacheMessage") }
            }.padding(22)
        }.appPageStyle().navigationTitle("缓存管理").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
            .confirmationDialog("确认清理？", isPresented: $confirming, titleVisibility: .visible) {
                if clearingAudio {
                    Button("停止并清理音频",role:.destructive) { Task { do { try await library.audio.clearCache(); await refresh(); message = "音频缓存已清理，阅读、主动下载和角色设置保留。" } catch { message = "清理未完成：\(error.localizedDescription)" } } }
                } else {
                    Button("只清理网络章节缓存", role: .destructive) { Task { do { try await library.onlineService?.clearCache(bookID: bookID); await refresh(); message = "缓存已清理，阅读记录和导入正文保留。" } catch { message = "清理未完成：\(error.localizedDescription)" } } }
                }
                Button("取消", role: .cancel) {}
            }
    }
    @MainActor private func refresh() async {
        let usage = await library.onlineService?.cacheUsage(); bytes = usage?.bytes ?? 0; chapters = usage?.chapters ?? 0
        audioBytes = (try? await library.audio.cacheBytes()) ?? 0
    }
}

struct ProductionFilesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var files: [LocalBookFile] = []
    @State private var message: String?
    @State private var renaming: LocalBookFile?
    @State private var newName = ""
    @State private var deleting: LocalBookFile?
    @State private var exportFile: ExportFile?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "文件管理", subtitle: "本地导入归档 · 不修改导入前原文件", icon: "folder")
                ForEach(files) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name).font(.system(size: 14))
                            Text("\(file.chapters) 章 · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            Button("阅读") { if let book = library.books.first(where: { $0.id == file.id }) { library.read(book) } }
                            Button("重命名") { newName = file.name; renaming = file }
                            Button("导出正文 TXT") { Task { await perform { exportFile = try ExportFile.prepare(try await library.exportLocalText(id: file.id), filename: safeFilename(file.name) + ".txt") } } }
                            Button("永久删除", role: .destructive) { deleting = file }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityIdentifier("file-actions-\(file.id)")
                    }.padding(13).background(.white.opacity(0.7), in: .rect(cornerRadius: 10))
                }
                if files.isEmpty { ContentUnavailableView("还没有导入文件", systemImage: "folder") }
                if busy { ProgressView() }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("fileMessage") }
                Text("PDF 归档为提取的文字，导出为 TXT。永久删除同时移除该作品的书架、历史、书签和正文；仅移出收藏请使用书架管理。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("文件管理").navigationBarTitleDisplayMode(.inline).disabled(busy)
            .task { await refresh() }
            .alert(renaming == nil ? "永久删除“\(deleting?.name ?? "")”？" : "重命名归档作品",
                   isPresented: Binding(get: { renaming != nil || deleting != nil }, set: { if !$0 { renaming = nil; deleting = nil } })) {
                if let file = renaming {
                    TextField("作品名称", text: $newName).accessibilityIdentifier("renameLocalFile")
                    Button("保存") { renaming = nil; Task { await perform { try await library.renameLocalBook(id: file.id, title: newName); await refresh() } } }
                    Button("取消", role: .cancel) { renaming = nil }
                } else if let file = deleting {
                    Button("删除作品、正文和阅读记录", role: .destructive) { deleting = nil; Task { await perform { try await library.permanentlyDeleteBook(id: file.id); await refresh() } } }
                    Button("取消", role: .cancel) { deleting = nil }
                }
            } message: { Text(renaming == nil ? "此操作仅影响 App 内归档，不修改原始文件。可先创建本地备份。" : "只修改归档作品名称，章节身份、进度与原始文件保留。") }
            .sheet(item: $exportFile) { file in
                NativeFileExporter(file: file) { result in
                    exportFile = nil
                    if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                }
            }
    }
    private func safeFilename(_ value: String) -> String { String(value.map { "/\\:\n\r".contains($0) ? "_" : $0 }.prefix(100)) }
    @MainActor private func refresh() async { do { files = try await library.localFiles() } catch { message = error.localizedDescription } }
    @MainActor private func perform(_ body: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await body() } catch { message = "操作未完成：\(error.localizedDescription)" }
    }
}
