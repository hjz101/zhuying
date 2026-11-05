import Foundation

/// Persisted reader appearance shared by settings, previews and the native reader.
struct ReaderPreferences: Codable, Equatable {
    var paragraphSpacing: Double = 22
    var leftMargin: Double = 25
    var rightMargin: Double = 25
    var topMargin: Double = 24
    var bottomMargin: Double = 20
    var marginsLinked = true
    var firstLineIndent = true
    var fontName: String? = nil
    var fontResourceHash: String? = nil
    var fontWeight = "常规"
    var colors: ReaderColors? = nil
    var titleCSS: String? = nil
    var themeTitleCSS: String? = nil
    var headerEnabled = false
    var footerEnabled = false
    var headerHeight: Double = 64
    var footerHeight: Double = 64
    var headerGap: Double = 12
    var footerGap: Double = 12
    var pageElements: [ReaderPageElement] = ReaderPageElement.defaults
    var horizontalEffect = "平移"
    var verticalEffect = "平移"
    var rules: [ReaderStyleRule] = ReaderStyleRule.templates
    var showCommentBubbles = false
    var showGodComments = false
    var bubbleStyle = "胶囊"
    var godStyle = "纯色"
    var bubbleRadius: Double = 12
    var bubbleColor: UInt32? = nil
    var godRadius: Double = 10
    var godBackground: UInt32? = nil
    var godBorder: UInt32? = nil
    var bubbleFollowsTheme = true
    var godFollowsTheme = true
    var themeGodStyle: String? = nil
    var bubbleSVG: String? = nil
    var bubbleImageData: Data? = nil
    var customBubbleSVG: String? = nil
    var customBubbleImageData: Data? = nil

    var effectiveTitleCSS: String? { titleCSS ?? themeTitleCSS }
    var effectiveGodStyle: String { godFollowsTheme ? (themeGodStyle ?? "纯色") : godStyle }
    func effect(for mode: ReadingMode) -> String {
        switch mode {
        case .scroll: return "连续滚动"
        case .paged: return ["平移", "覆盖", "仿真", "无动画"].contains(horizontalEffect) ? horizontalEffect : "平移"
        case .verticalPaged: return ["平移", "覆盖", "无动画"].contains(verticalEffect) ? verticalEffect : "平移"
        }
    }
    mutating func normalize() {
        bubbleRadius = ReaderPreferenceBounds.clamp(bubbleRadius, 0...30, fallback: 12)
        godRadius = ReaderPreferenceBounds.clamp(godRadius, 0...30, fallback: 10)
        if let bubbleColor { self.bubbleColor = bubbleColor & 0xFFFFFF }
        if let godBackground { self.godBackground = godBackground & 0xFFFFFF }
        if let godBorder { self.godBorder = godBorder & 0xFFFFFF }
        paragraphSpacing = ReaderPreferenceBounds.clamp(paragraphSpacing, 0...48, fallback: 22)
        leftMargin = ReaderPreferenceBounds.clamp(leftMargin, 0...80, fallback: 25)
        rightMargin = ReaderPreferenceBounds.clamp(rightMargin, 0...80, fallback: 25)
        topMargin = ReaderPreferenceBounds.clamp(topMargin, 0...80, fallback: 24)
        bottomMargin = ReaderPreferenceBounds.clamp(bottomMargin, 0...80, fallback: 20)
        headerHeight = ReaderPreferenceBounds.clamp(headerHeight, 48...140, fallback: 64)
        footerHeight = ReaderPreferenceBounds.clamp(footerHeight, 48...140, fallback: 64)
        headerGap = ReaderPreferenceBounds.clamp(headerGap, 0...48, fallback: 12)
        footerGap = ReaderPreferenceBounds.clamp(footerGap, 0...48, fallback: 12)
        if !["常规", "细体", "中等", "粗体"].contains(fontWeight) { fontWeight = "常规" }
        if !["平移", "覆盖", "仿真", "无动画"].contains(horizontalEffect) { horizontalEffect = "平移" }
        if !["平移", "覆盖", "无动画"].contains(verticalEffect) { verticalEffect = "平移" }
        if let css = titleCSS, css.utf8.count > 60_000 { titleCSS = nil }
        if let css = themeTitleCSS, css.utf8.count > 60_000 { themeTitleCSS = nil }
        if let svg = bubbleSVG, svg.utf8.count > 60_000 { bubbleSVG = nil }
        if let image = bubbleImageData, image.count > 512_000 { bubbleImageData = nil }
        if let svg = customBubbleSVG, svg.utf8.count > 60_000 { customBubbleSVG = nil }
        if let image = customBubbleImageData, image.count > 512_000 { customBubbleImageData = nil }
        if let fontName, fontName.count > 200 { self.fontName = nil }
        if let hash = fontResourceHash, hash.count != 64 || !hash.allSatisfy({ "0123456789abcdef".contains($0) }) { fontResourceHash = nil; fontName = nil }
        var elementIDs = Set<String>()
        pageElements = Array(pageElements.prefix(32)).map { element in
            var value = element.constrained(headerHeight: headerHeight, footerHeight: footerHeight)
            if value.id.isEmpty || !elementIDs.insert(value.id).inserted {
                value.id = UUID().uuidString
                elementIDs.insert(value.id)
            }
            value.text = String(value.text.prefix(160))
            return value
        }
        var ruleIDs = Set<String>()
        rules = Array(rules.prefix(64)).map { rule in
            var value = rule
            if value.id.isEmpty || !ruleIDs.insert(value.id).inserted {
                value.id = UUID().uuidString
                ruleIDs.insert(value.id)
            }
            value.name = String(value.name.prefix(80))
            value.color &= 0xFFFFFF
            if value.scope != "全部书籍" || (try? value.validate()) == nil { value.enabled = false }
            return value
        }
        if var colors { colors.background &= 0xFFFFFF; colors.ink &= 0xFFFFFF; colors.accent &= 0xFFFFFF; self.colors = colors }
    }

