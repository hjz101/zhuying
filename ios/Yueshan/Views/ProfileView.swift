import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: LibraryStore
    let onShelf: () -> Void
    @State private var showSettings = false
    @State private var now = Date()

    private var todaySeconds: TimeInterval {
        let calendar = Calendar.current
        return ActivityReport(sessions: ActivitySession.demo(books: store.books, now: now, calendar: calendar),
                              now: now, period: .day, calendar: calendar).seconds
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                masthead
                VStack(alignment: .leading, spacing: 20) {
                    sectionRule("此刻，读到这里", label: "READING / 01")
                    if let book = store.history.first { currentBook(book) }
                    else {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("下一段故事，等你翻开。").font(.system(size: 23, design: .serif))
                            Button(action: onShelf) { Label("去书架挑一本", systemImage: "arrow.right") }
                                .font(.system(size: 13)).frame(minHeight: 44)
                        }.padding(.vertical, 12).accessibilityIdentifier("profileReadingEmpty")
                    }
                }
                VStack(alignment: .leading, spacing: 15) {
                    sectionRule("那些翻过书页的日子", label: "HABITS / 02")
                    HStack(alignment: .top, spacing: 12) {
                        NavigationLink { FootprintsView() } label: {
                            metric("\(Int(todaySeconds / 60))", unit: "分钟", caption: "今天读了 · 示例")
                        }.accessibilityIdentifier("profileActivity")
                        Button(action: onShelf) { metric("\(store.favorites.count)", unit: "本", caption: "收藏的故事") }
                            .accessibilityIdentifier("profileFavorites")
                        NavigationLink { ReadingHistoryView() } label: {
                            metric("\(store.history.count)", unit: "本", caption: "读过的故事")
                        }.accessibilityIdentifier("profileReadBooks")
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionRule("为阅读，准备的一切", label: "ESSENTIALS / 03")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 21), GridItem(.flexible())], spacing: 0) {
                        NavigationLink { ReadingHistoryView() } label: { entry("阅读历史", icon: "clock.arrow.circlepath") }
                            .accessibilityIdentifier("readingHistory")
                        Button { showSettings = true } label: { entry("阅读偏好", icon: "slider.horizontal.3") }
                            .accessibilityIdentifier("profileReadingSettings").accessibilityLabel("阅读偏好")
                        NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("import")) } label: { entry("智能导入", icon: "square.and.arrow.down") }
                            .accessibilityIdentifier("profile-tool-import")
                        NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("themes")) } label: { entry("主题管理", icon: "paintpalette") }
                            .accessibilityIdentifier("profileThemes")
                        NavigationLink { FeatureHubView(sourceOnly: true) } label: { entry("书源管理", icon: "externaldrive") }
                            .accessibilityIdentifier("profileSources")
                        NavigationLink { FeatureHubView() } label: { entry("全部工具", icon: "square.grid.2x2") }
                            .accessibilityIdentifier("allTools")
                    }.buttonStyle(.plain)
                }
                Text("阅山 · 让故事，继续发生").font(.system(size: 11, design: .serif))
                    .tracking(2).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.top, 2)
            }.foregroundStyle(Palette.green).padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 25)
                .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }.appPageStyle().navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ProfileSettingsView() } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel("设置").accessibilityIdentifier("profileSettings")
                }
            }
            .sheet(isPresented: $showSettings) { ReadingSettingsView() }
            .onAppear { now = Date() }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("YUESHAN / MY SPACE").tracking(2).foregroundStyle(Palette.accent)
                Spacer()
                Text(now.formatted(.dateTime.month(.wide).locale(Locale(identifier: "zh_CN"))) + " · 阅读手记")
                    .foregroundStyle(Palette.muted)
            }.font(.system(size: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("在书里，")
                Text("找回") + Text("自己。").foregroundColor(Palette.accent)
            }.font(.system(size: 38, weight: .regular, design: .serif)).tracking(2)
                .accessibilityElement(children: .combine).accessibilityIdentifier("profileEditorialTitle")
            HStack(spacing: 7) {
                Text("山").font(.system(size: 12, design: .serif)).frame(width: 25, height: 25).background(Palette.soft, in: Circle())
                Text("山间读者 · 你的私人阅读角落").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func sectionRule(_ title: String, label: String) -> some View {
        VStack(spacing: 9) {
            Rectangle().fill(Palette.green.opacity(0.8)).frame(height: 0.5)
            HStack {
                Text(title).font(.system(size: 10)).tracking(1)
                Spacer(minLength: 5)
                Text(label).font(.system(size: 9, design: .serif)).tracking(1).foregroundStyle(Palette.accent)
            }
        }
    }
    private func currentBook(_ book: Book) -> some View {
        HStack(alignment: .center, spacing: 24) {
            BookCover(book: book, width: 113).rotationEffect(.degrees(-4))
                .padding(.horizontal, 4).padding(.vertical, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(book.title).font(.system(size: 22, weight: .medium, design: .serif))
                    .lineLimit(2).accessibilityIdentifier("profileCurrentBook")
                Text("\(book.author) · \(book.genre)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Text(book.subtitle).font(.system(size: 12, design: .serif)).foregroundStyle(Palette.muted)
                    .lineSpacing(4).lineLimit(2).padding(.vertical, 2)
                Text("第\((store.progress[book.id]?.chapter ?? 0) + 1)章 · 已读 \(store.percent(book))%")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).accessibilityIdentifier("profileCurrentProgress")
                Button { store.read(book) } label: {
                    HStack(spacing: 15) { Text("接着读"); Image(systemName: "arrow.right") }
                        .font(.system(size: 13)).frame(minHeight: 44)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.green).frame(height: 0.5) }
                }.buttonStyle(.plain).accessibilityIdentifier("profileContinueReading")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            (Text(value).font(.system(size: 25, design: .serif)) + Text(" \(unit)").font(.system(size: 10)))
            Text(caption).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
    }
    private func entry(_ title: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 14, weight: .light)).frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 2)
            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, minHeight: 49).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }
    }
}

