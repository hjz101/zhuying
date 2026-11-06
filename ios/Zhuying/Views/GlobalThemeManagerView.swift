import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let zhuyingTheme = UTType(exportedAs: "com.zhuying.theme", conformingTo: .zip)
}

private enum GlobalThemeFilter: String, CaseIterable {
    case all = "全部", light = "浅色", dark = "深色", imported = "已导入"
}
private struct ThemeShareFiles: Identifiable {
    let id = UUID()
    let files: [ExportFile]
}

struct GlobalThemeManagerView: View {
    var onReadingImport: ((String) -> Void)? = nil
    @Environment(\.themeAppearance) private var appAppearance
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @ObservedObject private var themes = GlobalThemeStore.shared
    @State private var showImport = false
    @State private var pending: GlobalThemeBundle?
    @State private var message: String?
    @State private var showExport = false
    @State private var preparedExport: ExportFile?
    @State private var activeExport: ExportFile?
    @State private var shareFiles: ThemeShareFiles?
    @State private var confirmClearRestore = false
    @State private var managing = false
    @State private var selection = Set<String>()
    @State private var filter = GlobalThemeFilter.all
    @State private var menuBundle: GlobalThemeBundle?
    @State private var deletion = Set<String>()
    private var visible: [GlobalThemeBundle] {
        themes.bundles.filter { bundle in
            switch filter {
            case .all: return true
            case .light: return !bundle.document.app.dark
            case .dark: return bundle.document.app.dark
            case .imported: return themes.canDelete(bundle)
            }
        }
    }
    private var chosen: [GlobalThemeBundle] { themes.bundles.filter { selection.contains($0.id) } }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 14), count: typeSize.isAccessibilitySize ? 1 : 2) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !managing { currentCard }
                HStack {
                    Text(managing ? "我的全部主题" : "我的主题").font(.headline)
                    Spacer()
                    if managing {
                        Button(selection.isSuperset(of: Set(visible.map(\.id))) ? "取消全选" : "全选") {
                            let ids = Set(visible.map(\.id))
                            if selection.isSuperset(of: ids) { selection.subtract(ids) } else { selection.formUnion(ids) }
                        }.accessibilityIdentifier("globalThemeSelectAll")
                    }
                    Button { managing.toggle(); selection.removeAll(); filter = .all } label: { Text(managing ? "完成" : "管理").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                        .accessibilityIdentifier("globalThemeManage")
                }.buttonStyle(ThemeButtonFeedbackStyle()).font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(GlobalThemeFilter.allCases, id: \.self) { value in
                            Button { filter = value } label: {
                                Text(value.rawValue).font(.subheadline).padding(.horizontal, 16).frame(minHeight: 44)
                                    .background(filter == value ? appAppearance.palette.primary : appAppearance.palette.soft, in: Capsule())
                                    .foregroundStyle(filter == value ? appAppearance.palette.onPrimary : appAppearance.palette.green)
                            }.accessibilityAddTraits(filter == value ? .isSelected : [])
                                .accessibilityIdentifier("globalThemeFilter-\(String(describing: value))")
                        }
                    }.buttonStyle(ThemeButtonFeedbackStyle())
                }
                if visible.isEmpty { Text("当前分类没有主题").foregroundStyle(appAppearance.palette.green.opacity(0.78)).padding(.vertical, 32) }
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(visible) { bundle in themeCard(bundle) }
                }
                if let message = themes.message { Text(message).font(.footnote).foregroundStyle(appAppearance.palette.green) }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.appPageStyle()
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !managing {
                        Button { showImport = true } label: { Text("导入").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("globalThemeImport")
                        Menu {
                            NavigationLink { GlobalThemeEditorView() } label: { ThemeLabel("制作新主题", systemImage: "slider.horizontal.3") }.accessibilityIdentifier("globalThemeCreate")
                            NavigationLink { ThemeLibraryView(readingAssets: true) } label: { ThemeLabel("阅读搭配与独立样式", systemImage: "textformat") }.accessibilityIdentifier("globalThemeReadingAssets")
                            Button("导出给 AI 的制作资料") { showExport = true }
                            Button("批量管理主题") { managing = true; filter = .all; selection.removeAll() }
                        } label: { ThemeIcon(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("更多主题工具").accessibilityIdentifier("globalThemeTools")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if managing {
                    HStack(spacing: 16) {
                        Text("已选 \(selection.count) 套").font(.subheadline).accessibilityIdentifier("globalThemeSelectionCount")
                        Spacer(minLength: 0)
                        Button { share(chosen) } label: { Text("分享").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.disabled(selection.isEmpty).accessibilityIdentifier("globalThemeBulkShare")
                        Button(role: .destructive) { deletion = Set(chosen.filter { themes.canDelete($0) }.map(\.id)) } label: { Text("删除").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                            .disabled(!chosen.contains { themes.canDelete($0) }).accessibilityIdentifier("globalThemeBulkDelete")
                    }.frame(minHeight: 44).padding(16).background(appAppearance.palette.card)
                }
            }
            .onAppear { themes.attach(library) }
            .nativeFileImporter(isPresented: $showImport, allowedContentTypes: [.zhuyingTheme, .zip, .json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    if url.pathExtension.lowercased() == "json" {
                        let imported = try demo.importThemeData(ImportedFileReader.read(url, maximumBytes: 3 * 1024 * 1024))
                        let summary = "新增 \(imported.added) 套主题、\(imported.titlesAdded) 款标题、\(imported.bubblesAdded) 款气泡 · 重复 \(imported.duplicates) 项 · 无效 \(imported.invalid) 项"
                        if let onReadingImport { onReadingImport(summary) } else { message = summary }
                        return
                    }
                    pending = try GlobalThemePackage.decode(ImportedFileReader.read(url, maximumBytes: GlobalThemePackage.maximumBytes))
                } catch { if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription } }
            }
            .sheet(item: $pending) { bundle in
                NavigationStack { GlobalThemeDetailView(bundle: bundle, pendingImport: true).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { pending = nil } } } }
            }
            .sheet(isPresented: $showExport, onDismiss: { activeExport = preparedExport; preparedExport = nil }) {
                NavigationStack { GlobalThemeExportView { preparedExport = $0; showExport = false } }
            }
            .sheet(item: $activeExport) { file in
                NativeFileExporter(file: file) { result in
                    if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                    activeExport = nil
                }
            }
            .sheet(item: $shareFiles) { files in ThemeActivityShare(files: files.files) }
            .confirmationDialog(menuBundle?.manifest.name ?? "主题操作", isPresented: Binding(get: { menuBundle != nil }, set: { if !$0 { menuBundle = nil } }), titleVisibility: .visible) {
                if let bundle = menuBundle {
                    Button("分享这套主题") { share([bundle]); menuBundle = nil }
                    Button("另存为副本") { do { _ = try themes.duplicate(bundle); message = "已保存副本，当前搭配保留。" } catch { message = error.localizedDescription }; menuBundle = nil }
                    Button("选择多个主题") { managing = true; selection = [bundle.id]; filter = .all; menuBundle = nil }
                    Button(themes.canDelete(bundle) ? "删除这套主题" : "内置主题不可删除", role: .destructive) { deletion = [bundle.id]; menuBundle = nil }.disabled(!themes.canDelete(bundle))
                }
                Button("取消", role: .cancel) { menuBundle = nil }
            }
            .confirmationDialog("删除 \(deletion.count) 套主题？", isPresented: Binding(get: { !deletion.isEmpty }, set: { if !$0 { deletion.removeAll() } }), titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    let ids = deletion; deletion.removeAll()
                    run { try await themes.remove(ids); selection.subtract(ids); demo.refreshReaderBubbles() }
                }
                Button("取消", role: .cancel) { deletion.removeAll() }
            } message: { Text(themes.deletionSummary(deletion)) }
            .alert("主题提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
            .confirmationDialog("清除上次搭配的恢复点？", isPresented: $confirmClearRestore, titleVisibility: .visible) {
                Button("清除恢复点", role: .destructive) { run { try await themes.clearRestorePoint() } }
            } message: { Text("当前搭配保留；清除后不能恢复上次外观。") }
            .disabled(themes.busy)
    }
    private var currentCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12).fill(appAppearance.palette.soft).frame(width: 48, height: 56)
                .overlay(Text("竹影").font(.system(.caption, design: .serif)).foregroundStyle(appAppearance.palette.green)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(themes.isMixed ? "当前搭配 · 已混搭" : "当前搭配").font(.caption).foregroundStyle(appAppearance.palette.green.opacity(0.78))
                Text(themes.active.manifest.name).font(.headline).accessibilityIdentifier("globalThemeCurrent")
            }
            Spacer(minLength: 0)
            NavigationLink { GlobalThemeAdjustmentView() } label: { Text("调整").font(.subheadline).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("globalThemeAdjust")
            Menu {
                Button("分享当前搭配") { showExport = true }.accessibilityIdentifier("globalThemeExport")
                Button("保存为新主题") {
                    do { _ = try themes.importPackage(themes.exportCurrent(name: "我的竹影搭配")); message = "已保存为新主题，当前搭配保留。" } catch { message = error.localizedDescription }
                }
                Button("恢复上次搭配") { run { try await themes.restore(); demo.refreshReaderBubbles() } }
                    .disabled(library.globalThemeSelection?.previous == nil).accessibilityIdentifier("globalThemeRestore")
                Button("清除恢复点", role: .destructive) { confirmClearRestore = true }.disabled(library.globalThemeSelection?.previous == nil)
            } label: { ThemeIcon(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("当前搭配选项").accessibilityIdentifier("globalThemeCurrentMenu")
        }.padding(16).background(appAppearance.palette.card, in: .rect(cornerRadius: 18))
    }
    private func themeCard(_ bundle: GlobalThemeBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                if managing {
                    Button { toggle(bundle.id) } label: { GlobalThemeCover(bundle: bundle, compact: true) }.buttonStyle(ThemeButtonFeedbackStyle())
                        .accessibilityLabel("选择\(bundle.manifest.name)").accessibilityIdentifier("globalTheme-\(bundle.manifest.themeID)")
                } else {
                    NavigationLink { GlobalThemeDetailView(bundle: bundle) } label: { GlobalThemeCover(bundle: bundle, compact: true) }
                        .buttonStyle(ThemeButtonFeedbackStyle()).accessibilityLabel("预览\(bundle.manifest.name)")
                        .accessibilityIdentifier("globalTheme-\(bundle.manifest.themeID)")
                        .contextMenu {
                            Button("分享这套主题") { share([bundle]) }
                            Button("另存为副本") { do { _ = try themes.duplicate(bundle); message = "已保存副本，当前搭配保留。" } catch { message = error.localizedDescription } }
                            Button("选择多个主题") { managing = true; selection = [bundle.id]; filter = .all }
                            Button(themes.canDelete(bundle) ? "删除这套主题" : "内置主题不可删除", role: .destructive) { deletion = [bundle.id] }.disabled(!themes.canDelete(bundle))
                        }
                        .accessibilityAction(named: "主题操作") { menuBundle = bundle }
                }
                Button {
                    if managing { toggle(bundle.id) } else { menuBundle = bundle }
                } label: {
                    ThemeIcon(systemName: managing ? (selection.contains(bundle.id) ? "checkmark.circle.fill" : "circle") : "ellipsis")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(ThemeAppearanceContext(bundle: bundle).palette.green)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(ThemeButtonFeedbackStyle())
                    // Keep the touch area, but leave only the dots visible over the cover.
                    .background(Color.clear)
                    .accessibilityLabel(managing ? "勾选\(bundle.manifest.name)" : "\(bundle.manifest.name)的操作")
                    .accessibilityValue(managing ? (selection.contains(bundle.id) ? "已选中" : "未选中") : "")
                    .accessibilityIdentifier("globalThemeMore-\(bundle.manifest.themeID)")
                if themes.isInUse(bundle) {
                    Text("使用中").font(.caption2).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(appAppearance.palette.primary, in: Capsule()).foregroundStyle(appAppearance.palette.onPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10).allowsHitTesting(false)
                }
            }.overlay(RoundedRectangle(cornerRadius: 16).stroke(selection.contains(bundle.id) ? appAppearance.palette.primary : Color.clear, lineWidth: 2))
            Text(bundle.manifest.name).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text("\(themes.canDelete(bundle) ? bundle.manifest.author : "竹影") · \(themes.canDelete(bundle) ? "已导入" : "内置")")
                .font(.caption).foregroundStyle(appAppearance.palette.green.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
    private func share(_ bundles: [GlobalThemeBundle]) {
        var files: [ExportFile] = []
        do {
            for bundle in bundles {
                let name = bundle.manifest.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
                files.append(try ExportFile.prepare(themes.exportPackage(bundle), filename: "竹影-\(name).zhuyingtheme"))
            }
            shareFiles = .init(files: files)
        } catch {
            for file in files { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            message = error.localizedDescription
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { message = error.localizedDescription } }
    }
}

private struct GlobalThemeAdjustmentView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List {
            Section {
                NavigationLink { GlobalThemeEditorView() } label: { ThemeLabel("界面配色、背景与图标", systemImage: "paintpalette") }
                NavigationLink { ReadingAppearanceView() } label: { ThemeLabel("阅读配色与字体", systemImage: "textformat") }
                NavigationLink { ReadingTypographyPreferencesView() } label: { ThemeLabel("正文排版与边距", systemImage: "text.alignleft") }
                NavigationLink { ReadingPageElementsView() } label: { ThemeLabel("页眉与页脚", systemImage: "rectangle.split.3x1") }
                NavigationLink { ReadingTitlePreferencesView() } label: { ThemeLabel("章节标题与 CSS", systemImage: "textformat.size") }
                NavigationLink { ReadingContentPreferencesView() } label: { ThemeLabel("气泡与段评", systemImage: "bubble.left.and.bubble.right") }
            } footer: { Text("阅读调整自动保存到当前搭配，原主题文件保留。取用其他主题的部分样式，可直接在主题预览中选择。") }
        }.appPageStyle().navigationTitle("调整搭配").navigationBarTitleDisplayMode(.inline)
    }
}

private struct GlobalThemeCover: View {
    let bundle: GlobalThemeBundle
    var compact = false
    private var palette: AppThemePalette { .init(appearance: bundle.document.app) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            Text("我的书架").font(.system(.headline, design: .serif)).padding(.top, compact ? 18 : 22)
            HStack(spacing: 8) {
                ForEach(["长风渡山海", "群星之外"], id: \.self) { name in
                    RoundedRectangle(cornerRadius: 5).fill(palette.soft)
                        .overlay(Text(name).font(.system(.caption2, design: .serif)).padding(6).foregroundStyle(palette.green))
                        .frame(height: compact ? 50 : 65)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("山雨欲来").font(.system(.caption, design: .serif).weight(.medium))
                Text("风从远山吹来，翻动窗边的书页。").font(.caption2).lineLimit(compact ? 1 : 2)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(palette.card, in: .rect(cornerRadius: 9))
            Spacer(minLength: compact ? 8 : 12)
        }.padding(compact ? 12 : 14).frame(maxWidth: .infinity, minHeight: compact ? 200 : 230, alignment: .topLeading)
            .foregroundStyle(palette.green).background(ThemeSurface()).clipShape(.rect(cornerRadius: 16)).contentShape(RoundedRectangle(cornerRadius: 16))
            .environment(\.themeAppearance, .init(bundle: bundle)).accessibilityHidden(true)
    }
}

private struct ThemeActivityShare: UIViewControllerRepresentable {
    let files: [ExportFile]
    func makeCoordinator() -> Coordinator { Coordinator(files: files) }
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: files.map(\.url), applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) { coordinator.clean() }
    final class Coordinator {
        let files: [ExportFile]
        init(files: [ExportFile]) { self.files = files }
        func clean() { for file in files { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) } }
    }
}

