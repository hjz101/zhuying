import SwiftUI

struct SourceConfigurationView: View {
    @Environment(\.themeAppearance) private var appAppearance
    let sourceID: String
    @EnvironmentObject private var demo: FeatureDemoStore
    @EnvironmentObject private var library: LibraryStore
    @State private var name = ""
    @State private var address = ""
    @State private var group = ""
    @State private var enabled = true
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书源编辑", subtitle: "书山聚合 · 固定原生适配器", icon: "square.and.pencil")
                AppSettingsCard("基本信息", icon: "info.circle") {
                    TextField("书源名称", text: $name).accessibilityIdentifier("sourceConfigName")
                    TextField("HTTPS 服务地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("sourceConfigURL")
                    TextField("分组", text: $group).accessibilityIdentifier("sourceConfigGroup")
                    Toggle("启用书源", isOn: $enabled)
                }
                Text("仅支持书山聚合的小说接口。修改服务地址后需在登录页登录对应主机；任意规则和其他媒体保留原入口，当前不可运行。")
                    .font(.system(size: 12)).foregroundStyle(appAppearance.palette.muted)
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("sourceConfigMessage") }
                Button("保存书源") { Task { await save() } }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("sourceConfigSave")
            }.padding(22)
        }.appPageStyle().navigationTitle("书源编辑").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let source = demo.sources.first(where: { $0.id == sourceID }) { name = source.name; address = source.url; group = source.group; enabled = source.enabled }
            }
    }
    @MainActor private func save() async {
        do {
            let host = try ShushanClient.host(address)
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines), group = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 100, group.count <= 100, let index = demo.sources.firstIndex(where: { $0.id == sourceID }) else { throw ContentFailure.invalidResponse }
            demo.sources[index].name = title; demo.sources[index].url = host.absoluteString
            demo.sources[index].group = group.isEmpty ? "小说" : group; demo.sources[index].enabled = enabled
            let saved = await library.flushPendingWrites()
            message = saved ? "已保存书源基本信息。" : "保存失败，修改已保留，请重试。"
        } catch { message = error.localizedDescription }
    }
}
