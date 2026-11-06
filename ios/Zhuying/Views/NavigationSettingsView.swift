import SwiftUI

struct NavigationSettingsView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var navigation: NavigationStore
    private var supportsCollapse: Bool { if #available(iOS 26.0, *) { true } else { false } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AppPageHeader(title: "常用的，放在手边。", subtitle: "选择底部入口，安排自己的阅读习惯。", icon: "rectangle.bottomthird.inset.filled")
                AppSettingsCard("显示项目", icon: "checklist") {
                    Text("主导航最多 4 项，搜索始终在右侧。书架与我的固定显示。")
                        .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).lineSpacing(5)
                    ForEach(AppTab.optional) { tab in
                        Toggle(isOn: Binding(get: { navigation.shortcuts.contains(tab) }, set: { navigation.setVisible(tab, $0) })) {
                            ThemeLabel(tab.title, systemImage: tab.icon)
                        }.font(.system(size: 14))
                            .disabled(!navigation.shortcuts.contains(tab) && !navigation.canAddShortcut)
                            .accessibilityIdentifier("nav-toggle-\(tab.rawValue)")
                    }
                    Text("已显示 \(navigation.visibleTabs.count) / 4 项").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
                        .accessibilityIdentifier("navItemCount")
                }
                AppSettingsCard("显示顺序", icon: "arrow.up.arrow.down") {
                    orderRow(.shelf, fixed: true)
                    ForEach(navigation.shortcuts) { tab in orderRow(tab, fixed: false) }
                    orderRow(.profile, fixed: true)
                }
                AppSettingsCard("导航显示方式", icon: "rectangle.compress.vertical") {
                    Toggle("滑动时自动收起导航", isOn: $navigation.autoCollapse)
                        .font(.system(size: 13)).disabled(!supportsCollapse).accessibilityIdentifier("navAutoCollapse")
                    Text(supportsCollapse
                         ? "关闭时固定展开；开启后上滑浏览时收起，下滑或轻触当前页胶囊展开，搜索持续可用。"
                         : "当前系统使用固定导航；iOS 26 及以上可启用滑动自动收起。")
                        .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).lineSpacing(5)
                }
                Button("恢复默认导航") { navigation.reset() }.buttonStyle(PrimaryButtonStyle(filled: false))
                    .accessibilityIdentifier("resetNavigation")
                ThemeLabel("选择自动保存在当前设备", systemImage: "checkmark.circle").font(.system(size: 11))
                    .foregroundStyle(appAppearance.palette.muted).frame(maxWidth: .infinity)
            }.padding(22)
        }.appPageStyle().navigationTitle("底部导航").navigationBarTitleDisplayMode(.inline)
    }
    private func orderRow(_ tab: AppTab, fixed: Bool) -> some View {
        HStack {
            ThemeLabel(tab.title, systemImage: tab.icon).font(.system(size: 13))
            Spacer()
            if fixed { Text("固定显示").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted) }
            else {
                Button { navigation.move(tab, by: -1) } label: { ThemeIcon(systemName: "chevron.up").frame(width: 44, height: 44) }
                    .disabled(navigation.shortcuts.first == tab).accessibilityLabel("上移\(tab.title)")
                    .accessibilityIdentifier("nav-move-\(tab.rawValue)-up")
                Button { navigation.move(tab, by: 1) } label: { ThemeIcon(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .disabled(navigation.shortcuts.last == tab).accessibilityLabel("下移\(tab.title)")
            }
        }.frame(minHeight: 44)
    }
}