    private enum CodingKeys: String, CodingKey {
        case paragraphSpacing, leftMargin, rightMargin, topMargin, bottomMargin, marginsLinked, firstLineIndent
        case fontName, fontResourceHash, fontWeight, colors, titleCSS, themeTitleCSS, headerEnabled, footerEnabled
        case headerHeight, footerHeight, headerGap, footerGap, pageElements, horizontalEffect, verticalEffect
        case rules, showCommentBubbles, showGodComments, bubbleStyle, godStyle, bubbleSVG, bubbleImageData
        case bubbleRadius, bubbleColor, godRadius, godBackground, godBorder, bubbleFollowsTheme, godFollowsTheme, themeGodStyle
        case customBubbleSVG, customBubbleImageData
    }
}

extension ReaderPreferences {
    init(from decoder: Decoder) throws {
        self.init()
        let box = try decoder.container(keyedBy: CodingKeys.self)
        paragraphSpacing = try box.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? paragraphSpacing
        leftMargin = try box.decodeIfPresent(Double.self, forKey: .leftMargin) ?? leftMargin
        rightMargin = try box.decodeIfPresent(Double.self, forKey: .rightMargin) ?? rightMargin
        topMargin = try box.decodeIfPresent(Double.self, forKey: .topMargin) ?? topMargin
        bottomMargin = try box.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? bottomMargin
        marginsLinked = try box.decodeIfPresent(Bool.self, forKey: .marginsLinked) ?? marginsLinked
        firstLineIndent = try box.decodeIfPresent(Bool.self, forKey: .firstLineIndent) ?? firstLineIndent
        fontName = try box.decodeIfPresent(String.self, forKey: .fontName)
        fontResourceHash = try box.decodeIfPresent(String.self, forKey: .fontResourceHash)
        fontWeight = try box.decodeIfPresent(String.self, forKey: .fontWeight) ?? fontWeight
        colors = try box.decodeIfPresent(ReaderColors.self, forKey: .colors)
        titleCSS = try box.decodeIfPresent(String.self, forKey: .titleCSS)
        themeTitleCSS = try box.decodeIfPresent(String.self, forKey: .themeTitleCSS)
        headerEnabled = try box.decodeIfPresent(Bool.self, forKey: .headerEnabled) ?? headerEnabled
        footerEnabled = try box.decodeIfPresent(Bool.self, forKey: .footerEnabled) ?? footerEnabled
        headerHeight = try box.decodeIfPresent(Double.self, forKey: .headerHeight) ?? headerHeight
        footerHeight = try box.decodeIfPresent(Double.self, forKey: .footerHeight) ?? footerHeight
        headerGap = try box.decodeIfPresent(Double.self, forKey: .headerGap) ?? headerGap
        footerGap = try box.decodeIfPresent(Double.self, forKey: .footerGap) ?? footerGap
        pageElements = try box.decodeIfPresent([ReaderPageElement].self, forKey: .pageElements) ?? pageElements
        horizontalEffect = try box.decodeIfPresent(String.self, forKey: .horizontalEffect) ?? horizontalEffect
        verticalEffect = try box.decodeIfPresent(String.self, forKey: .verticalEffect) ?? verticalEffect
        rules = try box.decodeIfPresent([ReaderStyleRule].self, forKey: .rules) ?? rules
        showCommentBubbles = try box.decodeIfPresent(Bool.self, forKey: .showCommentBubbles) ?? showCommentBubbles
        showGodComments = try box.decodeIfPresent(Bool.self, forKey: .showGodComments) ?? showGodComments
        bubbleStyle = try box.decodeIfPresent(String.self, forKey: .bubbleStyle) ?? bubbleStyle
        godStyle = try box.decodeIfPresent(String.self, forKey: .godStyle) ?? godStyle
        bubbleSVG = try box.decodeIfPresent(String.self, forKey: .bubbleSVG)
        bubbleImageData = try box.decodeIfPresent(Data.self, forKey: .bubbleImageData)
        customBubbleSVG = try box.decodeIfPresent(String.self, forKey: .customBubbleSVG)
        customBubbleImageData = try box.decodeIfPresent(Data.self, forKey: .customBubbleImageData)
        bubbleRadius = try box.decodeIfPresent(Double.self, forKey: .bubbleRadius) ?? bubbleRadius
        bubbleColor = try box.decodeIfPresent(UInt32.self, forKey: .bubbleColor)
        godRadius = try box.decodeIfPresent(Double.self, forKey: .godRadius) ?? godRadius
        godBackground = try box.decodeIfPresent(UInt32.self, forKey: .godBackground)
        godBorder = try box.decodeIfPresent(UInt32.self, forKey: .godBorder)
        bubbleFollowsTheme = try box.decodeIfPresent(Bool.self, forKey: .bubbleFollowsTheme) ?? bubbleFollowsTheme
        godFollowsTheme = try box.decodeIfPresent(Bool.self, forKey: .godFollowsTheme) ?? godFollowsTheme
        themeGodStyle = try box.decodeIfPresent(String.self, forKey: .themeGodStyle)
        normalize()
    }
}

