import SwiftUI

private enum ShortcutSheet: Identifiable {
    case manage, add, replace(String)
    var id: String { switch self { case .manage: "manage"; case .add: "add"; case .replace(let id): "replace-\(id)" } }
}

struct ToolboxView: View {
    @EnvironmentObject private var toolbox: ToolboxStore
    @State private var query = ""
    @State private var category: ToolCategory?
    @State private var expanded = Set<ToolCategory>()
    @State private var expandedDetails = Set<ToolCategory>()
    @State private var sheet: ShortcutSheet?
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var results: [DemoFeature] { category?.search(query) ?? FeatureCatalog.search(query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !searching { shortcuts }
                categoryBar
                if searching {
                    Text("\(results.count) 项结果\(category.map { " · \($0.title)" } ?? " · 全部工具")")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).accessibilityIdentifier("toolsSearchCount")
                    if results.isEmpty {
                        ContentUnavailableView("没有找到相关功能", systemImage: "magnifyingglass", description: Text("试试其他关键词，或切换到全部分类。"))
                    } else { rows(results) }
                } else if let category {
                    categoryContents(category)
                } else {
                    VStack(spacing: 0) {
                        ForEach(ToolCategory.allCases) { item in
                            Button {
                                if expanded.contains(item) { expanded.remove(item) } else { expanded.insert(item) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.icon).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.system(size: 15, weight: .medium))
                                        Text(item.summary).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    }
                                    Spacer()
                                    Image(systemName: expanded.contains(item) ? "chevron.down" : "chevron.right").font(.system(size: 11))
                                }.frame(minHeight: 62).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("tools-group-\(item.id)")
                                .accessibilityValue(expanded.contains(item) ? "已展开" : "已收起")
                            if expanded.contains(item) { categoryContents(item).padding(.top, 12).padding(.bottom, 8) }
                            Divider()
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 20)
        }.appPageStyle().navigationTitle("全部工具").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模块或功能")
            .sheet(item: $sheet) { item in
                NavigationStack {
                    switch item {
                    case .manage: ToolShortcutEditor()
                    case .add: ToolShortcutPicker()
                    case .replace(let id): ToolShortcutPicker(replacing: id)
                    }
                }.environmentObject(toolbox)
            }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("常用工具").font(.system(size: 16, weight: .medium, design: .serif))
                Spacer()
                Button("编辑") { sheet = .manage }.font(.system(size: 12)).accessibilityIdentifier("toolsEditShortcuts")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(toolbox.pinnedIDs, id: \.self) { id in
                    let feature = FeatureCatalog.feature(id)
                    NavigationLink { ToolDestination(feature: feature) } label: {
                        VStack(spacing: 7) {
                            Image(systemName: feature.icon).font(.system(size: 21, weight: .light)).frame(height: 28)
                            Text(feature.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                            ToolCapabilityBadge(feature: feature)
                        }.frame(maxWidth: .infinity, minHeight: 84, alignment: .top).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("tool-shortcut-\(id)")
                        .contextMenu {
                            Button("替换工具", systemImage: "arrow.triangle.swap") { sheet = .replace(id) }
                            Button("向前移动", systemImage: "arrow.left") { toolbox.shift(id, by: -1) }.disabled(toolbox.pinnedIDs.first == id)
                            Button("向后移动", systemImage: "arrow.right") { toolbox.shift(id, by: 1) }.disabled(toolbox.pinnedIDs.last == id)
                            Button("移出常用", systemImage: "minus.circle", role: .destructive) { toolbox.remove(id) }
                        }
                }
                if toolbox.canAdd {
                    Button { sheet = .add } label: {
                        VStack(spacing: 7) {
                            Image(systemName: "plus.circle").font(.system(size: 21, weight: .light)).frame(height: 28)
                            Text("添加常用").font(.system(size: 11))
                        }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
                    }.buttonStyle(.plain).accessibilityIdentifier("toolsAddShortcut")
                }
            }.accessibilityIdentifier("toolsShortcuts")
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryButton(nil)
                ForEach(ToolCategory.allCases) { categoryButton($0) }
            }.padding(.vertical, 2)
        }.accessibilityIdentifier("toolsCategories")
    }
    private func categoryButton(_ value: ToolCategory?) -> some View {
        Button { category = value } label: {
            Text(value?.shortTitle ?? "全部").font(.system(size: 12, weight: category == value ? .semibold : .regular))
                .padding(.horizontal, 15).frame(minHeight: 40)
                .foregroundStyle(category == value ? Color.white : Palette.green)
                .background(category == value ? Palette.green : Palette.soft, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("tool-category-\(value?.id ?? "all")")
            .accessibilityAddTraits(category == value ? .isSelected : [])
    }

    private func categoryContents(_ item: ToolCategory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if category != nil { Text(item.title).font(.system(size: 17, weight: .medium, design: .serif)) }
            rows(item.primaryFeatures)
            if !item.secondaryFeatures.isEmpty {
                Button {
                    if expandedDetails.contains(item) { expandedDetails.remove(item) } else { expandedDetails.insert(item) }
                } label: {
                    HStack {
                        Text(item == .files ? "格式支持与演示" : "更多功能与细项")
                        Spacer()
                        Image(systemName: expandedDetails.contains(item) ? "chevron.down" : "chevron.right")
                    }.frame(minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).font(.system(size: 12)).accessibilityIdentifier("tools-details-\(item.id)")
                    .accessibilityValue(expandedDetails.contains(item) ? "已展开" : "已收起")
                if expandedDetails.contains(item) {
                    if item == .files {
                        Text("文件统一从智能导入选择；当前实际支持 TXT 和文字 PDF。以下是各格式的演示页面。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.vertical, 10)
                    }
                    rows(item.secondaryFeatures)
                }
            }
            if item == .sources {
                Text("登录与编辑：进入书源列表后左滑，或长按具体书源。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func rows(_ features: [DemoFeature]) -> some View {
        VStack(spacing: 0) {
            ForEach(features) { feature in
                NavigationLink { ToolDestination(feature: feature) } label: { ToolEntryRow(feature: feature) }
                    .buttonStyle(.plain).accessibilityIdentifier("feature-\(feature.id)")
                    .contextMenu {
                        if toolbox.pinnedIDs.contains(feature.id) {
                            Button("移出常用", systemImage: "minus.circle") { toolbox.remove(feature.id) }
                        } else if toolbox.canAdd {
                            Button("加入常用", systemImage: "plus.circle") { toolbox.add(feature.id) }
                        } else {
                            Button("常用已满，编辑常用", systemImage: "square.and.pencil") { sheet = .manage }
                        }
                    }
                Divider()
            }
        }
    }
}

private struct ToolDestination: View {
    let feature: DemoFeature
    var body: some View {
        Group {
            if feature.id == "sources" { SourceManagementView(title: feature.title) }
            else if feature.id == "statistics" { FootprintsView(title: feature.title) }
            else { FeatureDemoView(feature: feature) }
        }
    }
}

private struct ToolEntryRow: View {
    let feature: DemoFeature
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: feature.icon).font(.system(size: 19, weight: .light)).frame(width: 27)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(feature.title).font(.system(size: 14, weight: .medium))
                    ToolCapabilityBadge(feature: feature)
                }
                Text(feature.summary).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.foregroundStyle(Palette.green).frame(minHeight: 65).contentShape(Rectangle())
    }
}

private struct ToolCapabilityBadge: View {
    let feature: DemoFeature
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        if let badge = library.isDemo ? feature.capabilityBadge : ProductionCapabilities.badge(for: feature.id) {
            Text(badge).font(.system(size: 8)).foregroundStyle(Palette.accent)
                .padding(.horizontal, 5).padding(.vertical, 3).background(Palette.accent.opacity(0.08), in: Capsule())
                .accessibilityIdentifier("tool-status-\(feature.id)")
        }
    }
}

private struct ToolShortcutEditor: View {
    @EnvironmentObject private var toolbox: ToolboxStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                ForEach(toolbox.pinnedIDs, id: \.self) { id in
                    Label(FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon)
                        .font(.system(size: 14)).accessibilityIdentifier("shortcut-edit-\(id)")
                }.onDelete { offsets in for id in offsets.map({ toolbox.pinnedIDs[$0] }) { toolbox.remove(id) } }
                    .onMove { toolbox.move(from: $0, to: $1) }
            } header: { Text("常用工具 · \(toolbox.pinnedIDs.count) / 4") }
                footer: { Text("拖动右侧把手调整顺序；更改自动保存在本机。") }
            Section {
                NavigationLink("添加常用工具") { ToolShortcutPicker() }.disabled(!toolbox.canAdd).accessibilityIdentifier("shortcutEditorAdd")
                if !toolbox.canAdd { Text("最多固定四个，先移除一项再添加；也可在首页长按替换。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        }.environment(\.editMode, .constant(.active)).scrollContentBackground(.hidden).appPageStyle()
            .navigationTitle("编辑常用").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }
}

private struct ToolShortcutPicker: View {
    var replacing: String?
    @EnvironmentObject private var toolbox: ToolboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var options: [DemoFeature] { FeatureCatalog.search(query).filter { !toolbox.pinnedIDs.contains($0.id) } }
    var body: some View {
        List {
            if options.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(options) { feature in
                Button {
                    let success = replacing.map { toolbox.replace($0, with: feature.id) } ?? toolbox.add(feature.id)
                    if success { dismiss() }
                } label: { ToolEntryRow(feature: feature) }.accessibilityIdentifier("shortcut-pick-\(feature.id)")
            }
        }.scrollContentBackground(.hidden).appPageStyle()
            .navigationTitle(replacing == nil ? "添加常用" : "替换工具").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索要固定的工具")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
    }
}
