import SwiftUI
import UIKit

struct ReadingSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR READING SPACE").font(.system(size: 9)).tracking(2).foregroundStyle(Palette.muted)
                        Text("你的阅读，自成风格。").font(.system(size: 27, design: .serif))
                        Text("\(store.settings.preferences.colors?.name ?? store.settings.theme.title) · \(Int(store.settings.fontSize)) pt · \(store.settings.mode.title)")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).accessibilityIdentifier("readingPreferenceSummary")
                    }.padding(.vertical, 9)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                        NavigationLink { ReadingAppearanceView() } label: { category("主题与字体", "我的主题 · 本地字体", "paintpalette") }.accessibilityIdentifier("reading-category-appearance")
                        NavigationLink { ReadingLayoutPreferencesView() } label: { category("排版与页面", "文字与边距 · 标题 · 页眉页脚", "rectangle.split.3x1") }.accessibilityIdentifier("reading-category-layout")
                        NavigationLink { ReadingOperationPreferencesView() } label: { category("翻页与手势", "阅读方式 · 翻页效果 · 单手操作", "hand.draw") }.accessibilityIdentifier("reading-category-operation")
                        NavigationLink { ReadingContentPreferencesView() } label: { category("正文与段评", "样式规则 · 段尾气泡 · 神人评论", "bubble.left.and.bubble.right") }.accessibilityIdentifier("reading-category-content")
                    }.buttonStyle(.plain)
                    Text("当前阅读效果").font(.system(size: 13, weight: .medium))
                    ReadingSettingsPreview(settings: store.settings)
                    HStack {
                        Label("自动保存在当前设备", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("恢复默认") { confirmReset = true }.font(.system(size: 11)).accessibilityIdentifier("resetReadingSettings")
                    }
                }.padding(22)
            }.appPageStyle().navigationTitle("阅读偏好").navigationBarTitleDisplayMode(.inline)
                .readingPreferenceDoneToolbar()
                .alert("恢复默认阅读偏好？", isPresented: $confirmReset) {
                    Button("恢复默认", role: .destructive) { store.settings = .init() }
                    Button("取消", role: .cancel) {}
                } message: { Text("字号、排版和个人样式恢复默认，阅读位置与已导入的字体保留。") }
        }.environment(\.readingPreferenceDismiss, { dismiss() })
            .appPageStyle().presentationBackground(Palette.background).presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(26)
    }
    private func category(_ title: String, _ detail: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 21, weight: .light))
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 114, alignment: .leading).padding(15)
            .background(Palette.card, in: .rect(cornerRadius: 15)).contentShape(Rectangle())
    }
}

struct ReadingLayoutPreferencesView: View {
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ReadingPreferencePage("排版与页面") {
            ReadingSettingsPreview(settings: store.settings)
            AppSettingsCard("排版与页面", icon: "text.alignleft") {
                NavigationLink { ReadingTypographyPreferencesView() } label: { ReadingPreferenceRow(title: "正文排版与边距", detail: "字号 · 行距 · 段距 · 四边留白") }.accessibilityIdentifier("reading-body")
                Divider()
                NavigationLink { ReadingTitlePreferencesView() } label: { ReadingPreferenceRow(title: "章节标题", detail: store.settings.preferences.titleCSS == nil ? "跟随主题 / 自定义" : "个人自定义") }.accessibilityIdentifier("reading-title")
                Divider()
                NavigationLink { ReadingPageElementsView() } label: { ReadingPreferenceRow(title: "页眉与页脚", detail: "添加元素 · 自由拖动与精调") }.accessibilityIdentifier("reading-page-elements")
            }
        }
    }
}

