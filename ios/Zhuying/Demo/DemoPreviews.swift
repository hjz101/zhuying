import SwiftUI
import UniformTypeIdentifiers

struct SourceManagementView: View {
    @Environment(\.themeAppearance) private var appAppearance
    var title = "书源"
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
        }.background(ThemeSurface())
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
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
            }.padding(4).background(appAppearance.palette.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            HStack {
                Text(managing ? "已选 \(selection.count) / \(sources.count)" : "\(sources.count) 个书源\(demo.isDemo ? " · 示例数据" : "")")
                    .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).accessibilityIdentifier("sourceCount")
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
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10).foregroundStyle(appAppearance.palette.green)
            .overlay(alignment: .bottom) { Rectangle().fill(appAppearance.palette.primary.opacity(0.12)).frame(height: 0.5) }
    }

    private func categoryButton(_ value: DemoSourceKind?) -> some View {
        let count = demo.sources.filter { value == nil || $0.kind == value }.count
        return Button { kind = value } label: {
            Text("\(value?.rawValue ?? "全部") \(count)")
                .font(.system(size: 12, weight: kind == value ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(kind == value ? appAppearance.palette.card : .clear, in: .rect(cornerRadius: 7))
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
            ThemeLabel(isFiltered ? "已筛选" : "筛选", systemImage: "line.3.horizontal.decrease")
                .font(.system(size: 12)).padding(.trailing, 10)
        }.accessibilityIdentifier("sourceFilter")
    }

    @ViewBuilder private var toolbarActions: some View {
        if managing {
            Button("完成") { managing = false; selection.removeAll() }.accessibilityIdentifier("sourceManageDone")
        } else {
            Menu {
                ThemeButton("导入书源", systemImage: "square.and.arrow.down") {
                    route = .init(sourceID: "main", featureID: "sourceImport")
                }
                ThemeButton("手动新建", systemImage: "square.and.pencil") {
                    route = .init(sourceID: demo.createSource(kind: kind ?? .novel, group: group), featureID: "sourceEdit")
                }
            } label: { ThemeIcon(systemName: "plus") }.accessibilityLabel("添加书源").accessibilityIdentifier("sourceAdd")
            Menu {
                ThemeButton("导出书源", systemImage: "square.and.arrow.up") { route = .init(sourceID: "main", featureID: "sourceImport") }
                ThemeButton("批量检测", systemImage: "checklist") { route = .init(sourceID: "main", featureID: "sourceBatch") }
                ThemeButton("规则调试", systemImage: "curlybraces") { route = .init(sourceID: "main", featureID: "engine") }
            } label: { ThemeIcon(systemName: "ellipsis") }.accessibilityLabel("更多书源工具").accessibilityIdentifier("sourceMore")
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
            Button(role: .destructive) { pendingRemoval = selection } label: { batchLabel("删除", "trash").foregroundStyle(appAppearance.palette.accent) }.accessibilityIdentifier("sourceBatchDelete")
        }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(appAppearance.palette.green)
            .disabled(selection.isEmpty).padding(.horizontal, 12).padding(.vertical, 10)
            .background(appAppearance.palette.card).overlay(alignment: .top) { Divider() }
    }
    private func batchLabel(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 4) { ThemeIcon(systemName: icon).font(.system(size: 17)); Text(text) }.frame(maxWidth: .infinity, minHeight: 44)
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
    @Environment(\.themeAppearance) private var appAppearance
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
                        ThemeIcon(systemName: selection.wrappedValue.contains(source.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(appAppearance.palette.green)
                        rowLabel(source)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("source-select-\(source.id)")
                    .accessibilityValue(selection.wrappedValue.contains(source.id) ? "已选择" : "未选择")
            } else {
            NavigationLink { DemoSourceDetail(sourceID: source.id) } label: {
                rowLabel(source)
            }.buttonStyle(.plain).accessibilityIdentifier("source-row-\(source.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { open("sourceLogin", source) } label: { ThemeLabel(demo.isDemo || source.id == "shushan" ? source.loginStatus.action : "访问说明", systemImage: "person.badge.key") }.tint(appAppearance.palette.primary)
                        .accessibilityIdentifier("source-login-\(source.id)")
                    Button { open("sourceEdit", source) } label: { ThemeLabel("编辑", systemImage: "square.and.pencil") }.tint(appAppearance.palette.accent)
                        .accessibilityIdentifier("source-edit-\(source.id)")
                }
                .contextMenu {
                    ThemeButton(source.pinned ? "取消置顶" : "置顶书源", systemImage: "pin") { demo.toggleSourcePin(source.id) }
                    ThemeButton(demo.isDemo || source.id == "shushan" ? source.loginStatus.action : "访问说明", systemImage: "person.badge.key") { open("sourceLogin", source) }
                    ThemeButton("编辑", systemImage: "square.and.pencil") { open("sourceEdit", source) }
                    ThemeButton("调试", systemImage: "ladybug") { open("sourceDebug", source) }
                    ThemeButton(source.enabled ? "停用书源" : "启用书源", systemImage: "power") {
                        demo.setSourcesEnabled([source.id], enabled: !source.enabled)
                    }
                    ThemeButton("移入个人收藏", systemImage: "folder") {
                        demo.moveSources([source.id], group: "个人收藏")
                    }
                    ThemeButton("删除书源", systemImage: "trash", role: .destructive) { removal = source }
                }
            }
        }
        if sources.isEmpty { ThemeUnavailableView(demo.sources.isEmpty ? "还没有书源" : "没有符合条件的书源", systemImage: "externaldrive", description: Text(demo.sources.isEmpty ? "点击右上角添加书源。" : "试试其他分类、筛选条件或关键词。")) }
        Color.clear.frame(height: 0).listRowSeparator(.hidden)
            .alert("删除“\(removal?.name ?? "")”？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                Button("确认删除书源", role: .destructive) { if let removal { demo.removeSource(removal.id) }; removal = nil }
                Button("取消", role: .cancel) { removal = nil }
            } message: { Text(demo.isDemo ? "仅移除演示书源，书架与阅读进度保留。" : "移除书源后，书架与阅读进度保留。") }
    }
    private func rowLabel(_ source: DemoSource) -> some View {
        HStack(spacing: 12) {
            if !compact { ThemeIcon(systemName: "externaldrive").font(.system(size: 21)) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if source.pinned { ThemeIcon(systemName: "pin.fill").font(.system(size: 10)).accessibilityLabel("已置顶") }
                    Text(source.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SourcePackages.accountTitle(source,isDemo:demo.isDemo)).font(.system(size: 10))
                        .foregroundStyle(source.loginStatus == .expired ? appAppearance.palette.accent : appAppearance.palette.muted)
                }
                Text("\(SourcePackages.executionDetail(source, isDemo: demo.isDemo)) · \(source.enabled ? "已启用" : "已停用")")
                    .font(.system(size: 10)).foregroundStyle(source.hasFailure ? appAppearance.palette.accent : appAppearance.palette.muted).lineLimit(1)
            }
        }.foregroundStyle(appAppearance.palette.green).padding(.vertical, compact ? 15 : 16).padding(.horizontal, compact ? 0 : 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(compact ? Color.clear : appAppearance.palette.card, in: .rect(cornerRadius: compact ? 0 : 13)).contentShape(Rectangle())
    }
    private func open(_ feature: String, _ source: DemoSource) { route = .init(sourceID: source.id, featureID: feature) }
}

