import SwiftUI

struct ShushanLoginView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var account: ShushanAccountStore
    @State private var email = ""
    @State private var password = ""
    @State private var loginTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书源登录", subtitle: SourceDistributionPolicy.nativeServiceName, icon: "person.crop.circle")
                AppSettingsCard("登录信息", icon: "person.badge.key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务地址").font(.system(size: 12, weight: .medium))
                        TextField(SourceDistributionPolicy.serviceAddressPrompt, text: $account.hostText)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("shushanHost")
                        Divider()
                        Text("邮箱").font(.system(size: 12, weight: .medium))
                        TextField("你的书源账号邮箱", text: $email).keyboardType(.emailAddress)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("shushanEmail")
                        Divider()
                        Text("密码").font(.system(size: 12, weight: .medium))
                        SecureField("账号密码", text: $password).textContentType(.password).accessibilityIdentifier("shushanPassword")
                    }.font(.system(size: 13)).padding(.vertical, 6)
                }.disabled(account.busy)
                Button {
                    let submittedPassword = password
                    password = ""
                    loginTask = Task { await account.login(email: email, password: submittedPassword) }
                } label: {
                    HStack { if account.busy { ProgressView() }; Text(account.busy ? "正在登录" : "登录") }
                }.buttonStyle(PrimaryButtonStyle()).disabled(account.busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("shushanLogin")
                if account.credential != nil {
                    Button("退出登录") { account.logout() }.buttonStyle(PrimaryButtonStyle(filled: false))
                        .disabled(account.busy).accessibilityIdentifier("shushanLogout")
                }
                Text("密码仅用于此次登录；登录状态保存在设备钥匙串。退出登录会保留书架和阅读记录。")
                    .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).lineSpacing(5)
            }.padding(22)
        }.appPageStyle().navigationTitle("书源登录").navigationBarTitleDisplayMode(.inline)
            .sourceFloatingFeedback(account.message, identifier: "shushanLoginMessage")
            .onDisappear { loginTask?.cancel(); password = "" }
    }
}
