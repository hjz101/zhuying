import SwiftUI

struct ProductionScriptTesterView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var shushan: ShushanAccountStore
    @State private var sourceID = ""
    @State private var network = false
    @State private var script = ""
    @State private var input = "null"
    @State private var output: String?
    @State private var message: String?
    @State private var busy = false
    @State private var host: NativeScriptHost?
    @State private var operation: Task<Void,Never>?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"JavaScript 宿主",subtitle:"Worker · 限时执行 · 来源隔离",icon:"chevron.left.forwardslash.chevron.right")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("书源作用域",selection:$sourceID) { Text("本地处理").tag(""); ForEach(library.sources) { Text($0.name).tag($0.id) } }.disabled(busy)
                    Toggle("允许访问所选书源",isOn:$network).disabled(sourceID.isEmpty || busy).accessibilityIdentifier("scriptNetwork")
                    Text("输入脚本函数体，使用 input 和 host，显式 return 返回结果。仅点击运行时执行；不会读取登录凭据。")
                        .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
                    TextEditor(text:$script).font(.system(size:12,design:.monospaced)).frame(minHeight:170).accessibilityIdentifier("scriptProgram")
                    Text("JSON 输入").font(.system(size:12))
                    TextEditor(text:$input).font(.system(size:12,design:.monospaced)).frame(minHeight:80).accessibilityIdentifier("scriptInput")
                }
                Button("运行脚本") { run() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || script.isEmpty).accessibilityIdentifier("scriptRun")
                if busy { ProgressView("正在执行"); Button("取消执行") { host?.cancel(); operation?.cancel(); busy = false }.accessibilityIdentifier("scriptCancel") }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("scriptMessage") }
                if let output { Text(output).font(.system(size:12,design:.monospaced)).textSelection(.enabled).accessibilityIdentifier("scriptOutput") }
                AppSettingsCard("兼容报告",icon:"checklist") { ForEach(NativeScriptHost.support,id:\.self) { Text($0).font(.system(size:12)).foregroundStyle(appAppearance.palette.muted) } }
            }.padding(22)
        }.appPageStyle().navigationTitle("JavaScript 宿主").navigationBarTitleDisplayMode(.inline)
            .onChange(of:sourceID) { _,_ in network = false; output = nil }
            .onDisappear { host?.cancel(); operation?.cancel() }
    }
    private func run() {
        guard let data = input.data(using:.utf8) else { return }
        let source = library.sources.first(where:{$0.id == sourceID}),origin = source.flatMap{try? ShushanClient.host($0.url)}
        let account = sourceID == "shushan" ? shushan.credentialForRequests.map{StableContentID.version($0.apiKey)} ?? "signed-out" : "public"
        let policy = ScriptHostPolicy(sourceID:sourceID.isEmpty ? "local-preview" : sourceID,origin:origin,accountID:account,network:network && origin != nil,timeout:network ? 5 : 1.5),program = script
        let transport: any HTTPTransport
        do { if let source { transport = try library.requestTransport(for:source,maximumBytes:1024 * 1024) } else { transport = BoundedAudioHTTPTransport(maximumBytes:1024 * 1024) } } catch { message = error.localizedDescription; return }
        let runner = NativeScriptHost(transport:transport); host = runner; busy = true; output = nil; message = nil
        operation = Task {
            defer { if !Task.isCancelled { busy = false; host = nil } }
            do { let bytes = try await runner.run(program,input:data,policy:policy); try Task.checkCancellation(); output = String(decoding:bytes,as:UTF8.self); message = "执行完成" }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
