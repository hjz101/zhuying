import SwiftUI
import UniformTypeIdentifiers

struct ReaderPageRegionPreview: View {
    let settings: ReadingSettings
    let zone: String
    var selectedID: String? = nil
    var onSelect: ((String) -> Void)? = nil
    var onMove: ((String, Double, Double) -> Void)? = nil
    private var prefs: ReaderPreferences { settings.preferences }
    private var height: Double { zone == "header" ? prefs.headerHeight : prefs.footerHeight }
    private var ink: Color { prefs.colors.map { Color(hex: $0.ink) } ?? settings.theme.ink }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if onMove != nil { RoundedRectangle(cornerRadius: 5).stroke(ink.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                ForEach(prefs.pageElements.filter { $0.zone == zone }) { raw in
                    let item = raw.constrained(headerHeight: prefs.headerHeight, footerHeight: prefs.footerHeight)
                    if let onMove {
                        label(item, width: geo.size.width)
                            .onTapGesture { onSelect?(item.id) }
                            .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("page-region-\(zone)")).onChanged { value in
                                onSelect?(item.id)
                                onMove(item.id, value.location.x / max(1, geo.size.width) * 100, value.location.y / max(1, geo.size.height) * 100)
                            }.onEnded { value in
                                onSelect?(item.id)
                                onMove(item.id, value.location.x / max(1, geo.size.width) * 100, value.location.y / max(1, geo.size.height) * 100)
                            })
                            .position(x: geo.size.width * item.x / 100, y: geo.size.height * item.y / 100)
                    } else {
                        label(item, width: geo.size.width)
                            .position(x: geo.size.width * item.x / 100, y: geo.size.height * item.y / 100)
                    }
                }
            }.coordinateSpace(name: "page-region-\(zone)")
        }.frame(height: height).accessibilityElement(children: .contain).accessibilityIdentifier("page-region-\(zone)")
    }
    private func label(_ item: ReaderPageElement, width: CGFloat) -> some View {
        let elementWidth: CGFloat = width * CGFloat(item.width) / 100
        let elementHeight: CGFloat = max(28, CGFloat(item.fontSize) + 12)
        let color = item.color.map { Color(hex: $0) } ?? ink.opacity(0.7)
        return Text(display(item)).font(.system(size: item.fontSize)).foregroundStyle(color)
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
            .frame(width: elementWidth, height: elementHeight)
            .background(selectedID == item.id ? Palette.green.opacity(0.08) : Color.clear)
            .overlay { if selectedID == item.id { RoundedRectangle(cornerRadius: 4).stroke(Palette.accent, lineWidth: 1) } }
            .contentShape(Rectangle()).accessibilityIdentifier("page-element-\(item.id)")
            .accessibilityLabel("\(zone == "header" ? "页眉" : "页脚")\(item.kind)")
    }
    private func display(_ item: ReaderPageElement) -> String {
        switch item.kind {
        case "书名": "长风渡山海"
        case "章节": "第三章"
        case "时间": "09:41"
        case "进度": settings.mode.isPaged ? "12 / 180" : "章进度 36%"
        default: item.text
        }
    }
}

