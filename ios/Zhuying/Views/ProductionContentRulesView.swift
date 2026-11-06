import SwiftUI
import UniformTypeIdentifiers

struct ProductionContentRulesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var rules: [ContentProcessingRule] = []
    @State private var editing: ContentProcessingRule?
    @State private var importing = false
    @State private var pending: [ContentProcessingRule]?
    @State private var export: ExportFile?
    @State private var message: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"正文净化",subtitle:"正则／JS · 顺序与作用域 · 原文保留",icon:"line.3.horizontal.decrease")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Button("添加规则") { editing = .init(name:"新规则",pattern:"") }.accessibilityIdentifier("purifyAdd")
                    HStack { Button("导入规则") { importing = true }; Spacer(); Button("导出规则") { do { export = try ExportFile.prepare(ContentProcessingStore.encode(rules),filename:"正文净化规则.json") } catch { message = error.localizedDescription } } }
                }
                AppSettingsCard("规则顺序",icon:"list.number") {
                    if rules.isEmpty { Text("还没有净化规则，当前保留原文。").font(.system(size:12)) }
                    ForEach(Array(rules.enumerated()),id:\.element.id) { index,rule in
                        VStack(alignment:.leading,spacing:9) {
                            Toggle(isOn:Binding(get:{rule.enabled},set:{ value in var next = rules; next[index].enabled = value; commit(next) })) { Button(rule.name) { editing = rule }.accessibilityIdentifier("purify-edit-" + rule.id) }
                            Text("\(rule.kind.rawValue) · \(rule.scope.rawValue)").font(.system(size:11)).foregroundStyle(Palette.muted)
                            HStack {
                                Button("上移") { var next = rules; next.swapAt(index,index - 1); commit(next) }.disabled(index == 0)
                                Button("下移") { var next = rules; next.swapAt(index,index + 1); commit(next) }.disabled(index + 1 == rules.count)
                                Spacer(); Button("删除",role:.destructive) { commit(rules.filter{$0.id != rule.id}) }
                            }.font(.system(size:11))
                        }.padding(.vertical,7)
                    }
                }.disabled(busy)
                if busy { ProgressView("正在保存") }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("purifyMessage") }
                Text("按列表顺序处理符合范围的规则。最多启用 20 条，其中 JS 最多 2 条；JS 禁止联网。原文不改写，净化结果可重建，全文搜索与朗读使用同一结果。规则变化先尝试按原文上下文重定位，无法唯一匹配时需明确选章或从章首打开。异常保留上次有效结果或原文，规则随完整备份保存。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("正文净化").navigationBarTitleDisplayMode(.inline)
            .task { do { rules = try await library.contentProcessor.rules(); message = await library.contentProcessor.message } catch { message = "规则未载入，原文件保留：\(error.localizedDescription)" } }
            .sheet(item:$editing) { rule in NavigationStack { ContentRuleEditor(rule:rule) { value in var next = rules; if let index = next.firstIndex(where:{$0.id == value.id}) { next[index] = value } else { next.append(value) }; try await save(next) } } }
            .sheet(item:$export) { file in NativeFileExporter(file:file) { _ in export = nil } }
            .nativeFileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
                do { pending = try ContentProcessingStore.decode(ImportedFileReader.read(result.get(), maximumBytes: 512 * 1024)) }
                catch { if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription } }
            }
            .confirmationDialog("导入 \(pending?.count ?? 0) 条净化规则？",isPresented:Binding(get:{pending != nil},set:{if !$0 { pending = nil }}),titleVisibility:.visible) {
                Button("导入并保持停用") { guard let pending else { return }; self.pending = nil; let known = Set(rules.map(\.id)),added = pending.filter{!known.contains($0.id)}.map { value in var item = value; item.enabled = false; return item }; commit(rules + added) }
                Button("取消",role:.cancel) { pending = nil }
            } message: { Text("同 ID 跳过；核对内容后逐条启用。导入时不执行脚本。") }
    }
    private func save(_ values: [ContentProcessingRule]) async throws { try await library.contentProcessor.save(values); rules = values; message = "规则已保存。" }
    private func commit(_ values: [ContentProcessingRule]) { guard !busy else { return }; busy = true; Task { defer { busy = false }; do { try await save(values) } catch { message = "未保存，已有规则保留：\(error.localizedDescription)" } } }
}

