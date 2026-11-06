import SwiftUI

struct ProfileView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var store: LibraryStore
    let onShelf: () -> Void
    @State private var showSettings = false
    @State private var now = Date()

    private var todaySeconds: TimeInterval {
        let calendar = Calendar.current
        return ActivityReport(sessions: store.isDemo ? ActivitySession.demo(books: store.books, now: now, calendar: calendar) : store.activitySessions.filter { ($0.kind ?? .reading) == .reading },
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
                            Button(action: onShelf) { ThemeLabel("去书架挑一本", systemImage: "arrow.right") }
                                .font(.system(size: 13)).frame(minHeight: 44)
                        }.padding(.vertical, 12).accessibilityIdentifier("profileReadingEmpty")
                    }
                }
                VStack(alignment: .leading, spacing: 15) {
                    sectionRule("那些翻过书页的日子", label: "HABITS / 02")
                    HStack(alignment: .top, spacing: 12) {
                        NavigationLink { FootprintsView() } label: {
                            metric("\(Int(todaySeconds / 60))", unit: "分钟", caption: store.isDemo ? "今天读了 · 示例" : "今天读了 · 实际记录")
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
                Text("竹影 · 让故事，继续发生").font(.system(size: 11, design: .serif))
                    .tracking(2).foregroundStyle(appAppearance.palette.muted).frame(maxWidth: .infinity).padding(.top, 2)
            }.foregroundStyle(appAppearance.palette.green).padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 25)
                .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }.appPageStyle(role: "profile").navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ProfileSettingsView() } label: { ThemeIcon(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel("设置").accessibilityIdentifier("profileSettings")
                }
            }
            .sheet(isPresented: $showSettings) { ReadingSettingsView() }
            .onAppear { now = Date() }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("ZHUYING / MY SPACE").tracking(2).foregroundStyle(appAppearance.palette.accent)
                Spacer()
                Text(now.formatted(.dateTime.month(.wide).locale(Locale(identifier: "zh_CN"))) + " · 阅读手记")
                    .foregroundStyle(appAppearance.palette.muted)
            }.font(.system(size: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("在书里，")
                Text("找回") + Text("自己。").foregroundColor(appAppearance.palette.accent)
            }.font(.system(size: 38, weight: .regular, design: .serif)).tracking(2)
                .accessibilityElement(children: .combine).accessibilityIdentifier("profileEditorialTitle")
            HStack(spacing: 7) {
                Text("山").font(.system(size: 12, design: .serif)).frame(width: 25, height: 25).background(appAppearance.palette.soft, in: Circle())
                Text("山间读者 · 你的私人阅读角落").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
            }
        }
    }
    private func sectionRule(_ title: String, label: String) -> some View {
        VStack(spacing: 9) {
            Rectangle().fill(appAppearance.palette.primary.opacity(0.8)).frame(height: 0.5)
            HStack {
                Text(title).font(.system(size: 10)).tracking(1)
                Spacer(minLength: 5)
                Text(label).font(.system(size: 9, design: .serif)).tracking(1).foregroundStyle(appAppearance.palette.accent)
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
                Text("\(book.author) · \(book.genre)").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
                Text(book.subtitle).font(.system(size: 12, design: .serif)).foregroundStyle(appAppearance.palette.muted)
                    .lineSpacing(4).lineLimit(2).padding(.vertical, 2)
                Text("第\((store.progress[book.id]?.chapter ?? 0) + 1)章 · 已读 \(store.percent(book))%")
                    .font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted).accessibilityIdentifier("profileCurrentProgress")
                Button { store.read(book) } label: {
                    HStack(spacing: 15) { Text("接着读"); ThemeIcon(systemName: "arrow.right") }
                        .font(.system(size: 13)).frame(minHeight: 44)
                        .overlay(alignment: .bottom) { Rectangle().fill(appAppearance.palette.primary).frame(height: 0.5) }
                }.buttonStyle(.plain).accessibilityIdentifier("profileContinueReading")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            (Text(value).font(.system(size: 25, design: .serif)) + Text(" \(unit)").font(.system(size: 10)))
            Text(caption).font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
        }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
    }
    private func entry(_ title: String, icon: String) -> some View {
        HStack(spacing: 9) {
            ThemeIcon(systemName: icon).font(.system(size: 14, weight: .light)).frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 2)
            ThemeIcon(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(appAppearance.palette.muted)
        }.frame(maxWidth: .infinity, minHeight: 49).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(appAppearance.palette.line).frame(height: 0.5) }
    }
}

private struct ProfileSettingsView: View {
    @Environment(\.themeAppearance) private var appAppearance
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
                    NavigationLink { DemoAboutView() } label: { settingsRow("关于竹影", icon: "leaf") }
                        .accessibilityIdentifier("profileAbout")
                }
            }.padding(22)
        }.appPageStyle(role: "settings").navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showReadingSettings) { ReadingSettingsView() }
            .sheet(isPresented: $showGuide) { ReadingGestureGuideView(isFirstUse: false) }
    }
    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack {
            ThemeLabel(title, systemImage: icon)
            Spacer()
            ThemeIcon(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
        }.font(.system(size: 13)).frame(minHeight: 44).contentShape(Rectangle())
    }
}

private struct DemoAboutView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppPageHeader(title: "竹影", subtitle: "一个安静的私人阅读角落。", icon: "leaf")
                AppSettingsCard(store.isDemo ? "关于这个 Demo" : "关于竹影", icon: "info.circle") {
                    if store.isDemo {
                    Text("这是 iOS 原生界面预览。8 本原创模拟小说，可体验搜索、收藏、选章、阅读和进度恢复。")
                    Text("阅读数据保存在当前设备，不连接真实书源。演示章节包含复用段落，书籍字数与状态仅用于界面展示。")
                        .foregroundStyle(appAppearance.palette.muted)
                    Text("ZHUYING FOR iOS · DESIGN PREVIEW 0.3").font(.system(size: 9)).foregroundStyle(appAppearance.palette.muted)
                    } else {
                        Text(SourceDistributionPolicy.aboutDescription)
                        Text("在线可读性取决于书源；阅读时长来自实际前台会话。需要服务配置的能力及尚未接入的扩展会单独说明。")
                        Text("ZHUYING FOR iOS · DEVELOPMENT CANDIDATE").font(.system(size: 9)).foregroundStyle(appAppearance.palette.muted)
                    }
                }.font(.system(size: 12)).lineSpacing(6)
            }.padding(22)
        }.appPageStyle().navigationTitle("关于竹影").navigationBarTitleDisplayMode(.inline)
    }
}