struct ReadingPageElementsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedID: String?
    private var prefs: ReaderPreferences { store.settings.preferences }
    private var selected: ReaderPageElement? { prefs.pageElements.first { $0.id == selectedID } }

    var body: some View {
        ReadingPreferencePage("页眉与页脚") {
            editorPreview
            Text("点选文字并拖动，也可在下方用 X / Y 精确微调。每个区域可添加多个元素。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            AppSettingsCard("显示区域", icon: "rectangle.topthird.inset.filled") {
                Toggle("显示页眉", isOn: $store.settings.preferences.headerEnabled).accessibilityIdentifier("readerHeaderEnabled")
                Toggle("显示页脚", isOn: $store.settings.preferences.footerEnabled).accessibilityIdentifier("readerFooterEnabled")
                HStack {
                    Button("＋ 页眉元素") { add("header") }.accessibilityIdentifier("addHeaderElement")
                    Spacer()
                    Button("＋ 页脚元素") { add("footer") }.accessibilityIdentifier("addFooterElement")
                }.font(.system(size: 12)).frame(minHeight: 38)
            }
            if !prefs.pageElements.isEmpty { elementPicker }
            if let selected { elementEditor(selected) }
            AppSettingsCard("区域高度与正文距离", icon: "arrow.up.and.down") {
                ReadingValueSlider("页眉区域高度", value: $store.settings.preferences.headerHeight, range: 48...120, id: "headerHeightSlider")
                ReadingValueSlider("页脚区域高度", value: $store.settings.preferences.footerHeight, range: 48...120, id: "footerHeightSlider")
                ReadingValueSlider("页眉与正文间距", value: $store.settings.preferences.headerGap, range: 0...40, id: "headerGapSlider")
                ReadingValueSlider("页脚与正文间距", value: $store.settings.preferences.footerGap, range: 0...40, id: "footerGapSlider")
                Text("元素位置相对于各自区域，区域留白参与正文排版。重叠时可用元素名称切换选中项。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.onAppear { if selectedID == nil { selectedID = prefs.pageElements.first?.id } }
    }
    private var editorPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if prefs.headerEnabled { ReaderPageRegionPreview(settings: store.settings, zone: "header", selectedID: selectedID, onSelect: { selectedID = $0 }, onMove: move) }
            Text("第三章 · 山海有相逢").font(.system(size: 19, design: .serif))
            Text("雨是在午后停的。山路尽头，一盏茶正冒着温热的白气。").font(.system(size: min(22, store.settings.fontSize))).lineSpacing(store.settings.lineSpacing)
            if prefs.footerEnabled { ReaderPageRegionPreview(settings: store.settings, zone: "footer", selectedID: selectedID, onSelect: { selectedID = $0 }, onMove: move) }
        }.padding(16).foregroundStyle(prefs.colors.map { Color(hex: $0.ink) } ?? store.settings.theme.ink)
            .background(prefs.colors.map { Color(hex: $0.background) } ?? store.settings.theme.background, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("pageElementsPreview")
    }
    private var elementPicker: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(prefs.pageElements) { item in
                Button { selectedID = item.id } label: {
                    Text("\(item.zone == "header" ? "页眉" : "页脚") · \(item.kind)").font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 38)
                        .background(selectedID == item.id ? Palette.green : Palette.soft, in: .rect(cornerRadius: 8))
                        .foregroundStyle(selectedID == item.id ? .white : Palette.green)
                }.accessibilityIdentifier("page-element-choice-\(item.id)").accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
            }
        }
    }
    private func elementEditor(_ item: ReaderPageElement) -> some View {
        AppSettingsCard("选中元素 · \(item.kind)", icon: "move.3d") {
            Picker("所在区域", selection: elementBinding(\.zone, fallback: "header")) { Text("页眉").tag("header"); Text("页脚").tag("footer") }.accessibilityIdentifier("pageElementZone")
            Picker("显示内容", selection: elementBinding(\.kind, fallback: "书名")) { ForEach(["书名", "章节", "时间", "进度", "自定义文字"], id: \.self) { Text($0) } }.accessibilityIdentifier("pageElementKind")
            if item.kind == "自定义文字" { TextField("显示文字", text: elementBinding(\.text, fallback: "")).textFieldStyle(.roundedBorder).accessibilityIdentifier("pageElementText") }
            ReadingValueSlider("横向位置 X", value: elementBinding(\.x, fallback: 50), range: 0...100, unit: "%", id: "pageElementX")
            ReadingValueSlider("纵向位置 Y", value: elementBinding(\.y, fallback: 50), range: 0...100, unit: "%", id: "pageElementY")
            ReadingValueSlider("元素宽度", value: elementBinding(\.width, fallback: 40), range: 15...90, unit: "%", id: "pageElementWidth")
            ReadingValueSlider("元素字号", value: elementBinding(\.fontSize, fallback: 11), range: 9...22, id: "pageElementFontSize")
            ColorPicker("元素颜色", selection: Binding(get: { Color(hex: selected?.color ?? prefs.colors?.ink ?? 0x354F40) }, set: { color in update { $0.color = color.readingPreferenceHex } }), supportsOpacity: false)
            Button("删除选中元素", role: .destructive) {
                store.settings.preferences.pageElements.removeAll { $0.id == selectedID }
                selectedID = prefs.pageElements.first?.id
            }.frame(minHeight: 36).accessibilityIdentifier("removePageElement")
        }
    }
    private func add(_ zone: String) {
        let item = ReaderPageElement(zone: zone, kind: "自定义文字", text: "我的文字")
        store.settings.preferences.pageElements.append(item)
        if zone == "header" { store.settings.preferences.headerEnabled = true } else { store.settings.preferences.footerEnabled = true }
        selectedID = item.id
    }
    private func move(_ id: String, _ x: Double, _ y: Double) { selectedID = id; update { $0.x = x; $0.y = y } }
    private func update(_ operation: (inout ReaderPageElement) -> Void) {
        guard let index = prefs.pageElements.firstIndex(where: { $0.id == selectedID }) else { return }
        var item = prefs.pageElements[index]; operation(&item)
        store.settings.preferences.pageElements[index] = item.constrained(headerHeight: prefs.headerHeight, footerHeight: prefs.footerHeight)
    }
    private func elementBinding<Value>(_ key: WritableKeyPath<ReaderPageElement, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { selected?[keyPath: key] ?? fallback }, set: { value in update { $0[keyPath: key] = value } })
    }
}