struct DemoSourceDetail: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var demo: FeatureDemoStore
    let sourceID: String
    var body: some View {
        ScrollView {
            if let source = demo.sources.first(where: { $0.id == sourceID }) {
                VStack(alignment: .leading, spacing: 22) {
                    AppPageHeader(title: source.name, subtitle: source.url, icon: "externaldrive")
                    if demo.isDemo { DemoNotice() }
                    AppSettingsCard("书源信息", icon: "info.circle") {
                        Text(SourcePackages.executionDetail(source, isDemo: demo.isDemo)).font(.system(size: 12))
                        Text("分组：\(source.group)").font(.system(size: 12))
                        Text("\(SourcePackages.accountTitle(source,isDemo:demo.isDemo))\(demo.isDemo ? " · 演示登录状态" : "")").font(.system(size: 12)).accessibilityIdentifier("sourceLoginStatus")
                        Toggle("启用书源", isOn: Binding(get: { demo.sources.first { $0.id == sourceID }?.enabled ?? false }, set: { value in
                            if let index = demo.sources.firstIndex(where: { $0.id == sourceID }) { demo.sources[index].enabled = value }
                        }))
                    }
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("sourceLogin"), scope: sourceID) } label: {
                        ThemeLabel(demo.isDemo || source.id == "shushan" ? source.loginStatus.action : "访问说明", systemImage: "person.badge.key").frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(appAppearance.palette.onPrimary).background(appAppearance.palette.primary, in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("sourceDetailLogin")
                    ForEach(["sourceEdit", "sourceDebug"], id: \.self) { id in
                        NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id), scope: sourceID) } label: { FeatureRow(feature: FeatureCatalog.feature(id)) }
                    }
                }.padding(22)
            } else { ThemeUnavailableView("书源已移除", systemImage: "externaldrive") }
        }.appPageStyle().navigationTitle("书源详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct DemoPlayerCard: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var demo: FeatureDemoStore
    var body: some View {
        VStack(spacing: 19) {
            ThemeIcon(systemName: "waveform").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(appAppearance.palette.green).padding(.top, 7)
            Text("长风渡山海").font(.system(size: 23, weight: .medium, design: .serif))
            Text("第三章 山雨欲来 · 无音频的播放器演示").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
            Slider(value: $demo.audioPosition).tint(appAppearance.palette.primary).accessibilityLabel("朗读进度")
            HStack { Text("03:24"); Spacer(); Text("12:08") }.font(.system(size: 9)).foregroundStyle(appAppearance.palette.muted)
            HStack(spacing: 35) {
                Button { demo.audioPosition = max(0, demo.audioPosition - 0.1) } label: { ThemeIcon(systemName: "gobackward.15").frame(width: 44, height: 44) }.accessibilityLabel("后退15秒")
                Button { demo.isPlaying.toggle(); demo.playerVisible = true } label: { ThemeIcon(systemName: demo.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 23)).frame(width: 62, height: 62).foregroundStyle(appAppearance.palette.onPrimary).background(appAppearance.palette.primary, in: Circle()) }.accessibilityLabel(demo.isPlaying ? "暂停演示朗读" : "播放演示朗读").accessibilityIdentifier("demoPlayerToggle")
                Button { demo.audioPosition = min(1, demo.audioPosition + 0.1) } label: { ThemeIcon(systemName: "goforward.15").frame(width: 44, height: 44) }.accessibilityLabel("前进15秒")
            }
            HStack { ThemeLabel("声音", systemImage: "person.wave.2"); Spacer(); ThemeLabel("1.0×", systemImage: "speedometer"); Spacer(); ThemeLabel("定时", systemImage: "moon") }.font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
        }.padding(22).background(appAppearance.palette.surface(0xE9EDDF), in: .rect(cornerRadius: 19))
    }
}

