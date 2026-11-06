import SwiftUI

struct LegadoSourceLoginRoute: View {
    let sourceID: String
    @EnvironmentObject private var library: LibraryStore
    @State private var model: LegadoLoginFormModel?
    @State private var error: String?
    private var source: DemoSource? { library.sources.first { $0.id == sourceID } }
    var body: some View {
        Group {
            if let model { LegadoLoginFormContent(model: model) }
            else if let error { ContentUnavailableView("无法打开登录表单", systemImage: "person.badge.key", description: Text(error)).appPageStyle() }
            else if sourceID == "main" || source.map({ (try? SourcePackages.legadoDefinition($0)) == nil }) == true { ProductionSourceAccessView(sourceID: sourceID) }
            else { ProgressView("正在打开书源登录").appPageStyle() }
        }.task(id: sourceID) {
            guard let source else { if sourceID != "main" { error = "书源已移除，请返回书源管理。" }; return }
            guard (try? SourcePackages.legadoDefinition(source)) != nil else { return }
            do {
                let state = try library.legadoLoginState(for: source)
                model = try LegadoLoginFormModel(source: source, state: state) { action, values in
                    try await library.runLegadoLoginAction(sourceID: source.id, action: action, values: values)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LegadoLoginView: View {
    @StateObject private var model: LegadoLoginFormModel
    init(source: DemoSource, state: LegadoPersistentState, runAction: @escaping LegadoLoginFormModel.Action) throws {
        let model = try LegadoLoginFormModel(source: source, state: state, runAction: runAction)
        _model = StateObject(wrappedValue: model)
    }
    var body: some View { LegadoLoginFormContent(model: model) }
}

private struct LegadoLoginFormContent: View {
    @ObservedObject var model: LegadoLoginFormModel
    @EnvironmentObject private var library: LibraryStore
    @State private var confirmLogout = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书源登录", subtitle: model.source.name, icon: "person.badge.key")
                AppSettingsCard("登录信息", icon: "key") {
                    Text(status).font(.system(size: 13)).accessibilityIdentifier("legadoLoginStatus")
                    if model.definition.items.isEmpty {
                        Text("此书源未提供登录表单。可使用内置浏览器完成网页登录后返回验证。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    ForEach(model.definition.items) { item in
                        if item.kind == .button {
                            Button(item.name) { model.perform(item) }.buttonStyle(PrimaryButtonStyle(filled: false))
                                .disabled(model.busy).accessibilityIdentifier("legadoLoginAction-" + item.id)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.name).font(.system(size: 12))
                                if item.kind == .password {
                                    SecureField(item.name, text: field(item.name)).textContentType(.password).frame(minHeight: 44)
                                        .accessibilityIdentifier("legadoLoginField-" + item.name)
                                } else {
                                    TextField(item.name, text: field(item.name)).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 44)
                                        .accessibilityIdentifier("legadoLoginField-" + item.name)
                                }
                            }.disabled(model.busy)
                        }
                    }
                }
                if model.busy { HStack { ProgressView("正在执行书源操作"); Spacer(); Button("取消") { model.cancel() }.frame(minHeight: 44) }.font(.system(size: 12)) }
                Button("退出并清除本地登录", role: .destructive) { confirmLogout = true }.font(.system(size: 13)).frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("legadoLogout")
                Text("登录信息按书源、账号和当前书库隔离保存。网页操作完成或脚本执行结束都不代表账号已经通过验证。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("书源登录").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .sourceFloatingFeedback(model.message, identifier: "legadoLoginMessage")
            .onAppear {
                let source = model.source, state = model.state
                model.useBrowserCleanup { try await library.clearLegadoBrowserSessions(source: source, state: state) }
            }
            .task {
                while !Task.isCancelled {
                    model.refreshStatus()
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            .onDisappear { model.disappeared() }
            .alert("清除此书源的本地登录？", isPresented: $confirmLogout) {
                Button("退出登录", role: .destructive) { model.logout() }
                Button("取消", role: .cancel) { }
            } message: { Text("将清除登录表单和 Cookie；书架、正文与阅读记录保留。") }
    }
    private var status: String {
        switch model.status {
        case .signedOut: "尚未登录"
        case .unverified: "登录信息已保存，尚未验证"
        case .verified: "已验证登录"
        case .expired: "登录已过期，请重新登录"
        }
    }
    private func field(_ name: String) -> Binding<String> { Binding(get: { model.values[name] ?? "" }, set: { model.values[name] = $0 }) }
}
