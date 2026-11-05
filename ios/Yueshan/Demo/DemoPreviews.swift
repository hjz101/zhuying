import SwiftUI
import UniformTypeIdentifiers

struct SourceManagementView: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var query = ""
    @State private var kind: DemoSourceKind?
    @State private var group: String?
    @State private var status = SourceStatusFilter.all
    @State private var sort = SourceSort.original
    @State private var route: SourceActionRoute?
    @State private var managing = false
    @State private var selection = Set<String>()
    @State private var pendingRemoval = Set<String>()
    @State private var showNewGroup = false
    @State private var newGroup = ""

    private var sources: [DemoSource] { demo.filteredSources(kind: kind, group: group, status: status, sort: sort, query: query) }
    private var visibleIDs: Set<String> { Set(sources.map(\.id)) }
    private var groups: [String] { Array(Set(demo.sources.map(\.group) + ["个人收藏"])).sorted() }
    private var isFiltered: Bool { group != nil || status != .all || sort != .original }

    var body: some View {
        VStack(spacing: 0) {
            controls
            List {
                DemoSourceRows(providedSources: sources, compact: true, managing: managing, selection: $selection, route: $route)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }.background(Palette.background)
            .navigationTitle("书源").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称、网址或分组")
            .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { toolbarActions } }
            .safeAreaInset(edge: .bottom, spacing: 0) { if managing { batchActions } }
            .navigationDestination(item: $route) { item in FeatureDemoView(feature: FeatureCatalog.feature(item.featureID), scope: item.sourceID) }
            .onChange(of: kind) { _, _ in selection.removeAll() }
            .onChange(of: group) { _, _ in selection.removeAll() }
            .onChange(of: status) { _, _ in selection.removeAll() }
            .onChange(of: query) { _, _ in selection.removeAll() }
            .onChange(of: visibleIDs) { _, ids in selection.formIntersection(ids) }
            .alert("删除选中的 \(pendingRemoval.count) 个书源？", isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval.removeAll() } })) {
                Button("确认删除书源", role: .destructive) {
                    for id in pendingRemoval { demo.removeSource(id) }
                    selection.subtract(pendingRemoval); pendingRemoval.removeAll()
                }
                Button("取消", role: .cancel) { pendingRemoval.removeAll() }
            } message: { Text("书架与阅读进度保留。") }
            .alert("新建分组", isPresented: $showNewGroup) {
                TextField("分组名称", text: $newGroup)
                Button("移动所选书源") { demo.moveSources(selection, group: newGroup) }
                    .disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) {}
            }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                categoryButton(nil)
                ForEach(DemoSourceKind.allCases, id: \.self) { categoryButton($0) }
            }.padding(4).background(Palette.green.opacity(0.05), in: .rect(cornerRadius: 10))
            HStack {
                Text(managing ? "已选 \(selection.count) / \(sources.count)" : "\(sources.count) 个书源 · 示例数据")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).accessibilityIdentifier("sourceCount")
                Spacer()
                if managing {
                    Button(!visibleIDs.isEmpty && selection == visibleIDs ? "取消全选" : "全选当前结果") {
                        selection = selection == visibleIDs ? [] : visibleIDs
                    }.font(.system(size: 12)).disabled(visibleIDs.isEmpty).accessibilityIdentifier("sourceSelectAll")
                } else {
                    filterMenu
                    Button("管理") { managing = true; selection.removeAll() }.font(.system(size: 12)).accessibilityIdentifier("sourceManage")
                }
            }
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10).foregroundStyle(Palette.green)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.green.opacity(0.12)).frame(height: 0.5) }
    }

    private func categoryButton(_ value: DemoSourceKind?) -> some View {
        let count = demo.sources.filter { value == nil || $0.kind == value }.count
        return Button { kind = value } label: {
            Text("\(value?.rawValue ?? "全部") \(count)")
                .font(.system(size: 12, weight: kind == value ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(kind == value ? Palette.card : .clear, in: .rect(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("source-kind-\(value?.rawValue ?? "全部")")
            .accessibilityAddTraits(kind == value ? .isSelected : [])
    }

    private var filterMenu: some View {
        Menu {
            Picker("状态", selection: $status) { ForEach(SourceStatusFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Menu("分组") {
                Button("全部分组") { group = nil }
                ForEach(groups, id: \.self) { value in Button(value) { group = value } }
            }
            Picker("排序", selection: $sort) { ForEach(SourceSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if isFiltered { Button("重置筛选与排序") { group = nil; status = .all; sort = .original } }
        } label: {
            Label(isFiltered ? "已筛选" : "筛选", systemImage: "line.3.horizontal.decrease")
                .font(.system(size: 12)).padding(.trailing, 10)
        }.accessibilityIdentifier("sourceFilter")
    }

    @ViewBuilder private var toolbarActions: some View {
        if managing {
            Button("完成") { managing = false; selection.removeAll() }.accessibilityIdentifier("sourceManageDone")
        } else {
            Menu {
                Button("导入书源", systemImage: "square.and.arrow.down") {
                    route = .init(sourceID: "main", featureID: "sourceImport")
                }
                Button("手动新建", systemImage: "square.and.pencil") {
                    route = .init(sourceID: demo.createSource(kind: kind ?? .novel, group: group), featureID: "sourceEdit")
                }
            } label: { Image(systemName: "plus") }.accessibilityLabel("添加书源").accessibilityIdentifier("sourceAdd")
            Menu {
                Button("导出书源", systemImage: "square.and.arrow.up") { route = .init(sourceID: "main", featureID: "sourceImport") }
                Button("批量检测", systemImage: "checklist") { route = .init(sourceID: "main", featureID: "sourceBatch") }
                Button("规则调试", systemImage: "curlybraces") { route = .init(sourceID: "main", featureID: "engine") }
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多书源工具").accessibilityIdentifier("sourceMore")
        }
    }

    private var batchActions: some View {
        HStack(spacing: 0) {
            Button { demo.setSourcesEnabled(selection, enabled: true) } label: { batchLabel("启用", "power") }.accessibilityIdentifier("sourceBatchEnable")
            Button { demo.setSourcesEnabled(selection, enabled: false) } label: { batchLabel("停用", "pause.circle") }.accessibilityIdentifier("sourceBatchDisable")
            Menu {
                ForEach(groups, id: \.self) { value in Button(value) { demo.moveSources(selection, group: value) } }
                Button("新建分组…") { newGroup = ""; showNewGroup = true }
            } label: { batchLabel("分组", "folder") }.accessibilityIdentifier("sourceBatchGroup")
            Button(role: .destructive) { pendingRemoval = selection } label: { batchLabel("删除", "trash").foregroundStyle(Palette.accent) }.accessibilityIdentifier("sourceBatchDelete")
        }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Palette.green)
            .disabled(selection.isEmpty).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Palette.card).overlay(alignment: .top) { Divider() }
    }
    private func batchLabel(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 17)); Text(text) }.frame(maxWidth: .infinity, minHeight: 44)
    }
}

struct DemoSourceList: View {
    var scope: String
    var group = "全部"
    @State private var route: SourceActionRoute?
    var body: some View {
        VStack(alignment: .leading, spacing: 13) { DemoSourceRows(group: group, route: $route) }
            .navigationDestination(item: $route) { item in FeatureDemoView(feature: FeatureCatalog.feature(item.featureID), scope: item.sourceID) }
    }
}

struct SourceActionRoute: Hashable, Identifiable {
    let sourceID: String
    let featureID: String
    var id: String { sourceID + featureID }
}

struct DemoSourceRows: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    var group = "全部"
    var query = ""
    var providedSources: [DemoSource]?
    var compact = false
    var managing = false
    var selection: Binding<Set<String>> = .constant([])
    @Binding var route: SourceActionRoute?
    @State private var removal: DemoSource?
    private var sources: [DemoSource] {
        providedSources ?? demo.sources.filter { (group == "全部" || $0.group == group) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        ForEach(sources) { source in
            if managing {
                Button {
                    if selection.wrappedValue.contains(source.id) { selection.wrappedValue.remove(source.id) }
                    else { selection.wrappedValue.insert(source.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selection.wrappedValue.contains(source.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.green)
                        rowLabel(source)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("source-select-\(source.id)")
                    .accessibilityValue(selection.wrappedValue.contains(source.id) ? "已选择" : "未选择")
            } else {
            NavigationLink { DemoSourceDetail(sourceID: source.id) } label: {
                rowLabel(source)
            }.buttonStyle(.plain).accessibilityIdentifier("source-row-\(source.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { open("sourceLogin", source) } label: { Label(source.loginStatus.action, systemImage: "person.badge.key") }.tint(Palette.green)
                        .accessibilityIdentifier("source-login-\(source.id)")
                    Button { open("sourceEdit", source) } label: { Label("编辑", systemImage: "square.and.pencil") }.tint(Palette.accent)
                        .accessibilityIdentifier("source-edit-\(source.id)")
                }
                .contextMenu {
                    Button(source.pinned ? "取消置顶" : "置顶书源", systemImage: "pin") { demo.toggleSourcePin(source.id) }
                    Button(source.loginStatus.action, systemImage: "person.badge.key") { open("sourceLogin", source) }
                    Button("编辑", systemImage: "square.and.pencil") { open("sourceEdit", source) }
                    Button("调试", systemImage: "ladybug") { open("sourceDebug", source) }
                    Button(source.enabled ? "停用书源" : "启用书源", systemImage: "power") {
                        demo.setSourcesEnabled([source.id], enabled: !source.enabled)
                    }
                    Button("移入个人收藏", systemImage: "folder") {
                        demo.moveSources([source.id], group: "个人收藏")
                    }
                    Button("删除书源", systemImage: "trash", role: .destructive) { removal = source }
                }
            }
        }
        if sources.isEmpty { ContentUnavailableView(demo.sources.isEmpty ? "还没有书源" : "没有符合条件的书源", systemImage: "externaldrive", description: Text(demo.sources.isEmpty ? "点击右上角添加书源。" : "试试其他分类、筛选条件或关键词。")) }
        Color.clear.frame(height: 0).listRowSeparator(.hidden)
            .alert("删除“\(removal?.name ?? "")”？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                Button("确认删除书源", role: .destructive) { if let removal { demo.removeSource(removal.id) }; removal = nil }
                Button("取消", role: .cancel) { removal = nil }
            } message: { Text("仅移除演示书源，书架与阅读进度保留。") }
    }
    private func rowLabel(_ source: DemoSource) -> some View {
        HStack(spacing: 12) {
            if !compact { Image(systemName: "externaldrive").font(.system(size: 21)) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if source.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).accessibilityLabel("已置顶") }
                    Text(source.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(source.loginStatus.title).font(.system(size: 10))
                        .foregroundStyle(source.loginStatus == .expired ? Palette.accent : Palette.muted)
                }
                Text("\(source.detail) · \(source.enabled ? "已启用" : "已停用")")
                    .font(.system(size: 10)).foregroundStyle(source.hasFailure ? Palette.accent : Palette.muted).lineLimit(1)
            }
        }.foregroundStyle(Palette.green).padding(.vertical, compact ? 15 : 16).padding(.horizontal, compact ? 0 : 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(compact ? Color.clear : Palette.card, in: .rect(cornerRadius: compact ? 0 : 13)).contentShape(Rectangle())
    }
    private func open(_ feature: String, _ source: DemoSource) { route = .init(sourceID: source.id, featureID: feature) }
}

struct DemoSourceDetail: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    let sourceID: String
    var body: some View {
        ScrollView {
            if let source = demo.sources.first(where: { $0.id == sourceID }) {
                VStack(alignment: .leading, spacing: 22) {
                    AppPageHeader(title: source.name, subtitle: source.url, icon: "externaldrive")
                    DemoNotice()
                    AppSettingsCard("书源信息", icon: "info.circle") {
                        Text(source.detail).font(.system(size: 12))
                        Text("分组：\(source.group)").font(.system(size: 12))
                        Text("\(source.loginStatus.title) · 演示登录状态").font(.system(size: 12)).accessibilityIdentifier("sourceLoginStatus")
                        Toggle("启用书源", isOn: Binding(get: { demo.sources.first { $0.id == sourceID }?.enabled ?? false }, set: { value in
                            if let index = demo.sources.firstIndex(where: { $0.id == sourceID }) { demo.sources[index].enabled = value }
                        }))
                    }
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("sourceLogin"), scope: sourceID) } label: {
                        Label(source.loginStatus.action, systemImage: "person.badge.key").frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white).background(Palette.green, in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("sourceDetailLogin")
                    ForEach(["sourceEdit", "sourceDebug"], id: \.self) { id in
                        NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id), scope: sourceID) } label: { FeatureRow(feature: FeatureCatalog.feature(id)) }
                    }
                }.padding(22)
            } else { ContentUnavailableView("书源已移除", systemImage: "externaldrive") }
        }.appPageStyle().navigationTitle("书源详情").navigationBarTitleDisplayMode(.inline)
    }
}

private enum ThemeFilter: String, CaseIterable {
    case all, light, dark, favorites
    var title: String {
        switch self { case .all: "全部"; case .light: "浅色"; case .dark: "深色"; case .favorites: "收藏" }
    }
}

struct ThemeLibraryView: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var query = ""
    @State private var filter: ThemeFilter = .all
    @State private var managing = false
    @State private var selection = Set<String>()
    @State private var showImportResult = false

    private var filteredThemes: [DemoTheme] {
        demo.themes.filter { theme in
            let matchesQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                theme.name.localizedCaseInsensitiveContains(query) || theme.summary.localizedCaseInsensitiveContains(query)
            let matchesFilter = filter == .all || (filter == .light && theme.mode == .light) ||
                (filter == .dark && theme.mode == .dark) || (filter == .favorites && theme.favorite)
            return matchesQuery && matchesFilter
        }
    }
    private var current: DemoTheme? { demo.themes.first { $0.id == demo.activeThemeID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("管理你的阅读气氛").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button(managing ? "完成" : "管理") { managing.toggle(); selection.removeAll() }
                        .font(.system(size: 12, weight: .medium)).accessibilityIdentifier("themeManage")
                }
                if let current { currentCard(current) }
                HStack(spacing: 10) {
                    Button { let result = demo.importDemoThemes(); showImportResult = result.added >= 0 } label: {
                        Label("批量导入", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("themeImport")
                    Button { filter = .favorites } label: {
                        Label("我的收藏", systemImage: "heart").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("themeFavorites")
                }
                if let message = demo.themeImportMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.green)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.green.opacity(0.06), in: .rect(cornerRadius: 10))
                        .accessibilityIdentifier("themeImportResult")
                }
                HStack(spacing: 8) {
                    ForEach(ThemeFilter.allCases, id: \.self) { item in
                        Button(item.title) { filter = item }.font(.system(size: 11))
                            .padding(.horizontal, 13).frame(height: 34)
                            .background(filter == item ? Palette.green : Palette.line.opacity(0.4), in: Capsule())
                            .foregroundStyle(filter == item ? .white : Palette.muted)
                            .accessibilityIdentifier("theme-filter-\(item.rawValue)")
                    }
                }
                if filteredThemes.isEmpty {
                    ContentUnavailableView("没有找到主题", systemImage: "paintpalette", description: Text("换个关键词或筛选条件试试。"))
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                        ForEach(filteredThemes) { theme in
                            ThemeCard(theme: theme, selected: selection.contains(theme.id), managing: managing) {
                                if managing { if selection.contains(theme.id) { selection.remove(theme.id) } else { selection.insert(theme.id) } }
                                else { demo.applyTheme(theme.id) }
                            }
                            .contextMenu {
                                Button(theme.id == demo.activeThemeID ? "已应用" : "应用主题", systemImage: "checkmark.circle") { demo.applyTheme(theme.id) }
                                Button(theme.favorite ? "取消收藏" : "收藏主题", systemImage: "heart") { demo.toggleThemeFavorite(theme.id) }
                                Button("删除主题", systemImage: "trash", role: .destructive) { demo.removeThemes([theme.id]) }
                            }
                        }
                    }
                }
            }.padding(22)
        }.background(Palette.background)
            .searchable(text: $query, prompt: "搜索主题名称或风格")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if managing && !selection.isEmpty {
                    HStack(spacing: 12) {
                        Text("已选 \(selection.count) 个").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("收藏") { selection.forEach { id in if !(demo.themes.first { $0.id == id }?.favorite ?? false) { demo.toggleThemeFavorite(id) } } }
                        Button("删除", role: .destructive) { demo.removeThemes(selection); selection.removeAll() }
                    }.padding(.horizontal, 18).padding(.vertical, 10).background(.regularMaterial)
                }
            }
            .alert("导入结果", isPresented: $showImportResult) {
                Button("知道了", role: .cancel) {}
            } message: { Text(demo.themeImportMessage ?? "") }
    }

    private func currentCard(_ theme: DemoTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("当前使用", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium))
                Spacer(); Text(theme.name).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            ThemePreview(theme: theme, compact: false)
        }.foregroundStyle(Palette.green).padding(16).background(Palette.soft, in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("activeThemeCard")
    }
}