struct DemoRulesPreview: View {
    @Environment(\.themeAppearance) private var appAppearance
    let feature: DemoFeature
    let scope: String
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var enabled = true
    var body: some View {
        let pattern = demo.text(feature, "pattern", scope: scope)
        VStack(alignment: .leading, spacing: 14) {
            Toggle(feature.id == "engine" ? "规则兼容预览" : "示例规则组", isOn: $enabled).tint(appAppearance.palette.primary).font(.system(size: 13))
            HStack { Text(feature.id == "engine" ? "规则输出示例" : "处理前"); Spacer(); Text("作用域：当前书籍") }.font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
            Text("陆青崖把旧地图摊在桌上，风从窗外吹进来。（本章完）").font(.system(size: 15, design: .serif)).lineSpacing(8)
            Divider()
            Text(feature.id == "highlight" ? "高亮预览" : "处理后（演示）").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
            if feature.id == "highlight" {
                Text(pattern.isEmpty ? "陆青崖" : pattern).padding(5).background(enabled ? appAppearance.palette.surface(0xDADDBA) : .clear, in: .rect(cornerRadius: 4))
                Text("把旧地图摊在桌上，风从窗外吹进来。").font(.system(size: 14, design: .serif))
            } else { Text(enabled ? "陆青崖把旧地图摊在桌上，风从窗外吹进来。" : "规则已停用").font(.system(size: 15, design: .serif)).lineSpacing(8) }
            Text("JavaScript 与兼容引擎仅展示规则和结果，不执行代码。").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
        }.padding(18).background(appAppearance.palette.card, in: .rect(cornerRadius: 14))
    }
}

