import SwiftUI

struct ProductionNetworkView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var sourceID = ""
    @State private var profile = SourceNetworkProfile()
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    private var source: DemoSource? { library.sources.first{$0.id == sourceID} }
    private var origin: URL? { source.flatMap{try? ShushanClient.host($0.url)} }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"网络配置",subtitle:"书源级代理 · DNS／IP · HTTPS 主机验证",icon:"network")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("书源",selection:$sourceID) { ForEach(library.sources) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("networkSource")
                    Picker("连接方式",selection:Binding(get:{profile.mode},set:{profile.mode = $0; profile.server = ""; profile.port = $0 == .dns ? 53 : 7890})) { ForEach(SourceNetworkProfile.Mode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("networkMode")
                    if profile.mode != .system {
                        TextField(profile.mode == .proxy ? "代理主机（不含端口）" : profile.mode == .dns ? "DNS 服务器 IP" : "指定 IPv4／IPv6",text:$profile.server).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("networkServer")
                        if profile.mode != .fixedIP { TextField("端口",text:Binding(get:{String(profile.port)},set:{profile.port = Int($0) ?? 0})).keyboardType(.numberPad).accessibilityIdentifier("networkPort") }
                    }
                    Button("保存此书源配置") { save() }.disabled(origin == nil || busy).accessibilityIdentifier("networkSave")
                    Button("恢复系统网络") { if let origin { library.networkProfiles.reset(sourceID:sourceID,origin:origin); profile = .init(); message = "此书源已恢复系统网络。" } }.disabled(origin == nil || busy).accessibilityIdentifier("networkReset")
                }
                Button("测试 HTTPS 连接") { test() }.buttonStyle(PrimaryButtonStyle()).disabled(origin == nil || busy).accessibilityIdentifier("networkTest")
                if busy { ProgressView("正在测试当前配置"); Button("取消") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("networkMessage") }
                Text("只作用于所选书源：原生读取、登录、段评、允许联网的脚本与该源浏览器。指定 IP／DNS 使用本机专用 CONNECT 隧道，原始 HTTPS 主机、SNI 与证书校验保留；不会关闭证书验证或修改系统 DNS。代理／DNS 不可用时报错，不自动直连。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
                Text("v1 支持无认证 HTTP CONNECT、IPv4／IPv6 固定地址及 UDP DNS 的 A／AAAA／CNAME。DNS 服务器需填 IP，可指定端口；不支持 DoH／DoT、DNS TCP 回退或代理用户名密码。浏览器仅当前主机走自定义路由，跨站资源按系统网络处理；配置为本设备所有，书库备份不复制局域网地址。测试连接只报告网络状态，书源可读性请用书源调试。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("网络配置").navigationBarTitleDisplayMode(.inline)
            .onAppear { sourceID = library.sources.first?.id ?? ""; load() }
            .onChange(of:sourceID) { _,_ in operation?.cancel(); busy = false; load() }
            .onDisappear { operation?.cancel() }
    }
    private func load() { guard let origin else { return }; do { profile = try library.networkProfiles.profile(sourceID:sourceID,origin:origin); message = nil } catch { message = "未加载配置，请恢复系统网络后重试。" } }
    private func save() { guard let origin else { return }; do { try library.networkProfiles.save(profile,sourceID:sourceID,origin:origin); message = "此书源配置已保存。" } catch { message = error.localizedDescription } }
    private func test() {
        guard let origin else { return }; let current = profile
        busy = true; message = nil
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do { let transport = try SourceNetworkTransport(origin:origin,profile:current,maximumBytes:2 * 1024 * 1024); var request = URLRequest(url:origin); request.timeoutInterval = 15; let (_,response) = try await transport.send(request); try Task.checkCancellation(); message = "HTTPS 返回 HTTP \(response.statusCode)。网络连接已完成，书源权限与正文需另验。" } catch { if !Task.isCancelled { message = "连接未通过：\(error.localizedDescription)" } }
        }
    }
}
