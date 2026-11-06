import SwiftUI

struct ShareImportView: View {
    var request: ShareImportRequest? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var input = ""
    @State private var parsed: ShareImportRequest?
    @State private var data: Data?
    @State private var summary: String?
    @State private var message: String?
    @State private var operation: Task<Void,Never>?
    @State private var busy = false
    var body: some View {
        Group {
            if let target = request ?? parsed,target.kind == .file { SmartImportView(initialInput:target.url.isFileURL ? .file(target.url) : .remote(target.url)) }
            else {
                ScrollView {
                    VStack(alignment:.leading,spacing:23) {
                        AppPageHeader(title:"分享与链接",subtitle:"识别类型 · 预览校验 · 明确确认后导入",icon:"link")
                        AppSettingsCard("配置与选项",icon:"link") {
                            if let target = request ?? parsed { Text(target.kind == .source ? "书源配置" : "主题套装"); Text(target.url.host ?? "本地文件").font(.system(size:12)).foregroundStyle(Palette.muted) }
                            else { TextField("zhuying://import?kind=…&url=…",text:$input,axis:.vertical).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("shareURL") }
                        }
                        Button("预览链接") { preview() }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("sharePreview")
                        if let summary { Text(summary).font(.system(size:13)).accessibilityIdentifier("shareSummary") }
                        if data != nil { Button("确认导入") { confirm() }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("shareConfirm") }
                        if busy { ProgressView("正在读取"); Button("取消读取") { operation?.cancel(); busy = false } }
                        if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("shareMessage") }
                        Text("支持竹影分享 v1：file 文件、source 书源、theme 主题。收到链接只展示预览入口，确认前不保存配置或执行规则。其他阅读器链接需先转换为已支持的格式。")
                            .font(.system(size:12)).foregroundStyle(Palette.muted)
                    }.padding(22)
                }.appPageStyle().navigationTitle("分享与链接").navigationBarTitleDisplayMode(.inline)
            }
        }.onDisappear { operation?.cancel() }
    }
    private func preview() {
        operation?.cancel(); data = nil; summary = nil; message = nil
        do {
            let target = try request ?? parsed ?? ShareImportRequest.parse(URL(string:input) ?? URL(string:"invalid:")!)
            parsed = target; guard target.kind != .file else { return }; busy = true
            operation = Task {
                defer { if !Task.isCancelled { busy = false } }
                do {
                    let bytes = try await BoundedBookDownloader(maximumBytes:target.kind == .theme ? 3 * 1024 * 1024 : 5 * 1024 * 1024,format:.sourceJSON).fetch(target.url).data
                    try Task.checkCancellation()
                    if target.kind == .source { let p = try SourcePackages.parse(bytes,existing:demo.sources); summary = "可添加 \(p.sources.count) · 重复 \(p.duplicates) · 无效 \(p.invalid)" }
                    else { let p = try ThemePackageParser.parse(bytes,existingThemes:demo.themes,existingAssets:demo.themeAssets); summary = "主题 \(p.themes.count) · 样式 \(p.assets.count) · 无效 \(p.invalid)" }
                    data = bytes
                } catch { if !Task.isCancelled { message = error.localizedDescription } }
            }
        } catch { message = error.localizedDescription }
    }
    private func confirm() {
        guard let target = request ?? parsed,let data else { return }
        do {
            if target.kind == .source { let p = try SourcePackages.parse(data,existing:demo.sources); let count = demo.confirmSourceImport(p); message = "已导入 \(count) 个书源。" }
            else { let p = try demo.importThemeData(data); message = "已导入 \(p.added) 项。" }
            self.data = nil; Task { if !library.isDemo { let saved = await library.flushPendingWrites(); if !saved { message = "保存失败，请重试。" } } }
        } catch { message = error.localizedDescription }
    }
}
