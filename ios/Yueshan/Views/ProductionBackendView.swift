import SwiftUI

struct ProductionBackendView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var sourceID = ""
    @State private var profile = RemoteBackendProfile()
    @State private var key = ""
    @State private var message: String?
    @State private var confirm = false
    @State private var operation: Task<Void,Never>?
    @State private var busy = false
    private var source: DemoSource? { library.sources.first{$0.id == sourceID} }
    private var origin: URL? { source.flatMap{try? ShushanClient.host($0.url)} }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:23) {
            AppPageHeader(title:"远程后端",subtitle:"自建 HTTPS 服务 · 选定书源 · 明确回退策略",icon:"server.rack")
            AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                Picker("书源",selection:$sourceID) { ForEach(library.sources) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("backendSource")
                Toggle("启用此书源转发",isOn:$profile.enabled).accessibilityIdentifier("backendEnabled")
                TextField("https://reader.example",text:$profile.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("backendURL")
                SecureField("访问令牌（留空保留同地址密钥）",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("backendKey")
                Toggle("网络连接失败时允许直连",isOn:$profile.directFallback).accessibilityIdentifier("backendFallback")
                Button("保存配置") { if profile.enabled { confirm = true } else { save() } }.disabled(origin == nil || busy).accessibilityIdentifier("backendSave")
                Button("移除此源后端配置",role:.destructive) { guard let origin else { return }; do { try library.backendProfiles.reset(sourceID:sourceID,origin:origin); load(); message = "后端配置与当前访问令牌已移除。" } catch { message = error.localizedDescription } }.disabled(origin == nil || busy)
            }
            Button("连接测试") { test() }.buttonStyle(PrimaryButtonStyle()).disabled(origin == nil || busy).accessibilityIdentifier("backendTest")
            if busy { ProgressView("正在验证转发协议"); Button("取消") { operation?.cancel(); busy = false } }
            if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("backendMessage") }
            Text("启用后，所选源的原生读取、段评及明确允许联网的脚本请求会经自建服务；书源地址、查询、正文和该请求的认证头／已启用 Cookie 会被后端接收。登录密码和内置浏览器网页不走此转发。密钥仅保存在本机钥匙串，不进入分享、书库备份或日志。")
                .font(.system(size:12)).foregroundStyle(Palette.muted)
            Text("使用仓库附带 gateway v1 服务，并在服务端按书源 ID 与路径配置白名单。只支持 HTTPS、GET／POST、4 MiB响应；不支持重定向、WebSocket 或流式响应。与源代理／DNS／IP 互斥。直连回退默认关闭；开启后仅连接失败／超时回退，认证错误、证书错误、协议错误及上游状态不会回退。")
                .font(.system(size:12)).foregroundStyle(Palette.muted)
            Text("当前书源 ID：\(sourceID)").font(.system(size:11,design:.monospaced)).textSelection(.enabled)
        }.padding(22) }.appPageStyle().navigationTitle("远程后端").navigationBarTitleDisplayMode(.inline)
            .onAppear { sourceID = library.sources.first?.id ?? ""; load() }
            .onChange(of:sourceID) { _,_ in operation?.cancel(); busy = false; load() }
            .onDisappear { operation?.cancel(); key = "" }
            .confirmationDialog("允许此后端接收所选书源请求及其认证信息？",isPresented:$confirm,titleVisibility:.visible) { Button("确认并保存") { save() }; Button("取消",role:.cancel) {} }
    }
    private func load() { key = ""; guard let origin else { return }; do { profile = try library.backendProfiles.profile(sourceID:sourceID,origin:origin); message = nil } catch { message = error.localizedDescription } }
    private func save() { guard let origin else { return }; do { if profile.enabled,try library.networkProfiles.profile(sourceID:sourceID,origin:origin).mode != .system { throw RemoteBackendError.conflictingRoute }; try library.backendProfiles.save(profile,key:key,sourceID:sourceID,origin:origin); key = ""; message = "此书源后端配置已保存。" } catch { message = error.localizedDescription } }
    private func test() {
        guard let source,let origin else { return }; busy = true; message = nil
        operation = Task { defer { if !Task.isCancelled { busy = false } }; do {
            let saved = try library.backendProfiles.profile(sourceID:sourceID,origin:origin); guard saved.enabled else { throw RemoteBackendError.invalid }
            let transport = try library.requestTransport(for:source,maximumBytes:4 * 1024 * 1024)
            let (_,response) = try await transport.send(URLRequest(url:origin)); try Task.checkCancellation(); message = "转发协议已通过，上游返回 HTTP \(response.statusCode)。具体书源接口仍需书源调试验证。"
        } catch { if !Task.isCancelled { message = error.localizedDescription } } }
    }
}