struct GlobalThemeDetailView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @ObservedObject private var themes = GlobalThemeStore.shared
    let bundle: GlobalThemeBundle
    var pendingImport = false
    @State private var scopes = Set(ThemeApplicationScope.allCases)
    @State private var showMulti = false
    @State private var previewPage = "书架"
    @State private var message: String?
    @State private var imported = false
    private var available: [ThemeApplicationScope] { ThemeApplicationScope.allCases.filter { $0.isAvailable(in: bundle) } }
    private var allSelected: Bool { scopes.isSuperset(of: Set(available)) }
    private var options: ThemeApplicationOptions { .scopes(scopes.intersection(available)) }
    private var label: String { allSelected ? "应用整套主题" : scopes.count == 1 ? "仅应用\(scopes.first!.rawValue)" : "应用所选 \(scopes.count) 项" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GlobalThemePreview(bundle: bundle, settings: library.settings, options: options, page: $previewPage)
                Text("\(bundle.manifest.author) · \(bundle.manifest.themeVersion)").font(.footnote).foregroundStyle(appAppearance.palette.green.opacity(0.78))
                HStack { Text("应用内容").font(.headline); Spacer(); Text("点一项直接取用").font(.caption).foregroundStyle(appAppearance.palette.green.opacity(0.78)) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                    scopeButton("整套", selected: allSelected, id: "all") { scopes = Set(available) }
                    ForEach(available.filter { $0 != .comments }) { scope in
                        scopeButton(scope.rawValue, selected: scopes == [scope], id: String(describing: scope)) {
                            scopes = [scope]; if ![.colors, .background, .icons].contains(scope) { previewPage = "阅读" }
                        }
                    }
                    scopeButton("多选…", selected: !allSelected && scopes.count > 1, id: "multi") { showMulti = true }
                }
                Text(allSelected ? "应用整套外观；阅读进度、翻页手势与震动保留。" : "仅应用\(ThemeApplicationScope.allCases.filter { scopes.contains($0) }.map(\.rawValue).joined(separator: "、"))，其余保留当前搭配。")
                    .font(.footnote).foregroundStyle(appAppearance.palette.green.opacity(0.78)).accessibilityIdentifier("globalThemeScopeSummary")
                if pendingImport && !imported {
                    Button("仅加入主题库") {
                        do { _ = try themes.importPackage(GlobalThemePackage.encode(bundle)); imported = true; message = "已加入主题库，当前外观保留。" }
                        catch { message = error.localizedDescription }
                    }.frame(minHeight: 44).accessibilityIdentifier("globalThemeSaveOnly")
                }
                if let message { Text(message).font(.subheadline).accessibilityIdentifier("globalThemeResult") }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.onAppear { scopes.formIntersection(available) }.appPageStyle().navigationTitle(bundle.manifest.name).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(label) { apply() }.buttonStyle(PrimaryButtonStyle()).disabled(themes.busy || scopes.isEmpty)
                    .accessibilityIdentifier("globalThemeApply").padding(16).background(appAppearance.palette.background)
            }
            .sheet(isPresented: $showMulti) {
                NavigationStack {
                    Form {
                        Section {
                            Button("全选") { scopes = Set(available) }
                            Button("清空") { scopes.removeAll() }
                            ForEach(available) { scope in
                                Toggle(scope.rawValue, isOn: Binding(get: { scopes.contains(scope) }, set: { if $0 { scopes.insert(scope) } else { scopes.remove(scope) } }))
                                    .accessibilityIdentifier("globalThemeMulti-\(String(describing: scope))")
                            }
                        }
                        Section {
                            Button("查看组合效果") { previewPage = "阅读"; showMulti = false }.disabled(scopes.isEmpty)
                            Button("应用所选 \(scopes.count) 项") { showMulti = false; apply() }.disabled(scopes.isEmpty || themes.busy)
                        }
                    }.navigationTitle("选择要取用的内容").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showMulti = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
    private func scopeButton(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? appAppearance.palette.primary : appAppearance.palette.soft, in: .rect(cornerRadius: 10))
                .foregroundStyle(selected ? appAppearance.palette.onPrimary : appAppearance.palette.green)
        }.buttonStyle(ThemeButtonFeedbackStyle()).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("globalThemeScope-\(id)")
    }
    private func apply() {
        Task {
            do {
                if pendingImport && !imported { _ = try themes.importPackage(GlobalThemePackage.encode(bundle)); imported = true }
                try await themes.apply(bundle, options: options)
                demo.refreshReaderBubbles(); message = "已应用并保存，可在当前搭配菜单中恢复。"
            } catch { message = error.localizedDescription }
        }
    }
}