struct ReadingTypographyPreferencesView: View {
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ReadingPreferencePage("正文排版与边距") {
            ReadingSettingsPreview(settings: store.settings)
            AppSettingsCard("文字与段落", icon: "textformat.size") {
                ReadingValueSlider("文字大小", value: $store.settings.fontSize, range: 14...30, id: "fontPicker")
                ReadingValueSlider("行间距", value: $store.settings.lineSpacing, range: 0...24, id: "lineSpacingPicker")
                ReadingValueSlider("段落间距", value: $store.settings.preferences.paragraphSpacing, range: 0...40, id: "paragraphSpacingSlider")
                Picker("字重", selection: $store.settings.preferences.fontWeight) { ForEach(["细体", "常规", "中等", "粗体"], id: \.self) { Text($0) } }
                Toggle("首行缩进", isOn: $store.settings.preferences.firstLineIndent).accessibilityIdentifier("readingIndentToggle")
            }
            AppSettingsCard("页面留白", icon: "arrow.up.left.and.arrow.down.right") {
                Toggle("左右边距联动", isOn: $store.settings.preferences.marginsLinked).accessibilityIdentifier("readingMarginsLinked")
                    .onChange(of: store.settings.preferences.marginsLinked) { _, linked in if linked { store.settings.preferences.rightMargin = store.settings.preferences.leftMargin } }
                ReadingValueSlider("左边距", value: margin(\.leftMargin, other: \.rightMargin), range: 8...56, id: "leftMarginSlider")
                ReadingValueSlider("右边距", value: margin(\.rightMargin, other: \.leftMargin), range: 8...56, id: "rightMarginSlider")
                ReadingValueSlider("上边距", value: $store.settings.preferences.topMargin, range: 0...56, id: "topMarginSlider")
                ReadingValueSlider("下边距", value: $store.settings.preferences.bottomMargin, range: 0...56, id: "bottomMarginSlider")
                Text("关闭联动后可独立调整左右留白。行间距、段落间距与页面留白分别生效。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func margin(_ key: WritableKeyPath<ReaderPreferences, Double>, other: WritableKeyPath<ReaderPreferences, Double>) -> Binding<Double> {
        Binding(get: { store.settings.preferences[keyPath: key] }, set: { value in
            store.settings.preferences[keyPath: key] = value
            if store.settings.preferences.marginsLinked { store.settings.preferences[keyPath: other] = value }
        })
    }
}

struct ReadingOperationPreferencesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showGestureGuide = false
    private var effect: Binding<String> {
        store.settings.mode == .verticalPaged ? $store.settings.preferences.verticalEffect : $store.settings.preferences.horizontalEffect
    }
    private var effects: [String] { store.settings.mode == .verticalPaged ? ["平移", "覆盖", "无动画"] : ["平移", "覆盖", "仿真", "无动画"] }
    var body: some View {
        ReadingPreferencePage("翻页与手势") {
            AppSettingsCard("阅读方式", icon: "book.pages") {
                Picker("翻页模式", selection: $store.settings.mode) {
                    ForEach(ReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("readingModePicker")
                if store.settings.mode.isPaged {
                    Picker("翻页效果", selection: effect) { ForEach(effects, id: \.self) { Text($0).tag($0) } }.accessibilityIdentifier("readingEffectPicker")
                } else { Text("连续滚动 · 正文随手指上下移动").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                Text(store.settings.mode == .scroll ? "上滑继续阅读，下滑回看。" : store.settings.mode == .verticalPaged ? "上滑下一页，下滑上一页。" : "左滑下一页，右滑上一页。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text("滑动是触发方式，仿真、平移等是翻页效果；切换方向时分别记忆。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            ReadingTurnPreview(settings: store.settings)
            AppSettingsCard("单手操作", icon: "hand.tap") {
                Toggle("轻触翻页", isOn: $store.settings.tapToTurn).accessibilityIdentifier("tapToTurnToggle")
                Text("轻点左右两侧前进，中间显示／隐藏菜单。滚动模式前进约一屏。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Toggle("轻微触觉反馈", isOn: $store.settings.haptics).accessibilityIdentifier("hapticsToggle")
                Button { showGestureGuide = true } label: { ReadingPreferenceRow(title: "查看阅读手势", detail: "滑动与轻点操作") }.accessibilityIdentifier("readingGestureHelp")
            }
        }.sheet(isPresented: $showGestureGuide) { ReadingGestureGuideView(isFirstUse: false) }
    }
}

struct ReadingTurnPreview: View {
    let settings: ReadingSettings
    @EnvironmentObject private var store: LibraryStore
    @State private var page = 0
    private var ink: Color { settings.preferences.colors.map { Color(hex: $0.ink) } ?? settings.theme.ink }
    private var paper: Color { settings.preferences.colors.map { Color(hex: $0.background) } ?? settings.theme.background }
    private var sample: NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = settings.lineSpacing
        let text = page.isMultiple(of: 2) ? "雨是在午后停的。山路尽头，一盏茶正冒着温热的白气。" : "她把书页折起，抬眼望向远处的群山。风经过窗边，故事才刚刚开始。"
        return NSAttributedString(string: "第三章 · 山海有相逢\n\n" + text + "\n\n第 \(page + 1) 页", attributes: [.font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: UIColor(ink), .paragraphStyle: paragraph])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if settings.mode == .scroll, let book = store.books.first {
                    ContinuousReaderText(document: ReaderDocument(book: book, chapter: 0, settings: settings), anchor: .init(), layoutID: "preview-\(settings.fontSize)-\(settings.lineSpacing)", restoreID: 0, turn: page, onAnchor: { _ in }, onTap: { _ in page += 1 }, onBoundary: { _ in })
                } else {
                    PagedReaderText(text: sample, onTap: { _ in page += 1 }, onSwipe: { page = max(0, page + ($0 ? 1 : -1)) }, mode: settings.mode, effect: settings.preferences.effect(for: settings.mode), pageID: page, layoutID: "preview-\(settings.mode.rawValue)-\(settings.preferences.effect(for: settings.mode))", paperColor: UIColor(paper))
                        .padding(18)
                }
            }.frame(height: 240).background(paper).clipShape(.rect(cornerRadius: 12)).accessibilityIdentifier("readingTurnPreview")
            HStack {
                Text("\(settings.mode.title) · \(settings.preferences.effect(for: settings.mode))").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button(settings.mode == .scroll ? "试滚动一屏" : "试翻下一页") { page += 1 }.font(.system(size: 12)).frame(minHeight: 36).accessibilityIdentifier("tryReadingTurn")
            }
        }.onChange(of: settings.mode) { _, _ in page = 0 }
    }
}

enum ReadingPreferencePresentation {
    static func titleStyle(settings: ReadingSettings) throws -> ReaderTitleStyle {
        try ReaderTitleStyle.parse(css: settings.preferences.effectiveTitleCSS, accent: ReaderPalette(settings: settings).hexAccent)
    }
    static func titleColor(settings: ReadingSettings) -> UIColor {
        guard let color = (try? titleStyle(settings: settings))?.color else { return ReaderPalette(settings: settings).ink }
        return UIColor(readerHex: color)
    }
    static func titleEditorCSS(settings: ReadingSettings) -> String {
        settings.preferences.effectiveTitleCSS ?? ".chapter-title {}"
    }
    static func fontDisplayName(_ name: String?, entries: [ReadingFontEntry]) -> String {
        guard let name else { return "系统黑体" }
        if name == "__serif__" { return "系统衬线" }
        if let entry = entries.first(where: { $0.postScriptName == name }) { return entry.displayName }
        return UIFont(name: name, size: 20)?.familyName ?? "当前字体（待重新导入）"
    }
    static func sampleFont(_ name: String?, settings: ReadingSettings) -> UIFont {
        var sampleSettings = settings
        sampleSettings.preferences.fontName = name
        return ReaderTypography.font(settings: sampleSettings)
    }
}

struct ReadingSettingsPreview: View {
    let settings: ReadingSettings
    var showChrome = true
    private var prefs: ReaderPreferences { settings.preferences }
    private var ink: Color { Color(ReaderPalette(settings: settings).ink) }
    private var paper: Color { Color(ReaderPalette(settings: settings).background) }
    private var accent: UInt32 { ReaderPalette(settings: settings).hexAccent }
    private var title: ReaderTitleStyle? { try? ReadingPreferencePresentation.titleStyle(settings: settings) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showChrome && prefs.headerEnabled { ReaderPageRegionPreview(settings: settings, zone: "header").padding(.bottom, prefs.headerGap) }
            titlePreview
            VStack(alignment: .leading, spacing: prefs.paragraphSpacing) {
                previewParagraph("雨是在午后停的。她说：「山路尽头，总有人为你留一盏茶。」")
                if prefs.showGodComments { GodCommentPreview(settings: settings) }
                previewParagraph("她推开木窗，让远山的风翻过书页。窗外的故事，还在慢慢继续。", isFirst: false)
                if prefs.rules.contains(where: { $0.enabled && $0.match == "系统提示" }) { previewParagraph("【系统提示：已解锁山海图鉴】", isFirst: false) }
                if prefs.rules.contains(where: { $0.enabled && $0.match == "诗词段落" }) { previewParagraph("长风破浪会有时，直挂云帆济沧海。", isFirst: false) }
            }.padding(.top, 8)
            if showChrome && prefs.footerEnabled { ReaderPageRegionPreview(settings: settings, zone: "footer").padding(.top, prefs.footerGap) }
        }.foregroundStyle(ink).padding(.leading, prefs.leftMargin).padding(.trailing, prefs.rightMargin)
            .padding(.top, prefs.topMargin).padding(.bottom, prefs.bottomMargin)
            .frame(maxWidth: .infinity, alignment: .leading).background(paper, in: .rect(cornerRadius: 13))
            .accessibilityElement(children: .contain).accessibilityIdentifier("readingStylePreview")
            .accessibilityValue("字号 \(Int(settings.fontSize))，行距 \(Int(settings.lineSpacing))，段距 \(Int(prefs.paragraphSpacing))")
    }
    private var titlePreview: some View {
        Text("第三章 · 山海有相逢")
            .font(titleFont)
            .tracking(title?.tracking ?? 0).underline(title?.underline ?? false)
            .foregroundStyle(Color(ReadingPreferencePresentation.titleColor(settings: settings)))
            .padding(.top, title?.spacingBefore ?? 0).padding(.bottom, title?.spacingAfter ?? 15)
            .frame(maxWidth: .infinity, alignment: title?.alignment == "right" ? .trailing : title?.alignment == "center" ? .center : .leading)
            .background(title?.background.map { Color(hex: $0) } ?? .clear)
    }
    private func previewParagraph(_ paragraph: String, isFirst: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            (Text(styled(paragraph, isFirst: isFirst)) + bubbleText)
                .font(bodyFont).lineSpacing(settings.lineSpacing).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var bubbleText: Text {
        guard prefs.showCommentBubbles else { return Text("") }
        let source = ReaderCommentArtwork.bubble(settings: settings)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 20)).image { _ in source.draw(in: CGRect(x: 0, y: 0, width: 32, height: 20)) }
        return Text(" ") + Text(Image(uiImage: image)).baselineOffset(-4)
    }

    private var titleFont: Font {
        let size = title?.fontSize ?? 26
        let base = UIFont.systemFont(ofSize: size, weight: ReaderTypography.weight(title?.fontWeight ?? "medium"))
        return Font(UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size))
    }
    private var bodyFont: Font { Font(ReaderTypography.font(settings: settings)) }
    private func styled(_ paragraph: String, isFirst: Bool) -> AttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing
        paragraphStyle.paragraphSpacing = prefs.paragraphSpacing
        let value = NSMutableAttributedString(string: paragraph, attributes: [.font: ReaderTypography.font(settings: settings), .foregroundColor: UIColor(ink), .paragraphStyle: paragraphStyle])
        ReaderTypography.applyRules(prefs.rules, to: value, paragraph: isFirst ? 0 : 1, settings: settings)
        if prefs.firstLineIndent { value.insert(NSAttributedString(string: "　　"), at: 0) }
        return AttributedString(value)
    }

}

