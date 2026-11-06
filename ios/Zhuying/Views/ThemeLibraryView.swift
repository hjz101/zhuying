import SwiftUI
import UniformTypeIdentifiers

private enum ThemeLibraryTab: String, CaseIterable { case bundles = "主题套装", titles = "章节标题", bubbles = "段评气泡" }
private enum ThemeLibraryFilter: String, CaseIterable { case all = "全部", light = "浅色", dark = "深色", favorites = "收藏", imported = "我的导入" }

struct ThemeLibraryView: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var tab = ThemeLibraryTab.bundles
    @State private var filter = ThemeLibraryFilter.all
    @State private var query = ""
    @State private var managing = false
    @State private var selection = Set<String>()
    @State private var showingFiles = false
    @State private var importMessage: String?
    @State private var previewReady: [String: Bool] = [:]
    private var current: DemoTheme? { demo.themes.first { $0.id == demo.activeThemeID } }
    private var kind: ThemeAssetKind { tab == .titles ? .title : .bubble }
    private var themes: [DemoTheme] {
        demo.themes.filter { theme in
            matches([theme.name, theme.summary]) && (filter == .all || (filter == .favorites && theme.favorite) ||
                (filter == .light && theme.mode == .light) || (filter == .dark && theme.mode == .dark) || (filter == .imported && theme.source == "文件导入"))
        }
    }
    private var assets: [ThemeAsset] {
        demo.themeAssets.filter { $0.kind == kind && matches([$0.name, $0.sourceName]) && (filter != .favorites || $0.favorite) }
    }
    private func matches(_ values: [String]) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let settings = demo.readingLibrary?.settings, settings.preferences.colors == nil {
                    HStack(spacing: 12) {
                        Circle().fill(settings.theme.background).frame(width: 30, height: 30).overlay(Circle().stroke(Palette.line))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("当前纸色 · \(settings.theme.title)").font(.system(size: 13, weight: .medium))
                            Text("选择下方套装可应用完整主题").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                    }.padding(14).background(Palette.soft, in: .rect(cornerRadius: 12)).accessibilityElement(children: .combine).accessibilityIdentifier("activePaperCard")
                } else if let current {
                    NavigationLink { ThemeBundleDetail(themeID: current.id, useCurrentMix: true) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(Color(hex: current.background)).frame(width: 30, height: 30).overlay(Circle().stroke(Palette.line))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("当前使用 · \(current.name)").font(.system(size: 13, weight: .medium))
                                Text("\(assetName(demo.activeTitleStyleID)) · \(assetName(demo.activeBubbleStyleID))")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.system(size: 11))
                        }.padding(14).background(Palette.soft, in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("activeThemeCard")
                }
                Picker("样式资源", selection: $tab) {
                    ForEach(ThemeLibraryTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("themeLibraryTabs")
                HStack {
                    Menu {
                        Button("选择套装文件", systemImage: "doc") { showingFiles = true }
                        Button("导入示例套装", systemImage: "sparkles") { _ = demo.importDemoThemes(); importMessage = demo.themeImportMessage }
                    } label: { Label("导入套装 / 样式", systemImage: "square.and.arrow.down").font(.system(size: 12)) }.accessibilityIdentifier("themeImport")
                    Spacer()
                    Button(managing ? "完成" : "管理") { managing.toggle(); selection.removeAll() }.font(.system(size: 12)).accessibilityIdentifier("themeManage")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tab == .bundles ? ThemeLibraryFilter.allCases : [.all, .favorites], id: \.self) { value in
                            Button(value.rawValue) { filter = value }.font(.system(size: 11)).padding(.horizontal, 14).frame(minHeight: 34)
                                .background(filter == value ? Palette.green : Palette.soft, in: Capsule()).foregroundStyle(filter == value ? .white : Palette.green)
                                .accessibilityIdentifier("theme-filter-\(String(describing: value))")
                        }
                    }
                }
                if tab == .bundles {
                    if themes.isEmpty { empty }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                        ForEach(themes) { theme in
                            if managing {
                                Button { toggle(theme.id) } label: { bundleCard(theme) }.buttonStyle(.plain).accessibilityIdentifier("theme-card-\(theme.id)")
                            } else {
                                NavigationLink { ThemeBundleDetail(themeID: theme.id) } label: { bundleCard(theme) }
                                    .buttonStyle(.plain).accessibilityIdentifier("theme-card-\(theme.id)")
                                    .accessibilityValue(previewReady[theme.id].map { $0 ? "预览就绪" : "无法预览" } ?? "正在预览")
                                    .contextMenu {
                                        Button("应用整套", systemImage: "checkmark.circle") { demo.applyTheme(theme.id) }
                                        Button(theme.favorite ? "取消收藏" : "收藏", systemImage: "heart") { demo.toggleThemeFavorite(theme.id) }
                                        Button("删除套装", systemImage: "trash", role: .destructive) { demo.removeThemes([theme.id]) }
                                    }
                            }
                        }
                    }
                } else {
                    if assets.isEmpty { empty }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                        ForEach(assets) { asset in
                            if managing {
                                Button { toggle(asset.id) } label: { assetCard(asset) }.buttonStyle(.plain).accessibilityIdentifier("theme-asset-\(asset.id)")
                            } else {
                                NavigationLink { ThemeAssetDetail(assetID: asset.id) } label: { assetCard(asset) }
                                    .buttonStyle(.plain).accessibilityIdentifier("theme-asset-\(asset.id)")
                                    .contextMenu {
                                        Button("用于当前搭配", systemImage: "checkmark.circle") { demo.applyThemeAsset(asset.id) }
                                        Button(asset.favorite ? "取消收藏" : "收藏", systemImage: "heart") { demo.toggleThemeAssetFavorite(asset.id) }
                                        Button("删除样式", systemImage: "trash", role: .destructive) { demo.removeThemeAssets([asset.id]) }
                                    }
                            }
                        }
                    }
                }
                Text(demo.readerThemeMessage ?? "主题库保存在本机。主题配色、兼容标题及气泡可应用到正文；章节 CSS 编辑集中在阅读偏好中。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                NavigationLink("导入格式与说明") { ThemeImportHelp() }.font(.system(size: 12))
            }.padding(22)
        }.appPageStyle().navigationTitle("主题管理").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称、风格或所属套装")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if managing && !selection.isEmpty {
                    HStack {
                        Text("已选 \(selection.count) 项").font(.system(size: 12)); Spacer()
                        Button("收藏") { favoriteSelected() }
                        Button("删除", role: .destructive) {
                            if tab == .bundles { demo.removeThemes(selection) } else { demo.removeThemeAssets(selection) }
                            selection.removeAll()
                        }
                    }.padding(16).background(.regularMaterial)
                }
            }
            .onChange(of: tab) { _, _ in filter = .all; selection.removeAll() }
            .onChange(of: filter) { _, _ in selection.removeAll() }
            .onChange(of: query) { _, _ in selection.removeAll() }
            .alert("导入结果", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("知道了", role: .cancel) { importMessage = nil }
            } message: { Text(importMessage ?? "") }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    var added = 0, titles = 0, bubbles = 0, duplicates = 0, invalid = 0
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= 3 * 1024 * 1024 else { invalid += 1; continue }
                            let result = try demo.importThemeData(Data(contentsOf: url))
                            added += result.added; titles += result.titlesAdded; bubbles += result.bubblesAdded; duplicates += result.duplicates; invalid += result.invalid
                        } catch { invalid += 1 }
                    }
                    if !urls.isEmpty { importMessage = "新增 \(added) 套主题、\(titles) 款标题、\(bubbles) 款气泡 · 重复 \(duplicates) 项 · 无效 \(invalid) 项" }
                } catch {
                    if (error as NSError).code != NSUserCancelledError { importMessage = "无法读取文件：\(error.localizedDescription)" }
                }
            }
    }
    private var empty: some View { ContentUnavailableView("没有找到样式", systemImage: "paintpalette", description: Text("试试其他关键词或筛选条件。")) }
    private func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
    private func assetName(_ id: String?) -> String { demo.themeAssets.first { $0.id == id }?.name ?? "默认样式" }
    private func favoriteSelected() {
        for id in selection {
            if tab == .bundles { if demo.themes.first(where: { $0.id == id })?.favorite == false { demo.toggleThemeFavorite(id) } }
            else if demo.themeAssets.first(where: { $0.id == id })?.favorite == false { demo.toggleThemeAssetFavorite(id) }
        }
    }
    private func bundleCard(_ theme: DemoTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeStylePreview(theme: theme, title: demo.themeAssets(theme, kind: .title).first, bubble: demo.themeAssets(theme, kind: .bubble).first, compact: true, readiness: { previewReady[theme.id] = $0 })
            HStack { Text(theme.name).font(.system(size: 13, weight: .medium)); Spacer(); if theme.favorite { Image(systemName: "heart.fill").font(.system(size: 10)) } }
            Text("标题 \(theme.titleStyleIDs.count) 款 · 气泡 \(theme.bubbleStyleIDs.count) 款").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(!theme.assetIssues.isEmpty ? "\(theme.assetIssues.count) 项样式无法预览" : theme.titleStyleIDs.isEmpty && theme.bubbleStyleIDs.isEmpty ? "未附带标题与气泡" : "\(theme.mode.title) · \(theme.id == demo.activeThemeID ? "使用中" : theme.source)")
                .font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
        }.padding(10).background(Palette.card, in: .rect(cornerRadius: 14)).overlay(alignment: .topTrailing) { selectionMark(theme.id) }
    }
    private func assetCard(_ asset: ThemeAsset) -> some View {
        let palette = demo.themes.first { $0.id == asset.sourceThemeID } ?? current ?? demo.themes[0]
        return VStack(alignment: .leading, spacing: 8) {
            ThemeStylePreview(theme: palette, title: asset.kind == .title ? asset : nil, bubble: asset.kind == .bubble ? asset : nil, compact: true, assetOnly: asset.kind)
            Text(asset.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text("\(asset.kind == .title ? "CSS" : "SVG") · \(asset.sourceName)").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
            if asset.id == demo.activeTitleStyleID || asset.id == demo.activeBubbleStyleID { Text("使用中").font(.system(size: 9)).foregroundStyle(Palette.accent) }
        }.padding(10).background(Palette.card, in: .rect(cornerRadius: 14)).overlay(alignment: .topTrailing) { selectionMark(asset.id) }
    }
    @ViewBuilder private func selectionMark(_ id: String) -> some View {
        if managing { Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle").font(.system(size: 21)).padding(8).foregroundStyle(Palette.green).background(.regularMaterial, in: Circle()).padding(4) }
    }
}

private struct ThemeBundleDetail: View {
    let themeID: String
    var useCurrentMix = false
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var titleID: String?
    @State private var bubbleID: String?
    @State private var initialized = false
    @State private var longTitle = false
    @State private var showMixer = false
    @State private var didApply = false
    var body: some View {
        if let theme = demo.themes.first(where: { $0.id == themeID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(theme.name).font(.system(size: 23, design: .serif)); Text("\(theme.source) · v\(theme.version)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        Spacer()
                        Button { demo.toggleThemeFavorite(themeID) } label: { Image(systemName: theme.favorite ? "heart.fill" : "heart").frame(width: 44, height: 44) }
                            .accessibilityLabel("收藏套装").accessibilityIdentifier("themeFavorite")
                    }
                    ThemeStylePreview(theme: theme, title: asset(titleID), bubble: asset(bubbleID), longTitle: longTitle)
                    Text("正文实际效果").font(.system(size: 13, weight: .medium))
                    ThemeNativeReadingPreview(settings: demo.readerPreview(theme: theme, titleID: titleID, bubbleID: bubbleID), theme: theme)
                    Text("上方套装预览展示原始 CSS／SVG；正文实际效果展示原生支持的标题样式。个人自定义标题和气泡会保留。 ").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Toggle("预览长章节标题", isOn: $longTitle).font(.system(size: 12)).accessibilityIdentifier("themeLongTitle")
                    assetSelector(theme, kind: .title)
                    assetSelector(theme, kind: .bubble)
                    if !theme.assetIssues.isEmpty { Text("无法预览：" + theme.assetIssues.joined(separator: "、")).font(.system(size: 12)).foregroundStyle(Palette.accent) }
                    Text("选择缩略图只改变预览；确认应用后才更新当前搭配。未附带的项目沿用当前样式。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if didApply { Text(demo.readerThemeMessage ?? "已应用到正文阅读器").font(.system(size: 12)).accessibilityIdentifier("themeApplied") }
                }.padding(22)
            }.appPageStyle().navigationTitle("主题预览").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        Button("应用整套") { didApply = demo.applyThemeMix(themeID: themeID, titleID: titleID, bubbleID: bubbleID) }
                            .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("themeApply")
                        Button("仅配色") { demo.activeThemeID = themeID; demo.updateReaderTheme(colorsOnly: true); didApply = true }
                            .buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("themeApplyColors")
                        Button("自定义搭配") { showMixer = true }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("themeCustomize")
                    }.padding(.horizontal, 22).padding(.vertical, 10).background(Palette.background)
                }
                .onAppear {
                    if !initialized {
                        titleID = useCurrentMix ? demo.activeTitleStyleID : theme.titleStyleIDs.first ?? demo.activeTitleStyleID
                        bubbleID = useCurrentMix ? demo.activeBubbleStyleID : theme.bubbleStyleIDs.first ?? demo.activeBubbleStyleID
                        initialized = true
                    }
                }
                .sheet(isPresented: $showMixer) { NavigationStack { ThemeMixer(initialThemeID: themeID, initialTitleID: titleID, initialBubbleID: bubbleID) }.environment(\.readingPreferenceDismiss, nil) }
        } else { ContentUnavailableView("主题不存在", systemImage: "paintpalette") }
    }
    private func asset(_ id: String?) -> ThemeAsset? { demo.themeAssets.first { $0.id == id } }
    private func assetSelector(_ theme: DemoTheme, kind: ThemeAssetKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .title ? "附带章节标题 · CSS" : "附带段评气泡 · SVG").font(.system(size: 14, weight: .medium))
            let choices = demo.themeAssets(theme, kind: kind)
            if choices.isEmpty { Text(theme.assetIssues.isEmpty ? "未附带，保留当前样式" : "未附带或导入失败，保留当前样式").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            ForEach(choices) { choice in
                Button { if kind == .title { titleID = choice.id } else { bubbleID = choice.id }; didApply = false } label: {
                    HStack {
                        ThemeStylePreview(theme: theme, title: kind == .title ? choice : nil, bubble: kind == .bubble ? choice : nil, compact: true, assetOnly: kind).frame(width: 130)
                        Text(choice.name).font(.system(size: 12)); Spacer()
                        Image(systemName: (kind == .title ? titleID : bubbleID) == choice.id ? "checkmark.circle.fill" : "circle")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("theme-choice-\(choice.id)")
            }
        }
    }
}