struct GlobalThemePreview: View {
    let bundle: GlobalThemeBundle
    let settings: ReadingSettings
    var options = ThemeApplicationOptions()
    @Binding var page: String
    @State private var renderedPreview: ReadingSettings?
    @State private var renderingMessage: String?
    private var appearance: GlobalThemeBundle { GlobalThemeStore.shared.previewAppearance(bundle, options: options) }
    private var base: ReadingSettings { (try? GlobalThemeStore.settings(for: bundle, current: settings, options: options)) ?? settings }
    static func fingerprint(_ settings: ReadingSettings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return FileResourceStore.digest((try? encoder.encode(settings)) ?? Data())
    }
    private var previewKey: String { Self.fingerprint(base) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("预览页面", selection: $page) { ForEach(["书架", "阅读", "我的"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            Group {
                if page == "阅读" {
                    ReadingSettingsPreview(settings: renderedPreview ?? base, themeBackground: options.includes(.readerBackground) && bundle.document.reader != nil ? bundle : GlobalThemeStore.shared.readerBundle)
                } else if page == "书架" { GlobalThemeCover(bundle: appearance) }
                else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("我的阅读时光").font(.title2)
                        ThemeLabel("主题管理", systemImage: "paintpalette")
                        ThemeLabel("阅读偏好", systemImage: "textformat.size")
                        Text("在字里行间，遇见山海").font(.footnote)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(ThemeSurface())
                }
            }.allowsHitTesting(false)
            if let renderingMessage { Text(renderingMessage).font(.footnote) }
        }.environment(\.themeAppearance, .init(bundle: appearance)).accessibilityElement(children: .contain).accessibilityIdentifier("globalThemePreview")
            .task(id: previewKey) {
                renderedPreview = nil; renderingMessage = nil
                let colors = base.preferences.colors
                let theme = DemoTheme(id: bundle.manifest.themeID, name: bundle.manifest.name, mode: colors?.dark == true ? .dark : .light,
                                      background: colors?.background ?? 0xF7F6F0, ink: colors?.ink ?? 0x354F40, accent: colors?.accent ?? 0xB7815A,
                                      summary: "原生阅读预览", source: "主题包", version: bundle.manifest.themeVersion)
                do {
                    let value = try await ThemeReaderBridge.renderedPreview(base, theme: theme)
                    try Task.checkCancellation(); renderedPreview = value
                } catch { if !Task.isCancelled { renderingMessage = "气泡预览暂不可用：\(error.localizedDescription)" } }
            }
    }
}

struct GlobalThemeExportView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var name = "我的竹影主题"
    @State private var license = ""
    var onPrepared: (ExportFile) -> Void
    @State private var message: String?
    var body: some View {
        Form {
            Section("分享主题名称") { TextField("主题名称", text: $name).accessibilityIdentifier("globalThemeExportName") }
            Section("包含的内容") { Text("当前界面配色、图标和背景，以及实际生效的阅读排版、页眉页脚、章节标题、气泡和段评样式。") }
            Section("导出前确认") {
                Text("分享的是外观，不含书籍、进度、账号、书源和真实评论。当前书籍／书源专属规则不会导出。")
                ForEach(library.settings.preferences.pageElements.filter { $0.kind == "自定义文字" && !$0.text.isEmpty }) { element in
                    Text("将附带自定义文字：\(element.text)").foregroundStyle(appAppearance.palette.accent)
                }
            }
            if let font = library.settings.preferences.fontName, font != "__serif__" {
                Section("自定义字体的分发许可") {
                    Text("主题包已附字体许可时会自动沿用；其他字体请填写分发许可原文，或切回系统字体再导出。")
                    TextEditor(text: $license).frame(minHeight: 120).accessibilityIdentifier("globalThemeFontLicense")
                }
            }
            Button("生成主题包并分享") { generate(kit: false) }.accessibilityIdentifier("globalThemeGenerate")
            Button("导出给 AI 的制作资料") { generate(kit: true) }.accessibilityIdentifier("globalThemeAuthoringKit")
            if let message { Text(message).accessibilityIdentifier("globalThemeExportResult") }
        }.appPageStyle().navigationTitle("打包分享").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }
    private func generate(kit: Bool) {
        message = "正在生成主题资料…"
        do {
            let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeName.isEmpty, safeName.count <= 80, !safeName.contains("/"), !safeName.contains("\\") else { throw GlobalThemeError.invalid("请填写不含路径字符的主题名称。") }
            let data = try GlobalThemeStore.shared.exportCurrent(name: safeName, fontLicense: license)
            let file = try ExportFile.prepare(kit ? GlobalThemePackage.authoringKit(theme: data) : data, filename: kit ? "竹影-AI主题制作资料.zip" : "竹影-\(safeName).zhuyingtheme")
            message = "文件已生成，请选择保存位置。"
            onPrepared(file)
        } catch { message = error.localizedDescription }
    }
}