struct GodCommentPreview: View {
    let settings: ReadingSettings
    var body: some View {
        Image(uiImage: ReaderCommentArtwork.godComment(settings: settings)).resizable().scaledToFit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("神人评论 · 本地示例：这盏茶，怕不是等了整整一章。")
    }
}

private struct ReadingPreferenceDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var readingPreferenceDismiss: (() -> Void)? {
        get { self[ReadingPreferenceDismissKey.self] }
        set { self[ReadingPreferenceDismissKey.self] = newValue }
    }
}

private struct ReadingPreferenceDoneToolbar: ViewModifier {
    @Environment(\.readingPreferenceDismiss) private var dismissPreferences
    func body(content: Content) -> some View {
        content.toolbar {
            if let dismissPreferences {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: dismissPreferences).accessibilityIdentifier("readingPreferencesDone")
                }
            }
        }
    }
}

extension View {
    func readingPreferenceDoneToolbar() -> some View { modifier(ReadingPreferenceDoneToolbar()) }
}

struct ReadingPreferencePage<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) { content }.padding(22) }.appPageStyle().navigationTitle(title).navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar() }
}

struct ReadingPreferenceRow: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(spacing: 12) { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13)); if !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted) } }; Spacer(minLength: 3); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted) }.frame(minHeight: 38).contentShape(Rectangle())
    }
}

struct ReadingValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "pt"
    var id: String?
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "pt", id: String? = nil) { self.title = title; _value = value; self.range = range; self.unit = unit; self.id = id }
    var body: some View {
        VStack(spacing: 7) {
            HStack { Text(title); Spacer(); Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(Palette.muted) }.font(.system(size: 12))
            Slider(value: $value, in: range, step: 1).accessibilityLabel(title).accessibilityValue("\(Int(value)) \(unit)").accessibilityIdentifier(id ?? title)
        }
    }
}

extension Color {
    var readingPreferenceHex: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0x354F40 }
        return UInt32(red * 255) << 16 | UInt32(green * 255) << 8 | UInt32(blue * 255)
    }
}