private struct ContentRuleEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var rule: ContentProcessingRule
    let onSave: (ContentProcessingRule) async throws -> Void
    @State private var sample = ""
    @State private var preview: String?
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                AppSettingsCard("规则内容",icon:"pencil") {
                    TextField("规则名称",text:$rule.name).accessibilityIdentifier("purifyName")
                    Picker("类型",selection:$rule.kind) { ForEach(ContentProcessingRule.Kind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    Picker("作用域",selection:$rule.scope) { ForEach(ContentProcessingRule.Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    if rule.scope == .book { Picker("目标书籍",selection:Binding(get:{rule.bookID ?? ""},set:{rule.bookID = $0.isEmpty ? nil : $0})) { Text("选择书籍").tag(""); ForEach(library.books) { Text($0.title).tag($0.id) } } }
                    if rule.scope == .source { Picker("目标书源",selection:Binding(get:{rule.sourceID ?? ""},set:{rule.sourceID = $0.isEmpty ? nil : $0})) { Text("选择书源").tag(""); ForEach(library.sources) { Text($0.name).tag($0.id) } } }
                    Text(rule.kind == .regex ? "正则表达式" : "脚本接收 [{id,text}]，返回保留 id 和相对顺序的数组；可删除条目。网络始终关闭。").font(.system(size:12)).foregroundStyle(Palette.muted)
                    TextEditor(text:$rule.pattern).font(.system(size:12,design:.monospaced)).frame(minHeight:120).accessibilityIdentifier("purifyPattern")
                    if rule.kind == .regex { TextField("替换为（可留空）",text:$rule.replacement).accessibilityIdentifier("purifyReplacement") }
                    Toggle("启用规则",isOn:$rule.enabled).accessibilityIdentifier("purifyEnabled")
                }.disabled(busy)
                AppSettingsCard("导入预览",icon:"doc.text.magnifyingglass") {
                    TextEditor(text:$sample).font(.system(size:12)).frame(minHeight:100).accessibilityIdentifier("purifySample")
                    Button("预览净化结果") { runPreview() }.disabled(busy || sample.isEmpty).accessibilityIdentifier("purifyPreview")
                    if let preview { Text(preview).font(.system(size:13)).textSelection(.enabled).accessibilityIdentifier("purifyPreviewOutput") }
                }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("purifyEditorMessage") }
                Button("保存规则") { busy = true; operation = Task { defer { busy = false }; do { try rule.validate(); try await onSave(rule); dismiss() } catch { message = error.localizedDescription } } }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("purifySave")
                if busy { ProgressView(); Button("取消处理") { operation?.cancel(); busy = false } }
            }.padding(22)
        }.appPageStyle().navigationTitle("净化规则").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("取消") { dismiss() } } }.onDisappear { operation?.cancel() }
    }
    private func runPreview() {
        do { try rule.validate() } catch { message = error.localizedDescription; return }
        var copy = rule; copy.enabled = true; copy.scope = .all
        let document = ChapterDocument(chapterID:"preview",paragraphs:sample.components(separatedBy:"\n").filter{!$0.isEmpty}),id = UUID().uuidString
        busy = true; message = nil; preview = nil
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            let processor = ContentProcessingStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(id),previewRules:[copy])
            do { let result = try await processor.process(document,bookID:"preview-" + id,sourceID:nil); try Task.checkCancellation(); preview = result.document.paragraphs.map(\.text).joined(separator:"\n"); message = await processor.message ?? "预览完成，尚未保存。" } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