private struct ThemeCard: View {
    let theme: DemoTheme
    let selected: Bool
    let managing: Bool
    let action: () -> Void
    @EnvironmentObject private var demo: FeatureDemoStore
    var body: some View {
        Group {
            if managing {
                Button(action: action) { cardContent }
            } else {
                NavigationLink { ThemeDetailView(themeID: theme.id) } label: { cardContent }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("theme-card-\(theme.id)")
    }
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ThemePreview(theme: theme, compact: true)
                if managing { Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 21)).foregroundStyle(selected ? Palette.green : .white).padding(8).shadow(radius: 2) }
            }
            HStack {
                Text(theme.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(); if theme.favorite { Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            }
            Text("\(theme.mode.title) · \(theme.summary)").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(Color(hex: theme.background)).frame(width: 10, height: 10)
                Circle().fill(Color(hex: theme.ink)).frame(width: 10, height: 10)
                Circle().fill(Color(hex: theme.accent)).frame(width: 10, height: 10)
                Spacer(); Text(theme.id == demo.activeThemeID ? "使用中" : theme.source).font(.system(size: 9)).foregroundStyle(theme.id == demo.activeThemeID ? Palette.green : Palette.muted)
            }
        }.foregroundStyle(Palette.green).padding(10).background(.white.opacity(0.72), in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(theme.id == demo.activeThemeID ? Palette.green : Palette.line, lineWidth: theme.id == demo.activeThemeID ? 1.5 : 0.5) }
    }
}