struct GlobalThemeEditorView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GlobalThemeStore.shared.active
    @State private var previewPage = "书架"
    @State private var name = "我的竹影配色"
    @State private var showImage = false
    @State private var imageKind = "background"
    @State private var backgroundRole = "page"
    @State private var iconRole = "navigation.shelf"
    @State private var iconState = "normal"
    @State private var message: String?
    @State private var readerBackground = GlobalThemeStore.shared.readerBundle?.document.reader?.background
    @State private var changedReaderBackground = false
    @State private var fontLicense = ""
    private var selectedBackground: ThemeBackgroundResource? { backgroundRole == "reader" ? readerBackground : draft.document.app.backgrounds[backgroundRole] }
    private func setBackground(_ value: ThemeBackgroundResource?) {
        if backgroundRole == "reader" { readerBackground = value; changedReaderBackground = true }
        else { draft.document.app.backgrounds[backgroundRole] = value }
    }
    private let colorRoles = [("background.page", "页面背景"), ("background.card", "卡片背景"), ("background.soft", "浅层背景"), ("text.primary", "主要文字"), ("text.secondary", "辅助文字"), ("accent", "强调色"), ("border", "分隔线"), ("action.primary.background", "主按钮"), ("action.primary.foreground", "按钮文字")]
    var body: some View {
        Form {
            Section("主题名称") { TextField("名称", text: $name); Toggle("深色界面", isOn: $draft.document.app.dark) }
            Section("预览") { GlobalThemePreview(bundle: draft, settings: library.settings, page: $previewPage) }
            Section("界面配色") {
                ForEach(colorRoles, id: \.0) { role, title in
                    ColorPicker(title, selection: Binding(get: { Color(hex: draft.document.app.colors[role].flatMap(GlobalThemePackage.hex) ?? 0) }, set: { color in
                        let value = UIColor(color); var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                        value.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                        draft.document.app.colors[role] = String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
                    }), supportsOpacity: false)
                }
            }
            Section("背景图片") {
                Picker("应用位置", selection: $backgroundRole) {
                    Text("全局页面").tag("page"); Text("书架").tag("shelf"); Text("我的").tag("profile"); Text("设置").tag("settings"); Text("卡片").tag("card"); Text("阅读正文").tag("reader"); Text("默认封面").tag("cover.default")
                }
                Button("选择背景图片") { imageKind = "background"; showImage = true }
                if selectedBackground != nil {
                    Picker("铺放方式", selection: Binding(get: { selectedBackground?.mode ?? "fill" }, set: { mode in var value = selectedBackground; value?.mode = mode; setBackground(value) })) { Text("填充").tag("fill"); Text("适应").tag("fit"); Text("平铺").tag("tile") }
                    HStack { Text("图片透明度"); Slider(value: Binding(get: { selectedBackground?.opacity ?? 1 }, set: { opacity in var value = selectedBackground; value?.opacity = opacity; setBackground(value) }), in: 0...1) }
                    HStack { Text("底色遮罩"); Slider(value: Binding(get: { selectedBackground?.overlayOpacity ?? 0 }, set: { opacity in var value = selectedBackground; value?.overlayOpacity = opacity; setBackground(value) }), in: 0...1) }
                    Button("移除此位置的背景", role: .destructive) { setBackground(nil) }
                }
                if changedReaderBackground, let font = library.settings.preferences.fontName, font != "__serif__" {
                    Text("阅读背景将随当前阅读套装保存；如使用自定义字体，请提供分发许可原文。")
                    TextEditor(text: $fontLicense).frame(minHeight: 90)
                }
            }
            Section("应用内图标") {
                Picker("图标位置", selection: $iconRole) {
                    ForEach(ThemeRoleCatalog.icons, id: \.key) { role in Text(role.title).tag(role.key) }
                }
                Picker("状态", selection: $iconState) { Text("普通").tag("normal"); Text("选中").tag("selected"); Text("禁用").tag("disabled"); Text("按下").tag("pressed"); Text("聚焦").tag("focused"); Text("加载").tag("loading") }
                Button("选择替换图片") { imageKind = "icon"; showImage = true }
                Button("恢复此图标", role: .destructive) { draft.document.app.icons.removeValue(forKey: iconRole) }
                Text("PNG／JPEG。图片尺寸不会改变按钮的位置、点击范围或功能。其余图标可在主题包中按 symbol.系统符号名替换。")
                    .font(.system(size: 11))
            }
            Section("点击反馈") {
                HStack { Text("按下透明度"); Slider(value: $draft.document.app.motion.pressOpacity, in: 0.2...1) }
                HStack { Text("过渡时长"); Slider(value: $draft.document.app.motion.duration, in: 0...0.4) }
            }
            Button("保存并应用界面主题") { save() }.accessibilityIdentifier("globalThemeEditorSave")
            if let message { Text(message).accessibilityIdentifier("globalThemeEditorResult") }
        }.appPageStyle().navigationTitle("制作主题")
            .nativeFileImporter(isPresented: $showImage, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let bytes = try ImportedFileReader.read(url, maximumBytes: 4 * 1024 * 1024)
                    let ext = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "jpg" : "png"
                    let path = "assets/\(imageKind == "icon" ? "icons" : "backgrounds")/\(UUID().uuidString).\(ext)"
                    draft.resources[path] = bytes
                    try GlobalThemePackage.validateImage(path, in: draft)
                    if imageKind == "background" { setBackground(.init(path: path, opacity: 0.25)) }
                    else {
                        var asset = draft.document.app.icons[iconRole] ?? .init(path: path, template: false)
                        asset.symbol = nil
                        if iconState == "selected" { asset.selected = path }
                        else if iconState == "disabled" { asset.disabled = path }
                        else if iconState == "pressed" { asset.pressed = path }
                        else if iconState == "focused" { asset.focused = path }
                        else if iconState == "loading" { asset.loading = path }
                        else { asset.path = path }
                        draft.document.app.icons[iconRole] = asset
                    }
                } catch { if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription } }
            }
    }
    private func save() {
        Task {
            do {
                var value = draft
                if changedReaderBackground {
                    value = try GlobalThemePackage.decode(GlobalThemeStore.shared.exportCurrent(name: name, fontLicense: fontLicense))
                    value.document.app = draft.document.app
                    value.resources.merge(draft.resources) { _, new in new }
                    if var background = readerBackground {
                        guard let data = draft.resources[background.path] ?? GlobalThemeStore.shared.readerBundle?.resources[background.path] else { throw GlobalThemeError.invalid("阅读背景资源缺失。") }
                        background.path = "assets/reader/custom-background." + (background.path as NSString).pathExtension
                        value.resources[background.path] = data; value.document.reader?.background = background
                    } else { value.document.reader?.background = nil }
                    value.manifest.name = name; value.manifest.appearanceModes = [value.document.app.dark ? "dark" : "light"]
                } else {
                    value.manifest = .init(themeID: "zhuying.user." + UUID().uuidString.lowercased(), name: name, appearanceModes: [value.document.app.dark ? "dark" : "light"])
                    value.document.reader = nil; value.document.fontBindings = [:]
                }
                value.resources = value.resources.filter { path, _ in
                    path.hasPrefix("licenses/") || value.document.app.backgrounds.values.contains { $0.path == path } || value.document.app.icons.values.contains { [$0.path, $0.selected, $0.disabled, $0.pressed, $0.focused, $0.loading].contains(path) } || value.document.reader?.resources.values.contains { $0.path == path } == true || value.document.reader?.background?.path == path || value.document.fontBindings.values.contains { $0.path == path || $0.licensePath == path }
                }
                let bundle = try GlobalThemeStore.shared.importPackage(GlobalThemePackage.encode(value))
                var options = ThemeApplicationOptions.interfaceOnly
                if changedReaderBackground { options.selectedParts = [.appColors, .appBackgrounds, .appIcons, .readerBackground] }
                try await GlobalThemeStore.shared.apply(bundle, options: options)
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

enum ThemeRoleCatalog {
    static let icons: [(key: String, title: String)] = [
        ("navigation.shelf", "导航·书架"), ("navigation.footprints", "导航·足迹"), ("navigation.profile", "导航·我的"), ("navigation.search", "导航·搜索"),
        ("navigation.discover", "导航·发现"), ("navigation.sources", "导航·书源"), ("navigation.tools", "导航·工具"),
        ("symbol.magnifyingglass", "搜索"), ("symbol.gearshape", "设置"), ("symbol.plus", "添加"), ("symbol.list.bullet", "章节目录"),
        ("symbol.ellipsis", "更多操作"), ("symbol.headphones", "听书"), ("symbol.paintpalette", "主题"), ("symbol.square.and.arrow.down", "导入"), ("symbol.chevron.right", "进入"),
        ("symbol.play.fill", "播放"), ("symbol.pause.fill", "暂停"), ("symbol.xmark", "关闭"), ("state.loading", "加载指示器"), ("navigation.back", "导航·返回")
    ]
}