struct DemoTitleCanvas: View {
    @Environment(\.themeAppearance) private var appAppearance
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
                appAppearance.palette.surface(0xECE8DA)
                if titleVisible { Text(title).font(.system(size: 25, weight: .medium, design: .serif)).multilineTextAlignment(.center).lineSpacing(10).offset(titlePosition).gesture(drag(title: true)) }
                if decorationVisible { ThemeIcon(systemName: "leaf").font(.system(size: 23, weight: .ultraLight)).offset(decorationPosition).gesture(drag(title: false)) }
            }.frame(height: 260).clipShape(.rect(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(appAppearance.palette.line)).accessibilityLabel("章节标题画布，支持拖动文字与装饰")
            HStack {
                Picker("选择图层", selection: $selected) { Text("标题").tag("标题"); Text("装饰").tag("装饰") }.pickerStyle(.segmented)
                Button { titleVisible.toggle() } label: { ThemeIcon(systemName: titleVisible ? "eye" : "eye.slash") }.accessibilityLabel("切换标题图层可见性")
                Button { decorationVisible.toggle() } label: { ThemeIcon(systemName: decorationVisible ? "leaf" : "leaf.fill") }.accessibilityLabel("切换装饰图层可见性")
            }
            HStack {
                ThemeButton("撤销", systemImage: "arrow.uturn.backward") {
                    guard let last = undo.popLast() else { return }; redo.append((titlePosition, decorationPosition)); (titlePosition, decorationPosition) = last
                }.disabled(undo.isEmpty)
                Spacer()
                ThemeButton("重做", systemImage: "arrow.uturn.forward") {
                    guard let last = redo.popLast() else { return }; undo.append((titlePosition, decorationPosition)); (titlePosition, decorationPosition) = last
                }.disabled(redo.isEmpty)
            }.font(.system(size: 12))
            Text("直接拖动画布内的标题或装饰，体验布局操作。").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
        }.foregroundStyle(appAppearance.palette.green)
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
    @Environment(\.themeAppearance) private var appAppearance
    var skin: String
    var opacity: Double
    @State private var showComments = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                Text("雨是在午后停的，地图上的山川，似乎又向东挪了半寸。").font(.system(size: 18, design: .serif)).lineSpacing(9)
                Button { showComments.toggle() } label: { Text("12").font(.system(size: 10)).padding(9).background(appAppearance.palette.primary.opacity(0.1), in: .rect(cornerRadius: skin == "纸片" ? 2 : skin == "圆角" ? 15 : 7)) }.opacity(opacity).accessibilityLabel("查看段评")
            }
            if showComments {
                Divider(); Text("段评 · 12 条示例").font(.system(size: 13, weight: .medium))
                ForEach(["山间读者：地图会动这个设定很有趣。", "小雨：期待接下来的旅程。"], id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(appAppearance.palette.muted) }
            }
        }.padding(22).background(appAppearance.palette.card, in: .rect(cornerRadius: 14)).foregroundStyle(appAppearance.palette.green)
    }
}