private struct ThemePreview: View {
    let theme: DemoTheme
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 13) {
            Text("阅山 · 阅读预览").font(.system(size: compact ? 8 : 10)).foregroundStyle(Color(hex: theme.ink).opacity(0.6))
            Text("第三章 山雨欲来").font(.system(size: compact ? 13 : 20, weight: .medium, design: .serif)).foregroundStyle(Color(hex: theme.ink))
            Text("雨是在午后停的。山路上还留着潮湿的气息，风从远处吹来，把书页轻轻翻过一页。")
                .font(.system(size: compact ? 9 : 13, design: .serif)).lineSpacing(compact ? 2 : 5).lineLimit(compact ? 3 : 4).foregroundStyle(Color(hex: theme.ink).opacity(0.85))
            HStack(spacing: 8) { Text("继续阅读").font(.system(size: compact ? 8 : 10, weight: .medium)).foregroundStyle(Color(hex: theme.background)).padding(.horizontal, 8).padding(.vertical, 5).background(Color(hex: theme.accent), in: Capsule()); Spacer(); Text("第 3 章").font(.system(size: compact ? 8 : 10)).foregroundStyle(Color(hex: theme.ink).opacity(0.55)) }
        }.padding(compact ? 10 : 15).frame(maxWidth: .infinity, alignment: .leading).frame(height: compact ? 150 : 150).background(Color(hex: theme.background), in: .rect(cornerRadius: 10))
    }
}

