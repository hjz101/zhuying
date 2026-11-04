import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showSettings = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                HStack(spacing: 18) {
                    Text("山").font(.system(size: 31, design: .serif)).foregroundStyle(Palette.green).frame(width: 70, height: 70).background(Color(hex: 0xE4EAD9), in: .rect(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("山间读者").font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(Palette.green)
                        Text("你的阅读，只属于你。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(.vertical, 13)
                HStack {
                    number(store.favorites.count, label: "书架收藏")
                    Rectangle().fill(Palette.line).frame(width: 1, height: 40)
                    number(store.progress.count, label: "读过的故事")
                }.padding(.vertical, 22).background(Color(hex: 0xEDF0E4), in: .rect(cornerRadius: 17))
                NavigationLink {
                    ReadingHistoryView()
                } label: {
                    HStack { Label("阅读历史", systemImage: "clock.arrow.circlepath"); Spacer(); Text("\(store.history.count) 本").font(.system(size: 11)); Image(systemName: "chevron.right").font(.system(size: 12)) }.font(.system(size: 14)).foregroundStyle(Palette.green).padding(20).background(.white.opacity(0.6), in: .rect(cornerRadius: 15))
                }.accessibilityIdentifier("readingHistory")
                Button { showSettings = true } label: {
                    HStack { Label("阅读偏好", systemImage: "textformat.size"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12)) }.font(.system(size: 14)).foregroundStyle(Palette.green).padding(20).background(.white.opacity(0.6), in: .rect(cornerRadius: 15))
                }
                VStack(spacing: 0) {
                    ForEach(["statistics", "backup", "icloud", "themes", "files", "cache"], id: \.self) { id in
                        NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id)) } label: { FeatureRow(feature: FeatureCatalog.feature(id)) }.buttonStyle(.plain)
                        if id != "cache" { Divider() }
                    }
                }.padding(.horizontal, 15).background(.white.opacity(0.6), in: .rect(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 16) {
                    Label("关于这个 Demo", systemImage: "leaf").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.green)
                    Text("阅山，一个安静的私人阅读角落。").font(.system(size: 20, design: .serif)).lineSpacing(7).foregroundStyle(Palette.green)
                    Text("这是 iOS 原生界面预览。8 本原创模拟小说，可体验搜索、收藏、选章、阅读和进度恢复。").font(.system(size: 12)).lineSpacing(7).foregroundStyle(Palette.muted)
                    Text("阅读数据保存在当前设备，不连接真实书源。演示章节包含复用段落，书籍字数与状态仅用于界面展示。").font(.system(size: 11)).lineSpacing(7).foregroundStyle(Palette.muted)
                    Text("YUESHAN FOR iOS · DESIGN PREVIEW 0.3").font(.system(size: 8)).tracking(1.3).foregroundStyle(Palette.muted).padding(.top, 5)
                }.padding(23).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xEEEFE4), in: .rect(cornerRadius: 17))
            }.padding(23)
        }.background(Palette.background).navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { ReadingSettingsView() }
    }

    private func number(_ value: Int, label: String) -> some View {
        VStack(spacing: 8) { Text("\(value)").font(.system(size: 29, weight: .regular, design: .serif)).foregroundStyle(Palette.green); Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity)
    }
}

