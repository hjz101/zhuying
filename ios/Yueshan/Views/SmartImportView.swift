import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum ImportSource: String, CaseIterable { case local = "本地文件", link = "链接导入", clipboard = "剪贴板" }

struct SmartImportView: View {
    var openPickerOnAppear = false
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = BookImportSession()
    @State private var source = ImportSource.local
    @State private var showingFiles = false
    @State private var showingHelp = false
    @State private var link = ""
    @State private var group = "未分组"
    @State private var encoding = ImportEncoding.automatic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("导入来源", selection: $source) {
                    ForEach(ImportSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("importSource").disabled(session.busy)
                sourceEntry.disabled(session.busy)
                if !session.items.isEmpty { fileList; destination }
                if let message = session.message {
                    Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("importMessage")
                }
                if session.finished {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(session.summary).font(.system(size: 14, weight: .medium)).accessibilityIdentifier("importSummary")
                        if session.failedCount > 0 {
                            Button("重试失败项") { retry() }.font(.system(size: 13)).accessibilityIdentifier("importRetry")
                        }
                        if session.readyCount > 0 { Text("未选中的文件仍在清单中，可继续导入。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.soft, in: .rect(cornerRadius: 12))
                }
                DisclosureGroup("更多选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("TXT 编码", selection: $encoding) { ForEach(ImportEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .font(.system(size: 13)).accessibilityIdentifier("importEncoding")
                        Text("编码用于下一次识别或重试；TXT 自动识别章节，PDF 按提取出的正文阅读。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.padding(.top, 10)
                }.font(.system(size: 13)).disabled(session.busy)
            }.padding(22)
        }.appPageStyle().navigationTitle("智能导入").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { primaryAction }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { showingHelp = true } label: { Image(systemName: "questionmark.circle") }.accessibilityLabel("导入帮助")
            } }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): if !urls.isEmpty { add(urls.map { .file($0) }) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { session.message = "未能选择文件：\(error.localizedDescription)" }
                }
            }
            .onAppear { if openPickerOnAppear { showingFiles = true } }
            .onChange(of: source) { _, _ in session.message = nil }
            .sheet(isPresented: $showingHelp) { help }
    }

    @ViewBuilder private var sourceEntry: some View {
        switch source {
        case .local:
            if session.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 34, weight: .light))
                    Text("把喜欢的故事带进书架").font(.system(size: 20, design: .serif))
                    Text("从“文件”选择，可浏览我的 iPhone、iCloud 等位置。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    Button("选择文件") { showingFiles = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("importChooseFiles")
                    Text("可多选 · TXT / 文字 PDF · 单个文件 ≤ 20 MB")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity).padding(22).background(Palette.card, in: .rect(cornerRadius: 16))
            } else {
                HStack {
                    Text("从本机或 iCloud 继续选择").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("继续添加", systemImage: "plus") { showingFiles = true }.font(.system(size: 12)).accessibilityIdentifier("importAddFiles")
                }.disabled(session.busy)
            }
        case .link:
            VStack(alignment: .leading, spacing: 14) {
                Text("粘贴文件直链").font(.system(size: 20, design: .serif))
                TextField("https://…/小说.txt", text: $link, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(14).background(Palette.card, in: .rect(cornerRadius: 10)).accessibilityIdentifier("importLinkInput")
                HStack {
                    Button("粘贴链接") { link = UIPasteboard.general.string ?? "" }.accessibilityIdentifier("importPasteLink")
                    Spacer()
                    Button("识别链接") { recognizeLink() }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("importRecognizeLink")
                }.font(.system(size: 13))
                Text("支持 TXT、文字 PDF 的 https 下载链接。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.disabled(session.busy)
        case .clipboard:
            VStack(alignment: .leading, spacing: 14) {
                Text("导入刚刚复制的内容").font(.system(size: 20, design: .serif))
                Text("点击后读取，可识别文件链接或保存纯文本正文。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button("读取剪贴板", systemImage: "doc.on.clipboard") { readClipboard() }
                    .buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("importReadClipboard")
            }.disabled(session.busy)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导入预览 · \(session.items.count) 项").font(.system(size: 15, weight: .medium))
                Spacer()
                if session.failedCount > 0 && !session.finished { Button("重试失败项") { retry() }.font(.system(size: 12)).accessibilityIdentifier("importRetry") }
            }
            ForEach(session.items) { item in
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            if session.selection.contains(item.id) { session.selection.remove(item.id) } else { session.selection.insert(item.id) }
                        } label: { Image(systemName: session.selection.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 21)).frame(minHeight: 44) }
                            .disabled(item.status != .ready || session.busy).accessibilityLabel("选择\(item.input.name)")
                            .accessibilityValue(session.selection.contains(item.id) ? "已选择" : "未选择")
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.input.name).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            if let prepared = item.prepared {
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(prepared.bytes), countStyle: .file)) · \(prepared.encoding) · \(prepared.book.chapters.count) 章")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            Text(statusText(item.status)).font(.system(size: 11)).foregroundStyle(item.status == .ready || item.status == .imported ? Palette.green : Palette.accent)
                                .accessibilityIdentifier("importStatus-\(item.input.name)")
                            if let book = item.prepared?.book, item.status == .ready {
                                Text(book.content.first?.first ?? "").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { session.remove(item.id, library: library) } label: { Image(systemName: "xmark").frame(width: 32, height: 44) }
                            .accessibilityLabel("移除\(item.input.name)").disabled(session.busy)
                    }
                    Divider()
                }
            }
        }
    }

    private var destination: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入到 · 小说书架").font(.system(size: 13))
                Text("当前支持文本作品").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Picker("加入分组", selection: $group) {
                ForEach(["未分组"] + demo.groups, id: \.self) { Text($0).tag($0) }
            }.font(.system(size: 12)).accessibilityIdentifier("importDestination")
        }.padding(14).background(Palette.card, in: .rect(cornerRadius: 12)).disabled(session.busy)
    }

    private var primaryAction: some View {
        VStack(spacing: 8) {
            if session.busy { HStack { ProgressView(); Text(session.progressText).font(.system(size: 12)) }.accessibilityIdentifier("importProgress") }
            if session.readyCount > 0 {
                Button("导入选中的 \(session.readyCount) 项") { Task { await session.commit(library: library, group: group) } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(session.busy).accessibilityIdentifier("importConfirm")
            } else if session.items.contains(where: { $0.status == .imported }) {
                Button("查看书架") { NotificationCenter.default.post(name: .showImportedShelf, object: nil); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("importShowShelf")
            } else if source == .local && session.items.isEmpty {
                EmptyView()
            } else {
                Text(session.items.isEmpty ? "先选择来源并识别内容" : "请选择可导入的文件")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).frame(minHeight: 44)
            }
        }.padding(.horizontal, 22).padding(.vertical, 12).frame(maxWidth: .infinity).background(Palette.background)
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("选择 → 预览 → 导入").font(.system(size: 23, design: .serif))
                    Text("本地文件通过系统“文件”选择，可多选；iCloud 文件需要先完成下载。取消选择不会改变书架。")
                    Text("TXT 支持 UTF-8、UTF-16 和 GB18030；PDF 提取文字后使用文本阅读器。扫描版、加密 PDF、EPUB、漫画与压缩包暂不支持实际解析。")
                    Text("重复内容会跳过。确认导入后，正文保存在 App 内，阅读进度在重启后保留。移除预览只影响本次清单，不删除原文件。")
                    Text("书源、主题等专用内容，请从对应的管理页面导入。")
                }.font(.system(size: 14)).lineSpacing(6).padding(22)
            }.appPageStyle().navigationTitle("导入帮助").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingHelp = false } } }
        }
    }

    private func add(_ inputs: [BookImportInput]) { Task { await session.add(inputs, encoding: encoding, library: library) } }
    private func retry() { Task { await session.retry(encoding: encoding, library: library) } }
    private func recognizeLink() {
        do { add([.remote(try BookImporter.remoteURL(link))]) } catch { session.message = error.localizedDescription }
    }
    private func readClipboard() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            session.message = "剪贴板中没有可导入的文字或链接。"; return
        }
        if value.contains("://"), !value.contains("\n") {
            do { add([.remote(try BookImporter.remoteURL(value))]) } catch { session.message = error.localizedDescription }
        } else { add([.text(value)]) }
    }
    private func statusText(_ status: ImportItemStatus) -> String {
        switch status {
        case .ready: "可导入"; case .duplicate: "内容重复，已跳过"; case .imported: "已导入书架"; case .failed(let message): message
        }
    }
}

extension Notification.Name { static let showImportedShelf = Notification.Name("showImportedShelf") }