private struct ThemeDetailView: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    let themeID: String
    var body: some View {
        if let theme = demo.themes.first(where: { $0.id == themeID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppPageHeader(title: theme.name, subtitle: "\(theme.mode.title) · \(theme.summary)", icon: "paintpalette")
                    ThemePreview(theme: theme, compact: false).frame(height: 250)
                    HStack(spacing: 10) {
                        Button(theme.id == demo.activeThemeID ? "已应用" : "应用主题") { demo.applyTheme(theme.id) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("themeApply")
                        Button { demo.toggleThemeFavorite(theme.id) } label: { Label(theme.favorite ? "已收藏" : "收藏", systemImage: theme.favorite ? "heart.fill" : "heart") }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("themeFavorite")
                    }
                    AppSettingsCard("主题信息", icon: "info.circle") {
                        Text("来源：\(theme.source)")
                        Text("版本：\(theme.version)")
                        HStack { Text("背景"); Spacer(); Color(hex: theme.background).frame(width: 28, height: 20).clipShape(.rect(cornerRadius: 4)); Text(String(format: "#%06X", theme.background)).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        HStack { Text("正文"); Spacer(); Color(hex: theme.ink).frame(width: 28, height: 20).clipShape(.rect(cornerRadius: 4)); Text(String(format: "#%06X", theme.ink)).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        HStack { Text("强调"); Spacer(); Color(hex: theme.accent).frame(width: 28, height: 20).clipShape(.rect(cornerRadius: 4)); Text(String(format: "#%06X", theme.accent)).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    }.font(.system(size: 12))
                }.padding(22)
            }.appPageStyle().navigationTitle("主题预览").navigationBarTitleDisplayMode(.inline)
        } else { ContentUnavailableView("主题不存在", systemImage: "paintpalette") }
    }
}

struct DemoPlayerCard: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    var body: some View {
        VStack(spacing: 19) {
            Image(systemName: "waveform").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Palette.green).padding(.top, 7)
            Text("长风渡山海").font(.system(size: 23, weight: .medium, design: .serif))
            Text("第三章 山雨欲来 · 无音频的播放器演示").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Slider(value: $demo.audioPosition).tint(Palette.green).accessibilityLabel("朗读进度")
            HStack { Text("03:24"); Spacer(); Text("12:08") }.font(.system(size: 9)).foregroundStyle(Palette.muted)
            HStack(spacing: 35) {
                Button { demo.audioPosition = max(0, demo.audioPosition - 0.1) } label: { Image(systemName: "gobackward.15").frame(width: 44, height: 44) }.accessibilityLabel("后退15秒")
                Button { demo.isPlaying.toggle(); demo.playerVisible = true } label: { Image(systemName: demo.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 23)).frame(width: 62, height: 62).foregroundStyle(.white).background(Palette.green, in: Circle()) }.accessibilityLabel(demo.isPlaying ? "暂停演示朗读" : "播放演示朗读").accessibilityIdentifier("demoPlayerToggle")
                Button { demo.audioPosition = min(1, demo.audioPosition + 0.1) } label: { Image(systemName: "goforward.15").frame(width: 44, height: 44) }.accessibilityLabel("前进15秒")
            }
            HStack { Label("声音", systemImage: "person.wave.2"); Spacer(); Label("1.0×", systemImage: "speedometer"); Spacer(); Label("定时", systemImage: "moon") }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(22).background(Color(hex: 0xE9EDDF), in: .rect(cornerRadius: 19))
    }
}

