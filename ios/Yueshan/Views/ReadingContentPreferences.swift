import SwiftUI
import UniformTypeIdentifiers

struct ReadingContentPreferencesView: View {
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ReadingPreferencePage("正文与段评") {
            ReadingSettingsPreview(settings: store.settings)
            AppSettingsCard("正文与段评", icon: "text.bubble") {
                NavigationLink { ReadingStyleRulesView() } label: { ReadingPreferenceRow(title: "正文样式规则", detail: "对话 · 系统消息 · 诗词 · 首字下沉") }.accessibilityIdentifier("reading-style-rules")
                Divider()
                NavigationLink { ReadingCommentsPreferencesView() } label: { ReadingPreferenceRow(title: "段评与神人评论", detail: "段尾气泡与段下评论分别管理") }.accessibilityIdentifier("reading-comments")
            }
        }
    }
}

struct ReadingStyleRulesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var editing: ReaderStyleRule?
    @State private var showImport = false
    @State private var importMessage: String?
    var body: some View {
        ReadingPreferencePage("正文样式规则") {
            ReadingSettingsPreview(settings: store.settings)
            HStack {
                Button("＋ 新建规则") { editing = ReaderStyleRule(name: "我的正文规则", enabled: true) }.accessibilityIdentifier("addReadingRule")
                Spacer()
                Button("导入规则") { showImport = true }.accessibilityIdentifier("importReadingRules")
            }.font(.system(size: 13)).frame(minHeight: 44)
            ForEach(Array(store.settings.preferences.rules.enumerated()), id: \.element.id) { index, rule in
                AppSettingsCard(rule.name, icon: "highlighter") {
                    Toggle("启用规则", isOn: ruleEnabled(rule.id)).accessibilityIdentifier("reading-rule-enabled-\(rule.id)")
                    Text("\(rule.match) → \(rule.presentation)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack {
                        Button("编辑") { editing = rule }.accessibilityIdentifier("reading-rule-edit-\(rule.id)")
                        Spacer()
                        Button("上移") { move(index, by: -1) }.disabled(index == 0).accessibilityIdentifier("reading-rule-up-\(rule.id)")
                        Button("下移") { move(index, by: 1) }.disabled(index + 1 == store.settings.preferences.rules.count)
                        Button("删除", role: .destructive) { store.settings.preferences.rules.removeAll { $0.id == rule.id } }.accessibilityIdentifier("reading-rule-delete-\(rule.id)")
                    }.font(.system(size: 12)).frame(minHeight: 38)
                }
            }
            if let importMessage { Text(importMessage).font(.system(size: 11)).foregroundStyle(Palette.accent).accessibilityIdentifier("readingRuleImportResult") }
            Text(store.isDemo ? "从上到下决定同类样式的优先级；首字下沉是段落装饰，可与对话高亮叠加。规则作用于全部书籍。" : "书籍规则优先于书源及全局规则；同范围按列表顺序。样式不修改正文或文字位置。").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .sheet(item: $editing) { rule in
            NavigationStack {
                ReadingStyleRuleEditor(initial: rule) { value in
                    if let index = store.settings.preferences.rules.firstIndex(where: { $0.id == value.id }) { store.settings.preferences.rules[index] = value }
                    else { store.settings.preferences.rules.append(value) }
                    editing = nil
                }
            }.environment(\.readingPreferenceDismiss, nil)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 128_000 else { throw ReaderPreferenceError.invalid("规则文件超过 128 KB。") }
                let decoder = JSONDecoder()
                let rules: [ReaderStyleRule]
                if let list = try? decoder.decode([ReaderStyleRule].self, from: data) { rules = list }
                else { rules = [try decoder.decode(ReaderStyleRule.self, from: data)] }
                guard !rules.isEmpty, rules.count + store.settings.preferences.rules.count <= 64 else { throw ReaderPreferenceError.invalid("最多保存 64 条规则。") }
                for rule in rules { try rule.validate(); if rule.scope == "当前书籍", rule.bookID == nil { throw ReaderPreferenceError.invalid("书籍规则缺少作品标识。") }; if rule.scope == "当前书源",rule.sourceID == nil { throw ReaderPreferenceError.invalid("来源规则缺少书源标识。") } }
                for var rule in rules { rule.id = UUID().uuidString; store.settings.preferences.rules.append(rule) }
                importMessage = "已导入 \(rules.count) 条规则。"
            } catch { importMessage = error.localizedDescription }
        }
    }
    private func ruleEnabled(_ id: String) -> Binding<Bool> {
        Binding(get: { store.settings.preferences.rules.first { $0.id == id }?.enabled ?? false }, set: { enabled in
            guard let index = store.settings.preferences.rules.firstIndex(where: { $0.id == id }) else { return }
            store.settings.preferences.rules[index].enabled = enabled
        })
    }
    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard store.settings.preferences.rules.indices.contains(index), store.settings.preferences.rules.indices.contains(target) else { return }
        store.settings.preferences.rules.swapAt(index, target)
    }
}