struct ReaderColors: Codable, Equatable {
    var background: UInt32
    var ink: UInt32
    var accent: UInt32
    var name: String
    var dark: Bool = false
}

/// Positions are element centres in percentages of a reserved header or footer zone.
struct ReaderPageElement: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var zone = "header"
    var kind = "书名"
    var text = ""
    var x: Double = 50
    var y: Double = 50
    var width: Double = 40
    var fontSize: Double = 11
    var color: UInt32? = nil

    static let defaults = [
        ReaderPageElement(id: "header-book", kind: "书名", x: 28, y: 45, width: 46),
        ReaderPageElement(id: "header-time", kind: "时间", x: 82, y: 45, width: 26),
        ReaderPageElement(id: "footer-chapter", zone: "footer", kind: "章节", x: 23, width: 36),
        ReaderPageElement(id: "footer-progress", zone: "footer", kind: "进度", x: 68, width: 54)
    ]

    func constrained(headerHeight: Double, footerHeight: Double) -> ReaderPageElement {
        var result = self
        if !["header", "footer"].contains(result.zone) { result.zone = "header" }
        if !["书名", "章节", "时间", "进度", "自定义文字"].contains(result.kind) { result.kind = "自定义文字" }
        result.width = ReaderPreferenceBounds.clamp(width, 15...90, fallback: 40)
        result.fontSize = ReaderPreferenceBounds.clamp(fontSize, 9...22, fallback: 11)
        let zoneHeight = max(48, ReaderPreferenceBounds.clamp(result.zone == "footer" ? footerHeight : headerHeight, 48...140, fallback: 64))
        let halfHeight = min(50, max(28, result.fontSize + 12) / zoneHeight * 50)
        result.x = ReaderPreferenceBounds.clamp(x, result.width / 2 ... 100 - result.width / 2, fallback: 50)
        result.y = ReaderPreferenceBounds.clamp(y, halfHeight ... 100 - halfHeight, fallback: 50)
        if let color { result.color = color & 0xFFFFFF }
        return result
    }
}