struct DemoRulesPreview: View {
    let feature: DemoFeature
    let scope: String
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var enabled = true
    var body: some View {
        let pattern = demo.text(feature, "pattern", scope: scope)
        VStack(alignment: .leading, spacing: 14) {
            Toggle(feature.id == "engine" ? "规则兼容预览" : "示例规则组", isOn: $enabled).tint(Palette.green).font(.system(size: 13))
            HStack { Text(feature.id == "engine" ? "规则输出示例" : "处理前"); Spacer(); Text("作用域：当前书籍") }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text("陆青崖把旧地图摊在桌上，风从窗外吹进来。（本章完）").font(.system(size: 15, design: .serif)).lineSpacing(8)
            Divider()
            Text(feature.id == "highlight" ? "高亮预览" : "处理后（演示）").font(.system(size: 10)).foregroundStyle(Palette.muted)
            if feature.id == "highlight" {
                Text(pattern.isEmpty ? "陆青崖" : pattern).padding(5).background(enabled ? Color(hex: 0xDADDBA) : .clear, in: .rect(cornerRadius: 4))
                Text("把旧地图摊在桌上，风从窗外吹进来。").font(.system(size: 14, design: .serif))
            } else { Text(enabled ? "陆青崖把旧地图摊在桌上，风从窗外吹进来。" : "规则已停用").font(.system(size: 15, design: .serif)).lineSpacing(8) }
            Text("JavaScript 与兼容引擎仅展示规则和结果，不执行代码。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(18).background(.white.opacity(0.7), in: .rect(cornerRadius: 14))
    }
}

struct DemoTitleCanvas: View {
    let title: String
    @State private var titlePosition = CGSize.zero
    @State private var decorationPosition = CGSize(width: 0, height: 65)
    @State private var selected = "标题"
    @State private var titleVisible = true
    @State private var decorationVisible = true
    @State private var undo: [(CGSize, CGSize)] = []
    @State private var redo: [(CGSize, CGSize)] = []
    @State private var dragStart: CGSize?
    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Color(hex: 0xECE8DA)
                if titleVisible { Text(title).font(.system(size: 25, weight: .medium, design: .serif)).multilineTextAlignment(.center).lineSpacing(10).offset(titlePosition).gesture(drag(title: true)) }
                if decorationVisible { Image(systemName: "leaf").font(.system(size: 23, weight: .ultraLight)).offset(decorationPosition).gesture(drag(title: false)) }
            }.frame(height: 260).clipShape(.rect(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line)).accessibilityLabel("章节标题画布，支持拖动文字与装饰")
            HStack {
                Picker("选择图层", selection: $selected) { Text("标题").tag("标题"); Text("装饰").tag("装饰") }.pickerStyle(.segmented)
                Button { titleVisible.toggle() } label: { Image(systemName: titleVisible ? "eye" : "eye.slash") }.accessibilityLabel("切换标题图层可见性")
                Button { decorationVisible.toggle() } label: { Image(systemName: decorationVisible ? "leaf" : "leaf.fill") }.accessibilityLabel("切换装饰图层可见性")
            }
            HStack {
                Button("撤销", systemImage: "arrow.uturn.backward") {
                    guard let last = undo.popLast() else { return }; redo.append((titlePosition, decorationPosition)); (titlePosition, decorationPosition) = last
                }.disabled(undo.isEmpty)
                Spacer()
                Button("重做", systemImage: "arrow.uturn.forward") {
                    guard let last = redo.popLast() else { return }; undo.append((titlePosition, decorationPosition)); (titlePosition, decorationPosition) = last
                }.disabled(redo.isEmpty)
            }.font(.system(size: 12))
            Text("直接拖动画布内的标题或装饰，体验布局操作。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.foregroundStyle(Palette.green)
    }
    private func drag(title: Bool) -> some Gesture {
        DragGesture().onChanged { value in
            if dragStart == nil { dragStart = title ? titlePosition : decorationPosition; undo.append((titlePosition, decorationPosition)); redo = [] }
            let start = dragStart ?? .zero
            let offset = CGSize(width: min(90, max(-90, start.width + value.translation.width)), height: min(100, max(-100, start.height + value.translation.height)))
            if title { titlePosition = offset } else { decorationPosition = offset }
        }.onEnded { _ in dragStart = nil }
    }
}

struct DemoCommentsPreview: View {
    var skin: String
    var opacity: Double
    @State private var showComments = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                Text("雨是在午后停的，地图上的山川，似乎又向东挪了半寸。").font(.system(size: 18, design: .serif)).lineSpacing(9)
                Button { showComments.toggle() } label: { Text("12").font(.system(size: 10)).padding(9).background(Palette.green.opacity(0.1), in: .rect(cornerRadius: skin == "纸片" ? 2 : skin == "圆角" ? 15 : 7)) }.opacity(opacity).accessibilityLabel("查看段评")
            }
            if showComments {
                Divider(); Text("段评 · 12 条示例").font(.system(size: 13, weight: .medium))
                ForEach(["山间读者：地图会动这个设定很有趣。", "小雨：期待接下来的旅程。"], id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        }.padding(22).background(.white.opacity(0.7), in: .rect(cornerRadius: 14)).foregroundStyle(Palette.green)
    }
}

