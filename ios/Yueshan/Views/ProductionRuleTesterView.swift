import SwiftUI

struct ProductionRuleTesterView: View {
    @State private var kind = ExtractionRule.Kind.css
    @State private var expression = "p"
    @State private var input = ""
    @State private var output: [String] = []
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"规则兼容测试",subtitle:"v1 · 本地解析 · 不执行网页脚本",icon:"curlybraces")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("解析器",selection:$kind) { ForEach(ExtractionRule.Kind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    TextField("表达式",text:$expression).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("ruleExpression")
                    TextEditor(text:$input).frame(minHeight:150).font(.system(size:12,design:.monospaced)).accessibilityIdentifier("ruleInput")
                    Button("解析输入") { parse() }.disabled(busy || input.isEmpty || expression.isEmpty).accessibilityIdentifier("ruleParse")
                }
                if busy { ProgressView("正在解析") }
                if let message { Text(message).font(.system(size:12)).accessibilityIdentifier("ruleResult") }
                if !output.isEmpty { Text(output.joined(separator:"\n")).font(.system(size:13)).textSelection(.enabled).accessibilityIdentifier("ruleOutput") }
                AppSettingsCard("支持范围",icon:"checklist") { ForEach(RuleExtraction.support,id:\.self) { Text($0).font(.system(size:12)).foregroundStyle(Palette.muted) } }
            }.padding(22)
        }.appPageStyle().navigationTitle("规则兼容测试").navigationBarTitleDisplayMode(.inline).onDisappear { operation?.cancel() }
    }
    private func parse() {
        operation?.cancel(); busy = true; output = []; message = nil
        let rule = ExtractionRule(kind:kind,expression:expression),source = input
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let worker = Task.detached { try RuleExtraction.extract(rule,from:source) }
                let result = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation(); output = result; message = "解析完成 · \(result.count) 项"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