private struct ProfileSettingsView: View {
    @State private var showReadingSettings = false
    @State private var showGuide = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppSettingsCard("界面与导航", icon: "rectangle.bottomthird.inset.filled") {
                    NavigationLink { NavigationSettingsView() } label: { settingsRow("界面设置", icon: "slider.horizontal.3") }
                        .accessibilityIdentifier("interfaceSettings")
                }
                AppSettingsCard("阅读与数据", icon: "slider.horizontal.3") {
                    Button { showReadingSettings = true } label: { settingsRow("阅读偏好", icon: "textformat.size") }
                    Divider()
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("icloud")) } label: { settingsRow("iCloud 同步", icon: "icloud") }
                    Divider()
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("statistics")) } label: { settingsRow("阅读统计", icon: "chart.bar") }
                }
                AppSettingsCard("关于与帮助", icon: "questionmark.circle") {
                    Button { showGuide = true } label: { settingsRow("阅读手势帮助", icon: "hand.tap") }
                        .accessibilityIdentifier("profileGestureHelp")
                    Divider()
                    NavigationLink { DemoAboutView() } label: { settingsRow("关于阅山", icon: "leaf") }
                        .accessibilityIdentifier("profileAbout")
                }
            }.padding(22)
        }.appPageStyle().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showReadingSettings) { ReadingSettingsView() }
            .sheet(isPresented: $showGuide) { ReadingGestureGuideView(isFirstUse: false) }
    }
    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.font(.system(size: 13)).frame(minHeight: 44).contentShape(Rectangle())
    }
}

private struct DemoAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppPageHeader(title: "阅山", subtitle: "一个安静的私人阅读角落。", icon: "leaf")
                AppSettingsCard("关于这个 Demo", icon: "info.circle") {
                    Text("这是 iOS 原生界面预览。8 本原创模拟小说，可体验搜索、收藏、选章、阅读和进度恢复。")
                    Text("阅读数据保存在当前设备，不连接真实书源。演示章节包含复用段落，书籍字数与状态仅用于界面展示。")
                        .foregroundStyle(Palette.muted)
                    Text("YUESHAN FOR iOS · DESIGN PREVIEW 0.3").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }.font(.system(size: 12)).lineSpacing(6)
            }.padding(22)
        }.appPageStyle().navigationTitle("关于阅山").navigationBarTitleDisplayMode(.inline)
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