struct DemoStatsPreview: View {
    let period: String
    let byBook: Bool
    private var values: [Double] { period == "本月" ? [0.4, 0.7, 0.5, 0.95] : period == "本年" ? [0.5, 0.6, 0.8, 0.3, 0.9, 0.6] : [0.4, 0.7, 0.3, 0.85, 0.6, 1, 0.5] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) { Text(period == "本周" ? "3.6" : period == "本月" ? "16.8" : "128.4").font(.system(size: 38, design: .serif)); Text("小时 · 模拟统计").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            HStack(alignment: .bottom, spacing: 12) { ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 9) { RoundedRectangle(cornerRadius: 5).fill(Palette.green.opacity(index == 5 ? 0.9 : 0.3)).frame(height: 125 * value); Text(byBook ? ["长风", "日落", "群星", "山河", "来信", "重逢", "云海"][index] : "\(index + 1)").font(.system(size: 9)).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity)
            }}.frame(height: 150, alignment: .bottom)
            Text("演示图表，未进行真实阅读计时。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(22).background(Color(hex: 0xEDF0E4), in: .rect(cornerRadius: 15)).foregroundStyle(Palette.green)
    }
}

struct DemoFilePreview: View {
    let file: DemoFile
    @Environment(\.dismiss) private var dismiss
    @State private var page = 1.0
    @State private var strip = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DemoNotice()
                    if file.name.hasSuffix("cbz") || file.name.hasSuffix("zip") {
                        Toggle("条漫连续滚动", isOn: $strip).tint(Palette.green)
                        ForEach(0..<(strip ? 4 : 1), id: \.self) { index in
                            ZStack { Color(hex: index % 2 == 0 ? 0xD7E0D0 : 0xD7C8AA); MountainShape().fill(Palette.green.opacity(0.35)).frame(height: 170); VStack { Text("山间来信").font(.system(size: 28, design: .serif)); Text("原创漫画构图示意 · \(index + 1)").font(.system(size: 11)); Spacer(); Text("“风会带来答案吗？”").padding(13).background(.white, in: Capsule()) }.padding(25) }.frame(height: strip ? 330 : 430).clipShape(.rect(cornerRadius: 9))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 25) {
                            Text(file.name.hasSuffix("pdf") ? "山海图志" : file.name.hasSuffix("epub") ? "日落之前" : "长风渡山海").font(.system(size: 29, design: .serif))
                            Text("第 \(Int(page)) 页 / 章 · 内容预览").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            ForEach(0..<4) { _ in Text("雨是在午后停的。青石板上积着浅浅的水，映出屋檐间一线明亮的天。故事从这里开始，沿着字里行间，走向更远的地方。").font(.system(size: 17, design: .serif)).lineSpacing(9) }
                        }.padding(25).background(.white, in: .rect(cornerRadius: 6))
                    }
                }.padding(22)
            }.background(Palette.background).navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .safeAreaInset(edge: .bottom) { VStack(spacing: 8) { Slider(value: $page, in: 1...12, step: 1).tint(Palette.green); Text("\(Int(page)) / 12 · 模拟文件内容，无真实解析").font(.system(size: 10)).foregroundStyle(Palette.muted) }.padding(18).background(.regularMaterial) }
        }.appPageStyle().presentationBackground(Palette.background).presentationCornerRadius(26)
    }
}

