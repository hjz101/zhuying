import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let zhuyingTheme = UTType(exportedAs: "com.zhuying.theme", conformingTo: .zip)
}

struct GlobalThemeManagerView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @ObservedObject private var themes = GlobalThemeStore.shared
    @State private var showImport = false
    @State private var pending: GlobalThemeBundle?
    @State private var message: String?
    @State private var showExport = false
    @State private var preparedExport: ExportFile?
    @State private var activeExport: ExportFile?
    @State private var confirmClearRestore = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppPageHeader(title: "全局主题", subtitle: "配色、图标和背景 · 沿用原有页面与操作", icon: "paintpalette")
                AppSettingsCard("当前外观", icon: "checkmark.circle") {
                    Text(themes.active.manifest.name).accessibilityIdentifier("globalThemeCurrent")
                    HStack {
                        Button("恢复上次外观") { run { try await themes.restore(); demo.refreshReaderBubbles() } }
                            .disabled(library.globalThemeSelection?.previous == nil || themes.busy).accessibilityIdentifier("globalThemeRestore")
                        Spacer()
                        Button("打包分享") { showExport = true }.accessibilityIdentifier("globalThemeExport")
                    }.font(.system(size: 13))
                    if library.globalThemeSelection?.previous != nil {
                        Button("清除恢复点", role: .destructive) { confirmClearRestore = true }.font(.system(size: 11))
                    }
                }
                HStack {
                    Button { showImport = true } label: { ThemeLabel("导入主题包", systemImage: "square.and.arrow.down") }.accessibilityIdentifier("globalThemeImport")
                    Spacer()
                    NavigationLink { GlobalThemeEditorView() } label: { ThemeLabel("制作主题", systemImage: "slider.horizontal.3") }.accessibilityIdentifier("globalThemeCreate")
                }.font(.system(size: 13))
                ForEach(themes.bundles) { bundle in
                    NavigationLink { GlobalThemeDetailView(bundle: bundle) } label: {
                        HStack(spacing: 14) {
                            HStack(spacing: 0) {
                                ForEach(["background.page", "accent", "background.soft"], id: \.self) { role in
                                    Color(hex: bundle.document.app.colors[role].flatMap(GlobalThemePackage.hex) ?? 0).frame(width: 17, height: 45)
                                }
                            }.clipShape(.rect(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(bundle.manifest.name).font(.system(size: 15, weight: .medium))
                                Text(bundle.document.reader == nil ? "界面主题 · 阅读配置保留" : "完整套装 · 含阅读排版与样式").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                            }
                            Spacer()
                            ThemeIcon(systemName: bundle.id == themes.active.id ? "checkmark.circle.fill" : "chevron.right")
                        }.padding(15).background(appAppearance.palette.card, in: .rect(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityIdentifier("globalTheme-\(bundle.manifest.themeID)")
                }
                if let message = themes.message { Text(message).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent) }
            }.padding(22)
        }.appPageStyle().navigationTitle("全局主题").navigationBarTitleDisplayMode(.inline)
            .onAppear { themes.attach(library) }
            .nativeFileImporter(isPresented: $showImport, allowedContentTypes: [.zhuyingTheme, .zip], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let data = try ImportedFileReader.read(url, maximumBytes: GlobalThemePackage.maximumBytes)
                    let decoded = try GlobalThemePackage.decode(data)
                    pending = decoded
                } catch { if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription } }
            }
            .sheet(item: $pending) { bundle in
                NavigationStack { GlobalThemeDetailView(bundle: bundle, pendingImport: true).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { pending = nil } } } }
            }
            .sheet(isPresented: $showExport, onDismiss: {
                activeExport = preparedExport; preparedExport = nil
            }) { NavigationStack { GlobalThemeExportView { preparedExport = $0; showExport = false } } }
            .sheet(item: $activeExport) { file in
                NativeFileExporter(file: file) { result in
                    if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                    activeExport = nil
                }
            }
            .alert("主题提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
            .confirmationDialog("清除上次外观的恢复点？", isPresented: $confirmClearRestore, titleVisibility: .visible) {
                Button("清除恢复点", role: .destructive) { run { try await themes.clearRestorePoint() } }
            } message: { Text("清除后不能一键恢复上次个人外观；当前主题不变。") }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { message = error.localizedDescription } }
    }
}