struct ReadingStyleRuleEditor: View {
    let initial: ReaderStyleRule
    let onSave: (ReaderStyleRule) -> Void
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReaderStyleRule
    @State private var error: String?
    @State private var testText = "她说：「山路尽头，总有人为你留一盏茶。」\n【系统提示：已解锁山海图鉴】\n长风破浪会有时，直挂云帆济沧海。"
    init(initial: ReaderStyleRule, onSave: @escaping (ReaderStyleRule) -> Void) { self.initial = initial; self.onSave = onSave; _draft = State(initialValue: initial) }
    private var previewSettings: ReadingSettings {
        var settings = store.settings
        settings.preferences.rules.removeAll { $0.id == draft.id }
        var preview = draft; preview.enabled = true; preview.scope = "全部书籍"
        settings.preferences.rules.insert(preview, at: 0)
        return settings
    }
    var body: some View {
        ReadingPreferencePage("编辑样式规则") {
            ReadingSettingsPreview(settings: previewSettings)
            AppSettingsCard("匹配条件", icon: "text.magnifyingglass") {
                TextField("规则名称", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("readingRuleName")
                Picker("匹配对象", selection: $draft.match) { ForEach(["对话引号", "系统提示", "诗词段落", "章节首段", "正则表达式", "关键词"], id: \.self) { Text($0) } }.accessibilityIdentifier("readingRuleMatch")
                if draft.match == "正则表达式" || draft.match == "关键词" {
                    TextField(draft.match == "关键词" ? "关键词" : "正则表达式", text: $draft.pattern, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).accessibilityIdentifier("readingRulePattern")
                }
                Picker("呈现方式", selection: $draft.presentation) { ForEach(["文字高亮", "段落底色", "居中斜体", "首字下沉"], id: \.self) { Text($0) } }.accessibilityIdentifier("readingRulePresentation")
                ColorPicker("样式颜色", selection: Binding(get: { Color(hex: draft.color) }, set: { draft.color = $0.readingPreferenceHex }), supportsOpacity: false)
                if store.isDemo { Text("作用范围：全部书籍").font(.system(size:11)).foregroundStyle(Palette.muted) }
                else {
                    Picker("作用范围",selection:$draft.scope) { ForEach(["全部书籍","当前书籍","当前书源"],id:\.self) { Text($0) } }.accessibilityIdentifier("readingRuleScope")
                    if draft.scope == "当前书籍" { Picker("作品",selection:Binding(get:{draft.bookID ?? ""},set:{draft.bookID = $0})) { Text("选择作品").tag(""); ForEach(store.books) { Text($0.title).tag($0.id) } } }
                    if draft.scope == "当前书源" { Picker("书源",selection:Binding(get:{draft.sourceID ?? ""},set:{draft.sourceID = $0})) { Text("选择书源").tag(""); ForEach(store.sources) { Text($0.name).tag($0.id) } } }
                }
            }
            AppSettingsCard("匹配测试", icon: "checkmark.magnifyingglass") {
                TextEditor(text: $testText).font(.system(size: 12)).frame(height: 100).accessibilityIdentifier("readingRuleTestText")
                if let count = try? draft.ranges(in: testText).count { Text("命中 \(count) 处").font(.system(size: 12)).accessibilityIdentifier("readingRuleMatchCount") }
                else { Text("匹配条件无效，请检查表达式。").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("readingRuleError") }
            Button("保存规则") {
                do {
                    if draft.scope == "当前书籍",draft.bookID?.isEmpty != false { throw ReaderPreferenceError.invalid("请选择作用的作品。") }
                    if draft.scope == "当前书源",draft.sourceID?.isEmpty != false { throw ReaderPreferenceError.invalid("请选择作用的书源。") }
                    try draft.validate(); onSave(draft)
                }
                catch { self.error = error.localizedDescription }
            }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("saveReadingRule")
        }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
    }
}

struct ReadingCommentsPreferencesView: View {
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ReadingPreferencePage("段评与神人评论") {
            ReadingSettingsPreview(settings: store.settings)
            AppSettingsCard("段尾气泡", icon: "bubble.right") {
                Toggle("显示段评气泡", isOn: $store.settings.preferences.showCommentBubbles).accessibilityIdentifier("showReadingBubbles")
                NavigationLink { ReadingCommentSkinView(kind: .bubble) } label: { ReadingPreferenceRow(title: "气泡皮肤", detail: store.settings.preferences.bubbleFollowsTheme ? "跟随当前主题" : store.settings.preferences.bubbleStyle) }.accessibilityIdentifier("reading-bubble-skin")
                Text("气泡紧接段落末尾，显示该段评论数，点击打开该段评论。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            AppSettingsCard("神人评论", icon: "quote.bubble") {
                Toggle("显示神人评论", isOn: $store.settings.preferences.showGodComments).accessibilityIdentifier("showGodComments")
                NavigationLink { ReadingCommentSkinView(kind: .god) } label: { ReadingPreferenceRow(title: "神评卡片皮肤", detail: store.settings.preferences.effectiveGodStyle) }.accessibilityIdentifier("reading-god-skin")
                Text("精选评论显示在对应段落下方。当前阅读器使用本地示例评论，不连接评论服务。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
}

enum ReadingCommentSkinKind { case bubble, god }
struct ReadingCommentSkinView: View {
    let kind: ReadingCommentSkinKind
    @EnvironmentObject private var store: LibraryStore
    @State private var showImport = false
    @State private var error: String?
    private var styles: [String] { kind == .bubble ? ["胶囊", "描边", "圆角方形"] : ["纯色", "液态玻璃", "画框"] }
    private var style: Binding<String> {
        Binding(get: {
            if kind == .god { return store.settings.preferences.effectiveGodStyle }
            if store.settings.preferences.bubbleFollowsTheme { return store.settings.preferences.bubbleImageData == nil ? "胶囊" : "主题资源" }
            if store.settings.preferences.customBubbleSVG != nil { return "个人 SVG" }
            return store.settings.preferences.bubbleStyle
        }, set: { value in
            if kind == .bubble { if value == "主题资源" { store.settings.preferences.bubbleFollowsTheme = true } else if value == "个人 SVG" { store.settings.preferences.bubbleFollowsTheme = false }
                else { store.settings.preferences.bubbleStyle = value; store.settings.preferences.bubbleFollowsTheme = false; store.settings.preferences.customBubbleSVG = nil; store.settings.preferences.customBubbleImageData = nil } }
            else { store.settings.preferences.godStyle = value; store.settings.preferences.godFollowsTheme = false }
        })
    }
    var body: some View {
        ReadingPreferencePage(kind == .bubble ? "段尾气泡皮肤" : "神人评论皮肤") {
            ReadingSettingsPreview(settings: preview)
            AppSettingsCard("皮肤样式", icon: "paintbrush") {
                Toggle("跟随当前主题", isOn: followsTheme).accessibilityIdentifier("commentSkinFollowsTheme")
                Picker("基础样式", selection: style) { ForEach(styleOptions, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("commentSkinStylePicker")
                Button("新建个人皮肤") { style.wrappedValue = "自定义" }.font(.system(size: 13)).frame(minHeight: 40).accessibilityIdentifier("createCommentSkin")
                if !followsTheme.wrappedValue && style.wrappedValue == "自定义" { customControls }
                Button("导入皮肤 JSON") { showImport = true }.font(.system(size: 13)).frame(minHeight: 44).accessibilityIdentifier("importCommentSkin")
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent) }
            }
        }.fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count < 32_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["style"] as? String, (styles + ["自定义"]).contains(value) else { throw ReaderPreferenceError.invalid("请选择包含有效 style 名称的皮肤 JSON。") }
                style.wrappedValue = value
                if let radius = object["radius"] as? Double { if kind == .bubble { store.settings.preferences.bubbleRadius = min(30, max(0, radius)) } else { store.settings.preferences.godRadius = min(30, max(0, radius)) } }
                if let hex = object["background"] as? String, let color = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) { if kind == .bubble { store.settings.preferences.bubbleColor = color & 0xFFFFFF } else { store.settings.preferences.godBackground = color & 0xFFFFFF } }
                if let hex = object["border"] as? String, let color = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16), kind == .god { store.settings.preferences.godBorder = color & 0xFFFFFF }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private var styleOptions: [String] {
        var choices = styles
        if style.wrappedValue == "自定义" { choices.append("自定义") }
        if kind == .bubble && store.settings.preferences.customBubbleSVG != nil { choices.append("个人 SVG") }
        if kind == .bubble && store.settings.preferences.bubbleFollowsTheme && store.settings.preferences.bubbleImageData != nil { choices.append("主题资源") }
        return choices
    }
    private var followsTheme: Binding<Bool> { kind == .bubble ? $store.settings.preferences.bubbleFollowsTheme : $store.settings.preferences.godFollowsTheme }
    @ViewBuilder private var customControls: some View {
        if kind == .bubble {
            ReadingValueSlider("气泡圆角", value: $store.settings.preferences.bubbleRadius, range: 0...30, id: "bubbleRadiusSlider")
            ColorPicker("气泡颜色", selection: Binding(get: { Color(hex: store.settings.preferences.bubbleColor ?? store.settings.preferences.colors?.accent ?? 0xB7815A) }, set: { store.settings.preferences.bubbleColor = $0.readingPreferenceHex }), supportsOpacity: false)
        } else {
            ReadingValueSlider("卡片圆角", value: $store.settings.preferences.godRadius, range: 0...30, id: "godRadiusSlider")
            ColorPicker("卡片底色", selection: Binding(get: { Color(hex: store.settings.preferences.godBackground ?? 0xF2EFE5) }, set: { store.settings.preferences.godBackground = $0.readingPreferenceHex }), supportsOpacity: false)
            ColorPicker("卡片边框", selection: Binding(get: { Color(hex: store.settings.preferences.godBorder ?? 0xB7815A) }, set: { store.settings.preferences.godBorder = $0.readingPreferenceHex }), supportsOpacity: false)
        }
    }
    private var preview: ReadingSettings { var settings = store.settings; if kind == .bubble { settings.preferences.showCommentBubbles = true } else { settings.preferences.showGodComments = true }; return settings }
}