struct SourceImportView: View {
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var method = "链接"
    @State private var address = ""
    @FocusState private var linkFocused: Bool
    @State private var showFiles = false
    @State private var filename: String?
    @State private var preview: SourceImportPreview?
    @State private var message: String?
    @State private var error: String?
    private let example = Data("[{\"bookSourceName\":\"远山书屋\",\"bookSourceUrl\":\"https://yuanshan.example\"}]".utf8)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("导入书源").font(.system(size: 25, weight: .medium, design: .serif))
                Text("粘贴分享链接，或从文件中选择 JSON 书源。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Picker("导入方式", selection: $method) {
                    Label("链接", systemImage: "link").tag("链接")
                    Label("文件", systemImage: "doc").tag("文件")
                }.pickerStyle(.segmented).accessibilityIdentifier("sourceImportMethod")
                AppSettingsCard(method == "链接" ? "书源链接" : "书源文件", icon: method == "链接" ? "link" : "doc") {
                    if method == "链接" {
                        TextField("粘贴 URL 或阅读 3.0 分享链接", text: $address, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(12).background(Palette.background, in: .rect(cornerRadius: 8))
                            .focused($linkFocused).accessibilityIdentifier("sourceImportURL")
                        Text("支持 HTTP / HTTPS、yuedu:// 和 qireader://；当前仅预览示例，不下载链接内容。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Button("预览链接示例") { previewLink() }
                            .buttonStyle(PrimaryButtonStyle(filled: true))
                            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sourceImportLinkPreview")
                    } else {
                        Button { showFiles = true } label: {
                            Label(filename == nil ? "选择 JSON 文件" : "重新选择文件", systemImage: "folder")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(PrimaryButtonStyle(filled: true)).accessibilityIdentifier("sourceImportChooseFile")
                        if let filename { Label(filename, systemImage: "doc.text").font(.system(size: 12)).accessibilityIdentifier("sourceImportFilename") }
                        Text("支持单个书源或书源数组，最大 5 MB。选择后先预览，再确认导入。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Button("使用示例文件") { load(example, name: "示例书源.json") }
                            .font(.system(size: 12)).frame(minHeight: 44).accessibilityIdentifier("sourceImportExample")
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("sourceImportError") }
                if let preview {
                    AppSettingsCard("导入预览", icon: "list.bullet.rectangle") {
                        Text("可新增 \(preview.sources.count) · 重复 \(preview.duplicates) · 无效 \(preview.invalid)")
                            .font(.system(size: 12)).accessibilityIdentifier("sourceImportSummary")
                        ForEach(preview.sources) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.system(size: 14, weight: .medium))
                                Text(source.url).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                        }
                        Button("确认导入 \(preview.sources.count) 个书源") {
                            let added = demo.confirmSourceImport(preview)
                            self.preview = nil
                            message = "已导入 \(added) 个书源，可返回书源列表查看。"
                        }.buttonStyle(PrimaryButtonStyle(filled: true)).disabled(preview.sources.isEmpty)
                            .accessibilityIdentifier("sourceImportConfirm")
                    }
                }
                if let message { Label(message, systemImage: "checkmark.circle").font(.system(size: 12)).accessibilityIdentifier("sourceImportResult") }
                Text("导入的基本信息仅保留在本次运行中，暂不执行书源规则。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Divider()
                DisclosureGroup("导出书源 · JSON 预览") {
                    Text("仅展示当前列表的基本信息，不写入文件或导出解析规则。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.vertical, 8)
                    Text(exportJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("sourceExportPreview")
                }.font(.system(size: 13)).accessibilityIdentifier("sourceExportDisclosure")
            }.padding(22)
        }.appPageStyle().navigationTitle("书源导入导出").navigationBarTitleDisplayMode(.inline)
            .onChange(of: method) { _, _ in clearPreview(); filename = nil; linkFocused = false }
            .onChange(of: address) { _, _ in clearPreview() }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 5 * 1024 * 1024 else { throw SourceImportError.message("文件超过 5 MB，请拆分后重试。") }
                        load(try Data(contentsOf: url), name: url.lastPathComponent)
                    } catch { clearPreview(); filename = nil; self.error = error.localizedDescription }
                case .failure(let error): clearPreview(); self.error = error.localizedDescription
                }
            }
    }

    private var exportJSON: String {
        let rows = demo.sources.map { ["bookSourceName": $0.name, "bookSourceUrl": $0.url, "bookSourceGroup": $0.group] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
    private func clearPreview() { preview = nil; error = nil; message = nil }
    private func load(_ data: Data, name: String? = nil) {
        clearPreview(); filename = name
        do { preview = try SourceImportPreview.parse(data, existing: demo.sources) }
        catch { self.error = error.localizedDescription }
    }
    private func previewLink() {
        linkFocused = false
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https", "yuedu", "qireader"].contains(scheme),
              !["http", "https"].contains(scheme) || url.host?.isEmpty == false else {
            clearPreview(); error = "请输入有效的书源 URL 或阅读分享链接。"; return
        }
        load(example)
    }
}