private struct ThemeNativeReadingPreview: View {
    let settings: ReadingSettings
    let theme: DemoTheme
    @State private var rendered: ReadingSettings?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadingSettingsPreview(settings: rendered ?? settings)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent) }
            else if rendered == nil && settings.preferences.showCommentBubbles &&
                (settings.preferences.bubbleFollowsTheme ? settings.preferences.bubbleSVG : settings.preferences.customBubbleSVG) != nil {
                Text("正在生成 SVG 气泡的正文预览…").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.task(id: settings) {
            rendered = nil; error = nil
            do {
                let result = try await ThemeReaderBridge.renderedPreview(settings, theme: theme)
                guard !Task.isCancelled else { return }
                rendered = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "该 SVG 暂时无法生成原生预览，显示默认气泡。"
            }
        }
    }
}

private struct ThemeAssetDetail: View {
    let assetID: String
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var longTitle = false
    @State private var darkCanvas = false
    @State private var showMixer = false
    @State private var didApply = false
    var body: some View {
        if let asset = demo.themeAssets.first(where: { $0.id == assetID }), let current = demo.themes.first(where: { $0.id == demo.activeThemeID }) {
            let palette = asset.kind == .bubble ? demo.themes.first(where: { $0.mode == (darkCanvas ? .dark : .light) }) ?? current : current
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(asset.name).font(.system(size: 23, design: .serif))
                    Text("\(asset.sourceName) · \(asset.kind == .title ? "CSS 章节标题" : "SVG 段评气泡")").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    ThemeStylePreview(theme: palette, title: asset.kind == .title ? asset : nil, bubble: asset.kind == .bubble ? asset : nil, longTitle: longTitle, assetOnly: asset.kind)
                    if asset.kind == .title { Toggle("预览长章节标题", isOn: $longTitle).accessibilityIdentifier("assetLongTitle") }
                    else {
                        Text("分别预览 3、28、128 条段评").font(.system(size: 12))
                        Toggle("深色背景预览", isOn: $darkCanvas).accessibilityIdentifier("assetDarkCanvas")
                    }
                    Button(asset.favorite ? "取消收藏" : "收藏样式") { demo.toggleThemeAssetFavorite(assetID) }.font(.system(size: 13)).accessibilityIdentifier("themeAssetFavorite")
                    if didApply { Text("已用于当前预览搭配").font(.system(size: 12)).accessibilityIdentifier("themeAssetApplied") }
                }.padding(22)
            }.appPageStyle().navigationTitle(asset.kind == .title ? "章节标题预览" : "段评气泡预览").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button(asset.kind == .title ? "应用标题" : "应用气泡") { demo.applyThemeAsset(assetID); didApply = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("themeAssetApply")
                        Button("自定义搭配") { showMixer = true }.buttonStyle(PrimaryButtonStyle(filled: false))
                    }.padding(16).background(Palette.background)
                }
                .sheet(isPresented: $showMixer) {
                    NavigationStack { ThemeMixer(initialThemeID: current.id, initialTitleID: asset.kind == .title ? assetID : demo.activeTitleStyleID, initialBubbleID: asset.kind == .bubble ? assetID : demo.activeBubbleStyleID) }.environment(\.readingPreferenceDismiss, nil)
                }
        } else { ContentUnavailableView("样式不存在", systemImage: "paintpalette") }
    }
}