struct GlobalThemeDetailView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @ObservedObject private var themes = GlobalThemeStore.shared
    let bundle: GlobalThemeBundle
    var pendingImport = false
    @State private var options = ThemeApplicationOptions()
    @State private var message: String?
    @State private var confirmFull = false
    @State private var imported = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppPageHeader(title: bundle.manifest.name, subtitle: "\(bundle.manifest.author) · \(bundle.manifest.themeVersion)", icon: "paintpalette")
                GlobalThemePreview(bundle: bundle, settings: library.settings)
                if bundle.document.reader != nil {
                    AppSettingsCard("应用范围", icon: "checklist") {
                        Toggle("界面配色、图标和背景", isOn: $options.app)
                        Toggle("阅读配色", isOn: $options.readerColors)
                        Toggle("阅读字体、排版和页眉页脚", isOn: $options.readerLayout)
                        Toggle("章节标题、气泡与段评样式", isOn: $options.readerDecorations)
                        Toggle("翻页模式、点击翻页与震动", isOn: $options.readingBehavior)
                        Text("完整应用会覆盖旧的个人阅读外观，并保存恢复点；阅读行为仅在勾选后应用。字体将在应用时校验并注册。")
                            .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                    }
                }
                Button(bundle.document.reader == nil ? "应用界面主题" : "完整应用主题") { confirmFull = true }
                    .buttonStyle(PrimaryButtonStyle()).disabled(themes.busy).accessibilityIdentifier("globalThemeApply")
                if bundle.document.reader != nil {
                    Button("按上方选择混搭") { apply(full: false) }.buttonStyle(PrimaryButtonStyle(filled: false))
                        .disabled(themes.busy || (!options.app && !options.readerColors && !options.readerLayout && !options.readerDecorations && !options.readingBehavior)).accessibilityIdentifier("globalThemeMix")
                }
                if pendingImport && !imported {
                    Button("仅加入主题库") {
                        do { _ = try themes.importPackage(GlobalThemePackage.encode(bundle)); imported = true; message = "已加入主题库，当前外观保留。" }
                        catch { message = error.localizedDescription }
                    }.accessibilityIdentifier("globalThemeSaveOnly")
                }
                if !bundle.manifest.themeID.hasPrefix("zhuying.builtin.") && !pendingImport {
                    Button("删除主题", role: .destructive) { do { try themes.remove(bundle); message = "主题已删除。" } catch { message = error.localizedDescription } }
                }
                if let message { Text(message).font(.system(size: 13)).accessibilityIdentifier("globalThemeResult") }
            }.padding(22)
        }.appPageStyle().navigationTitle("主题预览").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("应用这套主题？", isPresented: $confirmFull, titleVisibility: .visible) {
                Button("确认应用") { apply(full: true) }
            } message: { Text(bundle.document.reader == nil ? "仅更换应用界面，阅读配置保留。" : "将替换阅读配色、排版、标题和气泡等个人外观。可在主题管理中恢复上次外观。") }
    }
    private func apply(full: Bool) {
        Task {
            do {
                if pendingImport && !imported { _ = try themes.importPackage(GlobalThemePackage.encode(bundle)); imported = true }
                var selected = full ? ThemeApplicationOptions() : options
                selected.readingBehavior = options.readingBehavior
                try await themes.apply(bundle, options: selected)
                demo.refreshReaderBubbles()
                message = "已应用并保存，可在全局主题中恢复。"
            } catch { message = error.localizedDescription }
        }
    }
}

struct GlobalThemePreview: View {
    let bundle: GlobalThemeBundle
    let settings: ReadingSettings
    @State private var renderedPreview: ReadingSettings?
    @State private var renderingMessage: String?
    private var base: ReadingSettings { (try? GlobalThemeStore.settings(for: bundle, current: settings, options: .init())) ?? settings }
    static func fingerprint(_ settings: ReadingSettings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return FileResourceStore.digest((try? encoder.encode(settings)) ?? Data())
    }
    private var previewKey: String { Self.fingerprint(base) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            AppPageHeader(title: "我的书架", subtitle: "书架、设置与正文效果预览", icon: "books.vertical")
            AppSettingsCard("为阅读，准备的一切", icon: "slider.horizontal.3") {
                HStack { ThemeLabel("书架", systemImage: "books.vertical", role: "navigation.shelf", selected: true); Spacer(); ThemeLabel("我的", systemImage: "person.crop.circle", role: "navigation.profile") }
                Text("章节标题、气泡与正文配色来自当前搭配。").font(.system(size: 12))
                Button("继续阅读") {}.buttonStyle(PrimaryButtonStyle())
            }
            ReadingSettingsPreview(settings: renderedPreview ?? base)
            if let renderingMessage { Text(renderingMessage).font(.system(size: 11)) }
        }.padding(16).background(ThemeSurface()).clipShape(.rect(cornerRadius: 18))
            .environment(\.themeAppearance, .init(bundle: bundle)).allowsHitTesting(false).accessibilityIdentifier("globalThemePreview")
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
                    Text("请输入字体附带的分发许可原文。没有分发权限时，请先切回系统字体再导出。")
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
            Section("预览") { GlobalThemePreview(bundle: draft, settings: library.settings) }
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
                var options = ThemeApplicationOptions.interfaceOnly; options.readerDecorations = changedReaderBackground
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
        ("symbol.headphones", "听书"), ("symbol.paintpalette", "主题"), ("symbol.square.and.arrow.down", "导入"), ("symbol.chevron.right", "进入"),
        ("symbol.play.fill", "播放"), ("symbol.pause.fill", "暂停"), ("symbol.xmark", "关闭"), ("state.loading", "加载指示器"), ("navigation.back", "导航·返回")
    ]
}