struct DemoStatsPreview: View {
    @Environment(\.themeAppearance) private var appAppearance
    let period: String
    let byBook: Bool
    private var values: [Double] { period == "本月" ? [0.4, 0.7, 0.5, 0.95] : period == "本年" ? [0.5, 0.6, 0.8, 0.3, 0.9, 0.6] : [0.4, 0.7, 0.3, 0.85, 0.6, 1, 0.5] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) { Text(period == "本周" ? "3.6" : period == "本月" ? "16.8" : "128.4").font(.system(size: 38, design: .serif)); Text("小时 · 模拟统计").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted) }
            HStack(alignment: .bottom, spacing: 12) { ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 9) { RoundedRectangle(cornerRadius: 5).fill(appAppearance.palette.primary.opacity(index == 5 ? 0.9 : 0.3)).frame(height: 125 * value); Text(byBook ? ["长风", "日落", "群星", "山河", "来信", "重逢", "云海"][index] : "\(index + 1)").font(.system(size: 9)).foregroundStyle(appAppearance.palette.muted) }.frame(maxWidth: .infinity)
            }}.frame(height: 150, alignment: .bottom)
            Text("演示图表，未进行真实阅读计时。").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
        }.padding(22).background(appAppearance.palette.surface(0xEDF0E4), in: .rect(cornerRadius: 15)).foregroundStyle(appAppearance.palette.green)
    }
}

struct DemoFilePreview: View {
    @Environment(\.themeAppearance) private var appAppearance
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
                        Toggle("条漫连续滚动", isOn: $strip).tint(appAppearance.palette.primary)
                        ForEach(0..<(strip ? 4 : 1), id: \.self) { index in
                            ZStack { Color(hex: index % 2 == 0 ? 0xD7E0D0 : 0xD7C8AA); MountainShape().fill(appAppearance.palette.primary.opacity(0.35)).frame(height: 170); VStack { Text("山间来信").font(.system(size: 28, design: .serif)); Text("原创漫画构图示意 · \(index + 1)").font(.system(size: 11)); Spacer(); Text("“风会带来答案吗？”").padding(13).background(.white, in: Capsule()) }.padding(25).foregroundStyle(Palette.green) }.frame(height: strip ? 330 : 430).clipShape(.rect(cornerRadius: 9))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 25) {
                            Text(file.name.hasSuffix("pdf") ? "山海图志" : file.name.hasSuffix("epub") ? "日落之前" : "长风渡山海").font(.system(size: 29, design: .serif))
                            Text("第 \(Int(page)) 页 / 章 · 内容预览").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            ForEach(0..<4) { _ in Text("雨是在午后停的。青石板上积着浅浅的水，映出屋檐间一线明亮的天。故事从这里开始，沿着字里行间，走向更远的地方。").font(.system(size: 17, design: .serif)).lineSpacing(9) }
                        }.padding(25).foregroundStyle(Palette.green).background(.white, in: .rect(cornerRadius: 6))
                    }
                }.padding(22)
            }.background(ThemeSurface()).navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .safeAreaInset(edge: .bottom) { VStack(spacing: 8) { Slider(value: $page, in: 1...12, step: 1).tint(appAppearance.palette.primary); Text("\(Int(page)) / 12 · 模拟文件内容，无真实解析").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted) }.padding(18).background(.regularMaterial) }
        }.appPageStyle().presentationBackground(appAppearance.palette.background).presentationCornerRadius(26)
    }
}