struct ReaderStyleRule: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var match = "对话引号"
    var pattern = ""
    var presentation = "文字高亮"
    var color: UInt32 = 0x8F5442
    var enabled = false
    var scope = "全部书籍"

    static let templates = [
        ReaderStyleRule(id: "dialogue", name: "人物对话"),
        ReaderStyleRule(id: "system", name: "系统消息", match: "系统提示", presentation: "段落底色", color: 0x667E67),
        ReaderStyleRule(id: "poetry", name: "诗词", match: "诗词段落", presentation: "居中斜体", color: 0x876846),
        ReaderStyleRule(id: "drop-cap", name: "章节首字下沉", match: "章节首段", presentation: "首字下沉", color: 0x8B6449)
    ]

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderPreferenceError.invalid("请输入规则名称。") }
        guard ["对话引号", "系统提示", "诗词段落", "章节首段", "正则表达式", "关键词"].contains(match) else { throw ReaderPreferenceError.invalid("不支持的匹配方式。") }
        guard ["文字高亮", "段落底色", "居中斜体", "首字下沉"].contains(presentation) else { throw ReaderPreferenceError.invalid("不支持的呈现方式。") }
        guard ["全部书籍", "当前书籍", "当前书源"].contains(scope) else { throw ReaderPreferenceError.invalid("不支持的规则作用范围。") }
        if match == "正则表达式" || match == "关键词" {
            guard !pattern.isEmpty else { throw ReaderPreferenceError.invalid("请输入匹配内容。") }
            guard pattern.utf16.count <= 512 else { throw ReaderPreferenceError.invalid("规则超过 512 个字符，请精简后重试。") }
        }
        if match == "正则表达式" { _ = try NSRegularExpression(pattern: pattern) }
    }

    func ranges(in text: String) throws -> [NSRange] {
        try validate()
        guard !text.isEmpty, scope == "全部书籍" else { return [] }
        if match == "章节首段" { return [(text as NSString).rangeOfComposedCharacterSequence(at: 0)] }
        let source: String
        switch match {
        case "对话引号": source = "“[^”\\n]+”|「[^」\\n]+」|『[^』\\n]+』|\"[^\"\\n]+\""
        case "系统提示": source = "【(?:系统|提示)[^】]*】|\\[(?:系统|提示)[^\\]]*\\]|(?m)^(?:系统|提示)[：:].+$"
        case "诗词段落": source = "[\\p{Han}]{5,7}[，,][\\p{Han}]{5,7}[。！？!?]"
        case "关键词": source = NSRegularExpression.escapedPattern(for: pattern)
        default: source = pattern
        }
        let regex = try NSRegularExpression(pattern: source)
        var matches: [NSRange] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.03
        var timedOut = false
        regex.enumerateMatches(in: text, options: .reportProgress, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            if ProcessInfo.processInfo.systemUptime > deadline { timedOut = true; stop.pointee = true; return }
            if let range = match?.range, range.length > 0 { matches.append(range) }
        }
        if timedOut { throw ReaderPreferenceError.invalid("规则匹配耗时过长，请精简表达式。") }
        return matches
    }
}

enum ReaderPreferenceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

enum ReaderPreferenceBounds {
    static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(range.lowerBound, value), range.upperBound) : min(max(range.lowerBound, fallback), range.upperBound)
    }
}

/// Native subset used by both the chapter editor preview and ReaderDocument.
/// Unsupported declarations fail visibly instead of silently producing a different style.
struct ReaderTitleStyle: Equatable {
    var fontSize: Double = 26
    var alignment = "left"
    var color: UInt32? = nil
    var background: UInt32? = nil
    var tracking: Double = 0
    var spacingBefore: Double = 0
    var spacingAfter: Double = 15
    var underline = false
    var fontWeight = "medium"