struct ReadingSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showGestureGuide = false
    private var theme: ReadingTheme { store.settings.theme }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppPageHeader(title: "阅读，按你的习惯。", subtitle: "翻页、纸色与排版，找到舒服的阅读节奏。", icon: "textformat.size")
                    AppSettingsCard("阅读方式", icon: "book.pages") {
                        Picker("翻页模式", selection: $store.settings.mode) {
                            ForEach(ReadingMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("readingModePicker").labelsHidden()
                        Text("两种模式共用阅读位置，切换后可接着读。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Button { showGestureGuide = true } label: {
                            HStack { Label("查看阅读手势", systemImage: "hand.tap"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)) }
                                .font(.system(size: 12)).frame(minHeight: 32)
                        }.accessibilityIdentifier("readingGestureHelp")
                    }
                    AppSettingsCard("单手操作", icon: "hand.point.up.left") {
                        Toggle("轻触翻页", isOn: $store.settings.tapToTurn).font(.system(size: 13)).accessibilityIdentifier("tapToTurnToggle")
                        HStack(spacing: 5) {
                            tapZone("下一页")
                            tapZone("显示／隐藏菜单")
                            tapZone("下一页")
                        }
                        Text("轻点左右两侧均前进，中间唤出菜单。滚动模式前进约一屏；上一页可右滑或使用底部按钮。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                        Divider().overlay(Palette.line)
                        Toggle("轻微触觉反馈", isOn: $store.settings.haptics).font(.system(size: 13)).accessibilityIdentifier("hapticsToggle")
                    }
                    AppSettingsCard("阅读主题", icon: "paintpalette") {
                        HStack(spacing: 12) {
                            ForEach(ReadingTheme.allCases, id: \.self) { item in
                                Button { store.settings.theme = item } label: {
                                    VStack(spacing: 10) {
                                        Image(systemName: item == .dark ? "moon" : "sun.max").font(.system(size: 20))
                                        Text(item.title).font(.system(size: 12))
                                    }.frame(maxWidth: .infinity).frame(height: 78).foregroundStyle(item.ink).background(item.background, in: .rect(cornerRadius: 13))
                                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme == item ? Palette.green : Palette.line, lineWidth: theme == item ? 2 : 0.5))
                                }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(item == theme ? .isSelected : [])
                            }
                        }
                    }
                    AppSettingsCard("文字排版", icon: "text.alignleft") {
                        Text("文字大小 · \(Int(store.settings.fontSize)) pt").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Picker("字号", selection: $store.settings.fontSize) {
                            ForEach([16.0, 18, 20, 22, 24], id: \.self) { value in Text("\(Int(value))").tag(value) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("fontPicker").labelsHidden()
                        Text("行间距").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Picker("行距", selection: $store.settings.lineSpacing) {
                            Text("紧凑").tag(6.0); Text("适中").tag(12.0); Text("宽松").tag(18.0)
                        }.pickerStyle(.segmented).accessibilityIdentifier("lineSpacingPicker").labelsHidden()
                    }
                    AppSettingsCard("阅读预览", icon: "doc.text") {
                        Text("山海有相逢，长风自有归处。\n在字里行间，遇见另一个世界。")
                            .font(.system(size: store.settings.fontSize, design: .serif)).lineSpacing(store.settings.lineSpacing)
                            .foregroundStyle(theme.ink).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(theme.background, in: .rect(cornerRadius: 13)).accessibilityIdentifier("readingStylePreview")
                    }
                    AppSettingsCard("更多阅读设置", icon: "slider.horizontal.3") {
                        VStack(spacing: 0) {
                            ForEach(["pageStyle", "typography", "themes", "fonts", "titleDesign", "purify", "highlight", "comments"], id: \.self) { id in
                                NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id)) } label: {
                                    HStack {
                                        Label(FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon)
                                        Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    }.font(.system(size: 13)).frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("reading-option-\(id)")
                                if id != "comments" { Divider().overlay(Palette.line) }
                            }
                        }
                    }
                    Button("恢复默认设置") { store.settings = .init() }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("resetReadingSettings")
                    Label("偏好自动保存在当前设备", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                }.padding(22)
            }
            .appPageStyle()
            .navigationTitle("阅读偏好").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.appPageStyle().presentationBackground(Palette.background).presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(26)
            .sheet(isPresented: $showGestureGuide) { ReadingGestureGuideView(isFirstUse: false) }
    }
    private func tapZone(_ title: String) -> some View {
        Text(title).font(.system(size: 9)).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44).background(Palette.green.opacity(0.07), in: .rect(cornerRadius: 7)).foregroundStyle(Palette.green)
    }

}