private struct ThemeMixer: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var themeID: String
    @State private var titleID: String?
    @State private var bubbleID: String?
    init(initialThemeID: String, initialTitleID: String?, initialBubbleID: String?) {
        _themeID = State(initialValue: initialThemeID); _titleID = State(initialValue: initialTitleID); _bubbleID = State(initialValue: initialBubbleID)
    }
    var body: some View {
        ScrollView {
            if let theme = demo.themes.first(where: { $0.id == themeID }) {
                VStack(alignment: .leading, spacing: 20) {
                    ThemeStylePreview(theme: theme, title: demo.themeAssets.first { $0.id == titleID }, bubble: demo.themeAssets.first { $0.id == bubbleID })
                    HStack {
                        Text("主题配色"); Spacer()
                        Picker("主题配色", selection: $themeID) { ForEach(demo.themes) { Text($0.name).tag($0.id) } }.labelsHidden().accessibilityIdentifier("mixTheme")
                    }.font(.system(size: 13))
                    HStack {
                        Text("章节标题"); Spacer()
                        Picker("章节标题", selection: $titleID) {
                            Text("默认标题").tag(String?.none)
                            ForEach(demo.themeAssets.filter { $0.kind == .title }) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden().accessibilityIdentifier("mixTitle")
                    }.font(.system(size: 13))
                    HStack {
                        Text("段评气泡"); Spacer()
                        Picker("段评气泡", selection: $bubbleID) {
                            Text("默认气泡").tag(String?.none)
                            ForEach(demo.themeAssets.filter { $0.kind == .bubble }) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden().accessibilityIdentifier("mixBubble")
                    }.font(.system(size: 13))
                    Text("配色、章节标题、段评气泡独立选择，确认前不改变当前搭配。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.padding(22)
            }
        }.appPageStyle().navigationTitle("自定义搭配").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("应用搭配") { if demo.applyThemeMix(themeID: themeID, titleID: titleID, bubbleID: bubbleID) { dismiss() } }.accessibilityIdentifier("applyThemeMix") }
            }
    }
}

private struct ThemeImportHelp: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("一个套装，三种资源").font(.system(size: 24, design: .serif))
                Text("选择 JSON 文件，可包含 themes 数组，也可只有 chapterTitles 或 commentBubbles。颜色使用六位十六进制；CSS 使用 .chapter-title 选择器及 --ink／--accent／--background 变量。SVG 可使用 {{count}}、{{ink}}、{{accent}}、{{background}} 占位符。")
                Text("标题和气泡随套装关联；独立资源显示在各自栏目中。重复 ID 跳过，无效资源单独计数，缺少的项目显示未附带。预览支持内联样式和 SVG，不加载外部图片、字体或脚本。")
                Text("主题和样式库保存到本机。配色、兼容标题及气泡可用于正文；原生章节 CSS 不支持的伪元素或装饰会提示。可在主题 JSON 增加 godStyle（纯色／液态玻璃／画框）配置神评卡片。")
                Text("示例结构").font(.system(size: 16, weight: .medium))
                Text("{\n  \"themes\": [{\n    \"id\": \"my-theme\", \"name\": \"我的主题\",\n    \"background\": \"#F7F6F0\",\n    \"ink\": \"#354F40\", \"accent\": \"#B7815A\",\n    \"chapterTitles\": [{\"id\": \"title\", \"name\": \"章首\",\n      \"css\": \".chapter-title { text-align:center; }\"}],\n    \"commentBubbles\": []\n  }]\n}")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }.font(.system(size: 13)).lineSpacing(6).padding(22)
        }.appPageStyle().navigationTitle("导入说明").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
    }
}