    static func parse(css: String?, accent: UInt32) throws -> ReaderTitleStyle {
        guard let css, !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .init() }
        guard css.utf8.count <= 60_000 else { throw ReaderPreferenceError.invalid("章节 CSS 超过 60 KB。") }
        let comments = try NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
        let clean = comments.stringByReplacingMatches(in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try NSRegularExpression(pattern: "^\\.chapter-title\\s*\\{([^{}]*)\\}\\s*$", options: .dotMatchesLineSeparators)
        let input = clean as NSString
        guard let match = expression.firstMatch(in: clean, range: NSRange(location: 0, length: input.length)) else {
            throw ReaderPreferenceError.invalid("原生阅读器目前支持 .chapter-title { … }，暂不支持伪元素或其他选择器。")
        }
        var style = ReaderTitleStyle()
        for part in input.substring(with: match.range(at: 1)).split(separator: ";") {
            if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let colon = part.firstIndex(of: ":") else { throw ReaderPreferenceError.invalid("CSS 属性缺少冒号。") }
            let key = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.range(of: "url\\s*\\(|expression\\s*\\(|!important|[<>@]", options: [.regularExpression, .caseInsensitive]) == nil else {
                throw ReaderPreferenceError.invalid("请使用本地章节标题的字体、颜色、间距和对齐属性。")
            }
            switch key {
            case "font-size": style.fontSize = try number(value, range: 14...48)
            case "text-align":
                guard ["left", "center", "right", "justify"].contains(value) else { throw ReaderPreferenceError.invalid("标题对齐可选 left、center、right 或 justify。") }
                style.alignment = value
            case "color": style.color = try color(value, accent: accent)
            case "background-color": style.background = try color(value, accent: accent)
            case "letter-spacing": style.tracking = try number(value, range: -2...16)
            case "padding-top": style.spacingBefore = try number(value, range: 0...60)
            case "padding-bottom": style.spacingAfter = try number(value, range: 0...60)
            case "font-weight":
                guard ["normal", "medium", "bold", "100", "200", "300", "400", "500", "600", "700", "800", "900"].contains(value) else { throw ReaderPreferenceError.invalid("不支持的标题字重。") }
                style.fontWeight = value
            case "border-bottom":
                if value == "none" || value == "0" { style.underline = false }
                else {
                    guard value.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:px|pt)\\s+(?:solid|dotted|dashed|double)(?:\\s+.+)?$", options: .regularExpression) != nil else { throw ReaderPreferenceError.invalid("标题下划线请使用 1px solid 色值。") }
                    let width = Double(value.prefix { $0.isNumber || $0 == "." }) ?? 0
                    style.underline = width > 0
                }
            default: throw ReaderPreferenceError.invalid("原生章节标题暂不支持 CSS 属性：\(key)。")
            }
        }
        return style
    }

    private static func number(_ source: String, range: ClosedRange<Double>) throws -> Double {
        let expression = try NSRegularExpression(pattern: "^(-?[0-9]+(?:\\.[0-9]+)?)(?:px|pt)?$")
        let text = source as NSString
        guard let match = expression.firstMatch(in: source, range: NSRange(location: 0, length: text.length)),
              let number = Double(text.substring(with: match.range(at: 1))), range.contains(number) else {
            throw ReaderPreferenceError.invalid("标题数值需在 \(Int(range.lowerBound))–\(Int(range.upperBound)) pt 范围内。")
        }
        return number
    }
    private static func color(_ source: String, accent: UInt32) throws -> UInt32? {
        if ["var(--accent)", "var(--reader-accent)"].contains(source) { return accent & 0xFFFFFF }
        if ["currentColor", "transparent", "var(--ink)", "var(--reader-ink)", "var(--background)", "var(--reader-paper)"].contains(source) { return nil }
        let hex = source.hasPrefix("#") ? String(source.dropFirst()) : ""
        if hex.count == 6, let value = UInt32(hex, radix: 16) { return value }
        if hex.count == 3, hex.allSatisfy({ $0.isHexDigit }), let value = UInt32(hex.map { "\($0)\($0)" }.joined(), radix: 16) { return value }
        throw ReaderPreferenceError.invalid("标题颜色请使用 #RRGGBB、#RGB 或主题颜色变量。")
    }
}