struct ReadingTitlePreferencesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var cssText = ""
    @State private var error: String?
    @State private var showFiles = false
    @State private var suppressEditorChange = false
    private var prefs: ReaderPreferences { store.settings.preferences }
    private var accent: UInt32 { ReaderPalette(settings: store.settings).hexAccent }
    private var parsed: ReaderTitleStyle? { try? ReadingPreferencePresentation.titleStyle(settings: store.settings) }
    private let starter = ".chapter-title {\n  font-size: 26px;\n  text-align: center;\n  color: var(--reader-accent);\n  padding-bottom: 15px;\n}"

    var body: some View {
        ReadingPreferencePage("章节标题") {
            ReadingSettingsPreview(settings: store.settings)
            Picker("样式来源", selection: sourceBinding) { Text("跟随主题").tag(false); Text("自定义").tag(true) }.pickerStyle(.segmented).accessibilityIdentifier("titleStyleSource")
            Text(prefs.titleCSS == nil ? "使用主题标题样式，修改下方选项会创建个人样式。" : "个人自定义，切换主题时保留。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            AppSettingsCard("标题样式", icon: "textformat") {
                ReadingValueSlider("标题字号", value: titleNumber("font-size", default: parsed?.fontSize ?? 26), range: 14...40, id: "titleFontSizeSlider")
                Picker("标题对齐", selection: titleAlignment) { Text("居左").tag("left"); Text("居中").tag("center"); Text("居右").tag("right") }.accessibilityIdentifier("titleAlignmentPicker")
                ReadingValueSlider("标题字距", value: titleNumber("letter-spacing", default: parsed?.tracking ?? 0), range: 0...12, id: "titleTrackingSlider")
                ReadingValueSlider("标题上方留白", value: titleNumber("padding-top", default: parsed?.spacingBefore ?? 0), range: 0...40, id: "titleSpacingBeforeSlider")
                ReadingValueSlider("标题下方留白", value: titleNumber("padding-bottom", default: parsed?.spacingAfter ?? 15), range: 0...40, id: "titleSpacingAfterSlider")
                ColorPicker("标题颜色", selection: Binding(get: { Color(ReadingPreferencePresentation.titleColor(settings: store.settings)) }, set: { setProperty("color", String(format: "#%06X", $0.readingPreferenceHex)) }), supportsOpacity: false)
                Toggle("标题下划线", isOn: Binding(get: { parsed?.underline ?? false }, set: { setProperty("border-bottom", $0 ? "1px solid currentColor" : "none") }))
            }
            AppSettingsCard("高级 CSS", icon: "curlybraces") {
                HStack {
                    Button("新建 CSS") { apply(starter) }.accessibilityIdentifier("newTitleCSS")
                    Spacer()
                    Button("导入 CSS") { showFiles = true }.accessibilityIdentifier("importTitleCSS")
                }.font(.system(size: 13)).frame(minHeight: 40)
                TextEditor(text: $cssText).font(.system(size: 11, design: .monospaced)).frame(height: 170).scrollContentBackground(.hidden)
                    .padding(8).background(Palette.background, in: .rect(cornerRadius: 8)).accessibilityIdentifier("titleCSSEditor")
                    .onChange(of: cssText) { _, value in
                        if suppressEditorChange { suppressEditorChange = false }
                        else if value != prefs.effectiveTitleCSS { apply(value, updateEditor: false) }
                    }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.accent).accessibilityIdentifier("titleCSSError") }
                Text("支持标题字号、对齐、颜色、背景、字距、上下留白、字重及下划线；不支持的属性会明确提示，预览保留上次有效样式。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.onAppear { setEditor(ReadingPreferencePresentation.titleEditorCSS(settings: store.settings)) }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.plainText, UTType(filenameExtension: "css") ?? .plainText]) { result in
                do {
                    let url = try result.get(); let allowed = url.startAccessingSecurityScopedResource(); defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 60_000, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                    apply(text)
                } catch { self.error = error.localizedDescription }
            }
    }
    private var sourceBinding: Binding<Bool> {
        Binding(get: { prefs.titleCSS != nil }, set: { custom in
            if custom { apply(prefs.effectiveTitleCSS ?? starter) }
            else { store.settings.preferences.titleCSS = nil; setEditor(ReadingPreferencePresentation.titleEditorCSS(settings: store.settings)); error = nil }
        })
    }
    private var titleAlignment: Binding<String> { Binding(get: { parsed?.alignment ?? "left" }, set: { setProperty("text-align", $0) }) }
    private func titleNumber(_ key: String, default value: Double) -> Binding<Double> {
        Binding(get: {
            let style = parsed
            switch key { case "font-size": return style?.fontSize ?? value; case "letter-spacing": return style?.tracking ?? value; case "padding-top": return style?.spacingBefore ?? value; default: return style?.spacingAfter ?? value }
        }, set: { setProperty(key, "\(Int($0))px") })
    }
    private func setProperty(_ key: String, _ value: String) {
        let style = parsed
        var properties = ["font-size": "\(Int(style?.fontSize ?? 26))px", "text-align": style?.alignment ?? "left", "letter-spacing": "\(style?.tracking ?? 0)px", "padding-top": "\(style?.spacingBefore ?? 0)px", "padding-bottom": "\(style?.spacingAfter ?? 15)px", "color": String(format: "#%06X", style?.color ?? prefs.colors?.ink ?? store.settings.theme.ink.readingPreferenceHex), "border-bottom": style?.underline == true ? "1px solid currentColor" : "none"]
        properties["font-weight"] = style?.fontWeight ?? "medium"
        if let background = style?.background { properties["background-color"] = String(format: "#%06X", background) }
        properties[key] = value
        apply(".chapter-title {\n" + properties.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value);" }.joined(separator: "\n") + "\n}")
    }
    private func setEditor(_ text: String) {
        guard cssText != text else { return }
        suppressEditorChange = true; cssText = text
    }
    private func apply(_ text: String, updateEditor: Bool = true) {
        do { _ = try ReaderTitleStyle.parse(css: text, accent: accent); store.settings.preferences.titleCSS = text; if updateEditor { setEditor(text) }; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