struct SourceImportView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var method = "链接"
    @State private var address = ""
    @FocusState private var linkFocused: Bool
    @State private var showFiles = false
    @State private var filename: String?
    @State private var preview: SourceImportPreview?
    @State private var message: String?
    @State private var error: String?
    #if DEBUG
    private let example = Data("[{\"bookSourceName\":\"远山书屋\",\"bookSourceUrl\":\"https://yuanshan.example\"}]".utf8)
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("导入书源").font(.system(size: 25, weight: .medium, design: .serif))
                Text("粘贴分享链接，或从文件中选择 JSON 书源。")
                    .font(.system(size: 12)).foregroundStyle(appAppearance.palette.muted)
                Picker("导入方式", selection: $method) {
                    ThemeLabel("链接", systemImage: "link").tag("链接")
                    ThemeLabel("文件", systemImage: "doc").tag("文件")
                }.pickerStyle(.segmented).accessibilityIdentifier("sourceImportMethod")
                AppSettingsCard(method == "链接" ? "书源链接" : "书源文件", icon: method == "链接" ? "link" : "doc") {
                    if method == "链接" {
                        TextField("粘贴 URL 或阅读 3.0 分享链接", text: $address, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(12).background(appAppearance.palette.background, in: .rect(cornerRadius: 8))
                            .focused($linkFocused).accessibilityIdentifier("sourceImportURL")
                        Text("支持 HTTP / HTTPS、yuedu:// 和 qireader://；当前仅预览示例，不下载链接内容。")
                            .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                        Button("预览链接示例") { previewLink() }
                            .buttonStyle(PrimaryButtonStyle(filled: true))
                            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sourceImportLinkPreview")
                    } else {
                        Button { showFiles = true } label: {
                            ThemeLabel(filename == nil ? "选择 JSON 文件" : "重新选择文件", systemImage: "folder")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(PrimaryButtonStyle(filled: true)).accessibilityIdentifier("sourceImportChooseFile")
                        if let filename { ThemeLabel(filename, systemImage: "doc.text").font(.system(size: 12)).accessibilityIdentifier("sourceImportFilename") }
                        Text("支持单个书源或书源数组，最大 5 MB。选择后先预览，再确认导入。")
                            .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                        #if DEBUG
                        Button("使用示例文件") { load(example, name: "示例书源.json") }
                            .font(.system(size: 12)).frame(minHeight: 44).accessibilityIdentifier("sourceImportExample")
                        #endif
                    }
                }
                if let error { ThemeLabel(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("sourceImportError") }
                if let preview {
                    AppSettingsCard("导入预览", icon: "list.bullet.rectangle") {
                        Text("可新增 \(preview.sources.count) · 重复 \(preview.duplicates) · 无效 \(preview.invalid)")
                            .font(.system(size: 12)).accessibilityIdentifier("sourceImportSummary")
                        ForEach(preview.sources) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.system(size: 14, weight: .medium))
                                Text(source.url).font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
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
                if let message { ThemeLabel(message, systemImage: "checkmark.circle").font(.system(size: 12)).accessibilityIdentifier("sourceImportResult") }
                Text("导入的基本信息仅保留在本次运行中，暂不执行书源规则。")
                    .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                Divider()
                DisclosureGroup("导出书源 · JSON 预览") {
                    Text("仅展示当前列表的基本信息，不写入文件或导出解析规则。")
                        .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).padding(.vertical, 8)
                    Text(exportJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("sourceExportPreview")
                }.font(.system(size: 13)).accessibilityIdentifier("sourceExportDisclosure")
            }.padding(22)
        }.appPageStyle().navigationTitle("书源导入导出").navigationBarTitleDisplayMode(.inline)
            .onChange(of: method) { _, _ in clearPreview(); filename = nil; linkFocused = false }
            .onChange(of: address) { _, _ in clearPreview() }
            .nativeFileImporter(isPresented: $showFiles, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        load(try ImportedFileReader.read(url, maximumBytes: 5 * 1024 * 1024), name: url.lastPathComponent)
                    } catch { clearPreview(); filename = nil; self.error = error.localizedDescription }
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { clearPreview(); self.error = error.localizedDescription }
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
        #if DEBUG
        load(example)
        #else
        clearPreview(); error = "请通过书源导入入口读取您选择的文件或链接。"
        #endif
    }
}
