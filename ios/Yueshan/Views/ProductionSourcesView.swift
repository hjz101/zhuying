import SwiftUI
import UniformTypeIdentifiers

struct ProductionSourceAccessView: View {
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"访问说明",subtitle:"自定义书源 · 原生 JSON v1",icon:"person.badge.key")
                AppSettingsCard("公开访问",icon:"info.circle") {
                    Text("原生 JSON v1 书源使用公开 HTTPS 接口，无需登录。当前不运行导入规则中的脚本、Cookie 或请求头；需要账号的站点请使用已有书山登录入口。")
                        .font(.system(size:13)).lineSpacing(6)
                }
            }.padding(22)
        }.appPageStyle().navigationTitle("访问说明").navigationBarTitleDisplayMode(.inline)
    }
}

struct ProductionSourceImportView: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    @EnvironmentObject private var library: LibraryStore
    @State private var method = "URL"
    @State private var address = ""
    @State private var json = ""
    @State private var preview: SourceImportPreview?
    @State private var message: String?
    @State private var choosing = false
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    @State private var export: ExportFile?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书源导入导出", subtitle: "预览确认 · 版本校验 · 未支持规则保留但不执行", icon: "arrow.up.arrow.down.circle")
                AppSettingsCard("配置与选项", icon: "slider.horizontal.3") {
                    Picker("导入方式", selection: $method) { ForEach(["URL","JSON 文件","JSON 源码"], id: \.self) { Text($0) } }.pickerStyle(.segmented).accessibilityIdentifier("sourcePackageMethod")
                    if method == "URL" { TextField("HTTPS 书源文件链接", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("sourcePackageURL") }
                    if method == "JSON 源码" { TextEditor(text: $json).frame(minHeight: 180).font(.system(size: 12, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("sourcePackageJSON") }
                }
                if method == "JSON 文件" { Button("选择 JSON 文件") { choosing = true }.buttonStyle(PrimaryButtonStyle(filled: false)) }
                Button("预览导入") { load() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || method == "JSON 文件").accessibilityIdentifier("sourcePackagePreview")
                if busy { ProgressView("正在读取书源文件"); Button("取消") { operation?.cancel(); busy = false } }
                if let preview {
                    AppSettingsCard("导入预览", icon: "list.bullet") {
                        Text("可添加 \(preview.sources.count) · 重复 \(preview.duplicates) · 无效 \(preview.invalid)").font(.system(size: 12))
                        ForEach(preview.sources) { source in VStack(alignment: .leading) { Text(source.name); Text(source.detail).font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                    }
                    Button("确认导入") {
                        Task { let count = demo.confirmSourceImport(preview); self.preview = nil; message = await library.flushPendingWrites() ? "已保存 \(count) 个书源。" : "保存失败，请重试。" }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("sourcePackageConfirm")
                }
                Button("导出书源 JSON") { do { export = try ExportFile.prepare(SourcePackages.export(demo.sources), filename: "阅山书源.json") } catch { message = error.localizedDescription } }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("sourcePackageMessage") }
            }.padding(22)
        }.appPageStyle().navigationTitle("书源导入导出").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    operation?.cancel(); operation = Task {
                        do {
                            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= 5 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
                            preview = try SourcePackages.parse(Data(contentsOf: url), existing: demo.sources)
                        } catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }
            }
            .sheet(item: $export) { file in NativeFileExporter(file: file) { _ in export = nil } }
            .onDisappear { operation?.cancel() }
    }
    private func load() {
        preview = nil; message = nil; busy = true; operation?.cancel()
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let bytes: Data
                if method == "JSON 源码" { bytes = Data(json.utf8) }
                else { bytes = try await BoundedBookDownloader(format:.sourceJSON).fetch(BookImporter.remoteURL(address)).data }
                try Task.checkCancellation(); preview = try SourcePackages.parse(bytes, existing: demo.sources)
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

struct ProductionSourceRuleEditor: View {
    let sourceID: String
    @EnvironmentObject private var demo: FeatureDemoStore
    @EnvironmentObject private var library: LibraryStore
    @State private var json = ""
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书源编辑", subtitle: "基本信息 · 规则字段 · JSON 校验", icon: "square.and.pencil")
                AppSettingsCard("JSON 源码", icon: "curlybraces") { TextEditor(text: $json).frame(minHeight: 300).font(.system(size: 12, design: .monospaced)).accessibilityIdentifier("sourceRulesJSON") }
                Text("支持原生 JSON v1 和 extract-v1 的搜索、详情、目录、正文接口；解析规则支持 CSS／XPath／JSONPath／正则的已声明子集。其他阅读器方言可以保存导出，不会自动执行。修改后需点击保存，返回即取消。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button("校验 JSON") { validate(save: false) }.buttonStyle(PrimaryButtonStyle(filled: false))
                Button("保存书源") { validate(save: true) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("sourceRulesSave")
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("sourceRulesMessage") }
            }.padding(22)
        }.appPageStyle().navigationTitle("书源编辑").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard let source = demo.sources.first(where: { $0.id == sourceID }), let data = try? SourcePackages.export([source]),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String:Any], let rows = object["sources"] as? [[String:Any]], let row = rows.first,
                      let value = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys,.prettyPrinted]) else { return }
                json = String(decoding: value, as: UTF8.self)
            }
    }
    private func validate(save: Bool) {
        do {
            let preview = try SourcePackages.parse(Data(json.utf8), existing: demo.sources.filter { $0.id != sourceID })
            guard var source = preview.sources.first, preview.sources.count == 1, preview.invalid == 0, let index = demo.sources.firstIndex(where: { $0.id == sourceID }) else { throw ContentFailure.invalidResponse }
            source = .init(id: sourceID, name: source.name, group: source.group, enabled: source.enabled, detail: source.detail, url: source.url, kind: source.kind, configuration: source.configuration)
            if save { demo.sources[index] = source; Task { message = await library.flushPendingWrites() ? "已保存有效配置。\(source.detail)" : "保存失败，请重试。" } }
            else { message = "JSON 有效。\(source.detail)" }
        } catch { message = "未保存：\(error.localizedDescription)" }
    }
}
