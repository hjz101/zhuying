import UIKit
import CoreText

struct ReaderAnchor: Equatable {
    var paragraph: Int = 0
    var offset: Int = 0
}

struct ReaderPalette {
    let background: UIColor
    let ink: UIColor
    let accent: UIColor
    var secondary: UIColor { ink.withAlphaComponent(0.62) }
    var hexAccent: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0x4F4B3D }
        return UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
    }
    init(settings: ReadingSettings) {
        if let colors = settings.preferences.colors {
            background = UIColor(readerHex: colors.background)
            ink = UIColor(readerHex: colors.ink)
            accent = UIColor(readerHex: colors.accent)
        } else {
            background = UIColor(settings.theme.background)
            ink = UIColor(settings.theme.ink)
            accent = ink
        }
    }
}

extension UIColor {
    convenience init(readerHex value: UInt32) {
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Furniture consumes a stable reserved region; hiding the reader controls does not change it.
struct ReaderLayout {
    let textFrame: CGRect
    let scrollFrame: CGRect
    let scrollInsets: UIEdgeInsets
    let headerFrame: CGRect
    let footerFrame: CGRect
    init(settings: ReadingSettings, size: CGSize) {
        let p = settings.preferences
        let availableWidth = max(40, size.width)
        let marginTotal = max(0, p.leftMargin) + max(0, p.rightMargin)
        let horizontalScale = marginTotal > availableWidth - 40 ? max(0, availableWidth - 40) / max(1, marginTotal) : 1
        let left = max(0, p.leftMargin) * horizontalScale, right = max(0, p.rightMargin) * horizontalScale
        let availableHeight = max(40, size.height)
        let title = try? ReaderTitleStyle.parse(css: p.effectiveTitleCSS, accent: ReaderPalette(settings: settings).hexAccent)
        let minimumBody = min(availableHeight, max(80, settings.fontSize + settings.lineSpacing + 16,
                                                  (title?.fontSize ?? 26) * 1.4 + (title?.spacingBefore ?? 0) + 8))
        let top = min(max(0, p.topMargin), max(0, (availableHeight - minimumBody) / 2))
        let bottom = min(max(0, p.bottomMargin), max(0, availableHeight - top - minimumBody))
        let rawHeader = p.headerEnabled ? p.headerHeight + p.headerGap : 0
        let rawFooter = p.footerEnabled ? p.footerHeight + p.footerGap : 0
        let total = max(0, rawHeader) + max(0, rawFooter)
        let verticalScale = total > availableHeight - top - bottom - minimumBody ? max(0, availableHeight - top - bottom - minimumBody) / max(1, total) : 1
        let headerReserved = max(0, rawHeader) * verticalScale, footerReserved = max(0, rawFooter) * verticalScale
        let width = max(40, availableWidth - left - right)
        textFrame = CGRect(x: left, y: top + headerReserved, width: width,
                           height: max(40, availableHeight - top - bottom - headerReserved - footerReserved))
        scrollFrame = CGRect(x: 0, y: headerReserved, width: availableWidth,
                             height: max(40, availableHeight - headerReserved - footerReserved))
        scrollInsets = UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        headerFrame = CGRect(x: left, y: top, width: width, height: p.headerEnabled ? p.headerHeight * verticalScale : 0)
        footerFrame = CGRect(x: left, y: availableHeight - bottom - (p.footerEnabled ? p.footerHeight * verticalScale : 0), width: width,
                             height: p.footerEnabled ? p.footerHeight * verticalScale : 0)
    }
}

extension NSAttributedString.Key {
    static let readerCommentParagraph = NSAttributedString.Key("readerCommentParagraph")
}

/// Shared UTF-16 text locations only describe original prose, never generated commentary.
struct ReaderDocument {
    let text: NSAttributedString
    let paragraphRanges: [NSRange]

    init(book: Book, chapter: Int, settings: ReadingSettings, paragraphs: [String]? = nil, isDemo: Bool = true) {
        let text = NSMutableAttributedString(string: "")
        let preferences = settings.preferences
        let palette = ReaderPalette(settings: settings)
        let title = (try? ReaderTitleStyle.parse(css: preferences.titleCSS ?? preferences.themeTitleCSS,
                                               accent: palette.hexAccent))
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = title?.spacingBefore ?? 0
        heading.paragraphSpacing = title?.spacingAfter ?? 15
        switch title?.alignment ?? "left" {
        case "center": heading.alignment = .center
        case "right": heading.alignment = .right
        case "justify": heading.alignment = .justified
        default: heading.alignment = .left
        }
        let headingBase = UIFont.systemFont(ofSize: title?.fontSize ?? 26, weight: ReaderTypography.weight(title?.fontWeight ?? "medium"))
        let headingFont = headingBase.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: headingBase.pointSize) } ?? headingBase
        var headingAttributes: [NSAttributedString.Key: Any] = [
            .font: headingFont,
            .foregroundColor: title?.color.map { UIColor(readerHex: $0) } ?? palette.ink,
            .paragraphStyle: heading, .kern: title?.tracking ?? 0
        ]
        if let value = title?.background { headingAttributes[.backgroundColor] = UIColor(readerHex: value) }
        if title?.underline == true { headingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        text.append(NSAttributedString(string: book.chapterTitle(chapter) + "\n", attributes: headingAttributes))
        let meta = NSMutableParagraphStyle(); meta.paragraphSpacing = 32
        let attribution = isDemo ? "原创示例章节" : (book.subtitle == "PDF" ? "PDF 文字提取" : "本地正文")
        text.append(NSAttributedString(string: "\(book.author) 著  ·  \(attribution)\n", attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: palette.secondary, .paragraphStyle: meta]))
        var ranges: [NSRange] = []
        let font = ReaderTypography.font(settings: settings)
        for (paragraphIndex, paragraph) in (paragraphs ?? book.content[safe: chapter] ?? []).enumerated() {
            ranges.append(NSRange(location: text.length, length: (paragraph as NSString).length))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = settings.lineSpacing
            style.paragraphSpacing = preferences.paragraphSpacing
            style.firstLineHeadIndent = preferences.firstLineIndent ? settings.fontSize * 2 : 0
            let body = NSMutableAttributedString(string: paragraph, attributes: [.font: font, .foregroundColor: palette.ink, .paragraphStyle: style, .kern: 0.6])
            ReaderTypography.applyRules(preferences.rules, to: body, paragraph: paragraphIndex, settings: settings)
            text.append(body)
            if isDemo && preferences.showCommentBubbles {
                let attachment = ReaderResponsiveCommentAttachment()
                attachment.image = ReaderCommentArtwork.bubble(settings: settings)
                attachment.bounds = CGRect(x: 3, y: -3, width: 42, height: 22)
                let badge = NSMutableAttributedString(attachment: attachment)
                badge.addAttribute(.readerCommentParagraph, value: paragraphIndex, range: NSRange(location: 0, length: badge.length))
                text.append(badge)
            }
            text.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
            if isDemo && preferences.showGodComments {
                let attachment = ReaderResponsiveCommentAttachment()
                attachment.image = ReaderCommentArtwork.godComment(settings: settings)
                attachment.bounds = CGRect(x: 0, y: -2, width: 180, height: 47)
                let card = NSMutableAttributedString(attachment: attachment)
                card.addAttribute(.readerCommentParagraph, value: paragraphIndex, range: NSRange(location: 0, length: card.length))
                text.append(card)
                let spacing = NSMutableParagraphStyle(); spacing.paragraphSpacing = preferences.paragraphSpacing
                text.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 5), .paragraphStyle: spacing]))
            }
        }
        self.text = text
        paragraphRanges = ranges
    }

    func index(for anchor: ReaderAnchor) -> Int {
        guard !paragraphRanges.isEmpty else { return 0 }
        let range = paragraphRanges[min(max(0, anchor.paragraph), paragraphRanges.count - 1)]
        return ReadingAnchor.safeOffset(range.location + min(max(0, anchor.offset), max(0, range.length - 1)), in: text.string as NSString)
    }

    func anchor(at index: Int) -> ReaderAnchor {
        guard !paragraphRanges.isEmpty else { return .init() }
        let paragraph = paragraphRanges.lastIndex { $0.location <= index } ?? 0
        let range = paragraphRanges[paragraph]
        let bounded = range.location + min(max(0, index - range.location), max(0, range.length - 1))
        return ReaderAnchor(paragraph: paragraph, offset: ReadingAnchor.safeOffset(bounded, in: text.string as NSString) - range.location)
    }

    func pageText(in range: NSRange) -> NSAttributedString {
        let page = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        if range.location > 0, range.length > 0,
           (text.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) != "\n",
           let style = page.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let continuation = style.mutableCopy() as? NSMutableParagraphStyle {
            continuation.firstLineHeadIndent = 0
            let firstParagraph = (page.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            page.addAttribute(.paragraphStyle, value: continuation, range: firstParagraph)
        }
        return page
    }

    static func comment(at point: CGPoint, text: NSAttributedString, size: CGSize) -> Int? {
        guard text.length > 0, size.width > 0, size.height > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: size); container.lineFragmentPadding = 0
        manager.addTextContainer(container); manager.ensureLayout(for: container)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -5, dy: -5).contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        return text.attribute(.readerCommentParagraph, at: index, effectiveRange: nil) as? Int
    }
}

final class ReaderResponsiveCommentAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = min(bounds.width, max(1, lineFrag.width))
        return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height * width / max(1, bounds.width))
    }
}

enum ReaderTypography {
    static func weight(_ value: String) -> UIFont.Weight {
        switch value {
        case "100": return .ultraLight
        case "200": return .thin
        case "300", "细体": return .light
        case "500", "medium", "中等": return .medium
        case "600": return .semibold
        case "700", "bold", "粗体": return .bold
        case "800": return .heavy
        case "900": return .black
        default: return .regular
        }
    }
    static func font(settings: ReadingSettings) -> UIFont {
        let weight = weight(settings.preferences.fontWeight)
        if settings.preferences.fontName == "__serif__", let descriptor = UIFont.systemFont(ofSize: settings.fontSize, weight: weight).fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: settings.fontSize)
        }
        if let name = settings.preferences.fontName, let font = UIFont(name: name, size: settings.fontSize) {
            if let digest = settings.preferences.fontResourceHash {
                if let url = CTFontCopyAttribute(CTFontCreateWithName(name as CFString, settings.fontSize, nil), kCTFontURLAttribute) as? URL,
                   url.lastPathComponent == digest + ".font", let data = try? Data(contentsOf: url), FileResourceStore.digest(data) == digest { return font }
            } else { return font }
        }
        return UIFont.systemFont(ofSize: settings.fontSize, weight: weight)
    }
    static func applyRules(_ rules: [ReaderStyleRule], to text: NSMutableAttributedString, paragraph: Int, settings: ReadingSettings) {
        var claimed = IndexSet()
        for rule in rules where rule.enabled {
            if rule.match == "章节首段" && paragraph != 0 { continue }
            guard let ranges = try? rule.ranges(in: text.string) else { continue }
            for range in ranges where range.length > 0 && NSMaxRange(range) <= text.length {
                if rule.presentation == "首字下沉" {
                    let first = (text.string as NSString).rangeOfComposedCharacterSequence(at: 0)
                    text.addAttributes([.font: font(settings: settings).withSize(settings.fontSize * 1.9), .foregroundColor: UIColor(readerHex: rule.color), .baselineOffset: -settings.fontSize * 0.3], range: first)
                } else if rule.presentation == "文字高亮" {
                    let remaining = IndexSet(integersIn: range.location..<NSMaxRange(range)).subtracting(claimed)
                    for subrange in remaining.rangeView { text.addAttribute(.foregroundColor, value: UIColor(readerHex: rule.color), range: NSRange(subrange)) }
                    claimed.formUnion(remaining)
                } else if rule.presentation == "段落底色" {
                    text.addAttribute(.backgroundColor, value: UIColor(readerHex: rule.color).withAlphaComponent(0.15), range: range)
                } else if rule.presentation == "居中斜体" {
                    let style = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    style.alignment = .center; style.firstLineHeadIndent = 0
                    text.addAttributes([.paragraphStyle: style, .font: UIFont.italicSystemFont(ofSize: settings.fontSize)], range: range)
                }
            }
        }
    }
}

enum ReaderCommentArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 64; cache.totalCostLimit = 8 * 1024 * 1024; return cache
    }()
    private static func key(_ kind: String, settings: ReadingSettings) -> NSString {
        let p = settings.preferences
        return "\(kind):\(settings.theme.rawValue):\(p.colors != nil):\(p.bubbleColor != nil):\(p.godBackground != nil):\(p.godBorder != nil):\(p.colors?.background ?? 0):\(p.colors?.ink ?? 0):\(p.colors?.accent ?? 0):\(p.bubbleFollowsTheme):\(p.bubbleStyle):\(p.bubbleRadius):\(p.bubbleColor ?? 0):\(p.bubbleImageData?.hashValue ?? 0):\(p.customBubbleImageData?.hashValue ?? 0):\(p.godFollowsTheme):\(p.themeGodStyle ?? ""):\(p.godStyle):\(p.godRadius):\(p.godBackground ?? 0):\(p.godBorder ?? 0)" as NSString
    }
    private static func remember(_ image: UIImage, key: NSString) -> UIImage {
        cache.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)); return image
    }
    static func bubble(settings: ReadingSettings) -> UIImage {
        let key = key("bubble", settings: settings)
        if let cached = cache.object(forKey: key) { return cached }
        let importedData = settings.preferences.bubbleFollowsTheme ? settings.preferences.bubbleImageData : settings.preferences.customBubbleImageData
        if let data = importedData, let image = UIImage(data: data) { return remember(image, key: key) }
        let palette = ReaderPalette(settings: settings)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 42, height: 22)).image { _ in
            let style = settings.preferences.bubbleFollowsTheme ? "胶囊" : settings.preferences.bubbleStyle
            let radius: CGFloat = style == "自定义" ? settings.preferences.bubbleRadius : style == "圆角方形" ? 4 : 10
            let accent = (style == "自定义" ? settings.preferences.bubbleColor : nil).map { UIColor(readerHex: $0) } ?? palette.accent
            let path = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 40, height: 20), cornerRadius: radius)
            if style == "描边" { accent.setStroke(); path.lineWidth = 1; path.stroke() }
            else { accent.withAlphaComponent(0.14).setFill(); path.fill() }
            ("12·例" as NSString).draw(at: CGPoint(x: 7, y: 4), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: accent])
        }
        return remember(image, key: key)
    }
    static func godComment(settings: ReadingSettings) -> UIImage {
        let key = key("god", settings: settings)
        if let cached = cache.object(forKey: key) { return cached }
        let palette = ReaderPalette(settings: settings)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 230, height: 60)).image { _ in
            let rect = CGRect(x: 1, y: 1, width: 228, height: 58)
            let style = settings.preferences.godFollowsTheme ? (settings.preferences.themeGodStyle ?? "纯色") : settings.preferences.godStyle
            let path = UIBezierPath(roundedRect: rect, cornerRadius: style == "自定义" ? settings.preferences.godRadius : style == "画框" ? 1 : 9)
            let fill = (style == "自定义" ? settings.preferences.godBackground : nil).map { UIColor(readerHex: $0) } ?? (style == "液态玻璃" ? UIColor.white.withAlphaComponent(0.25) : palette.accent.withAlphaComponent(0.08))
            let stroke = (style == "自定义" ? settings.preferences.godBorder : nil).map { UIColor(readerHex: $0) } ?? palette.accent.withAlphaComponent(style == "画框" ? 0.75 : 0.2)
            fill.setFill(); path.fill()
            stroke.setStroke(); path.lineWidth = style == "画框" ? 2 : 0.5; path.stroke()
            if style == "画框" { UIBezierPath(rect: rect.insetBy(dx: 4, dy: 4)).stroke() }
            ("神人评论 · 本地示例" as NSString).draw(at: CGPoint(x: 10, y: 9), withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: palette.accent])
            ("这盏茶，怕不是等了整整一章。" as NSString).draw(at: CGPoint(x: 10, y: 29), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: palette.ink])
        }
        return remember(image, key: key)
    }
}

@MainActor
enum ReaderPaginator {
    static func ranges(document: ReaderDocument, size: CGSize) -> [NSRange] {
        guard size.width >= 40, size.height >= 40, document.text.length > 0 else { return [] }
        var result: [NSRange] = []
        var start = 0
        let source = document.text.string as NSString
        let body = document.paragraphRanges.first?.location ?? 0
        let fontSize = (document.text.attribute(.font, at: min(body, document.text.length - 1), effectiveRange: nil) as? UIFont)?.pointSize ?? 20
        let spacing = (document.text.attribute(.paragraphStyle, at: min(body, document.text.length - 1), effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
        let initialWindow = max(512, min(4096, Int(size.width / fontSize * size.height / max(1, fontSize + spacing) * 3)))
        // A bounded text window avoids retaining a text container and glyph
        // graph for every page of a very long chapter. Every page is measured
        // by the same TextKit renderer that displays it, including continuation
        // indentation. Grow the window if the first candidate fits in full.
        while start < document.text.length {
            let range: NSRange = autoreleasepool {
                var window = min(initialWindow, document.text.length - start)
                while true {
                    var end = min(document.text.length, start + window)
                    if end < source.length { end = source.rangeOfComposedCharacterSequence(at: end).location }
                    let candidate = document.pageText(in: NSRange(location: start, length: end - start))
                    let storage = NSTextStorage(attributedString: candidate)
                    let manager = NSLayoutManager(); storage.addLayoutManager(manager)
                    let container = NSTextContainer(size: size); container.lineFragmentPadding = 0
                    manager.addTextContainer(container); manager.ensureLayout(for: container)
                    let glyphs = manager.glyphRange(for: container)
                    let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    if NSMaxRange(characters) < candidate.length || end == document.text.length {
                        return NSRange(location: start, length: NSMaxRange(characters))
                    }
                    window = min(document.text.length - start, window * 2)
                }
            }
            guard range.length > 0 else { break }
            result.append(range); start = NSMaxRange(range)
        }
        return result
    }

    static func page(containing anchor: ReaderAnchor, document: ReaderDocument, ranges: [NSRange]) -> Int {
        // The zero anchor represents a chapter start in both reading modes,
        // including a custom title that may itself occupy more than one page.
        if anchor == ReaderAnchor() { return 0 }
        let index = document.index(for: anchor)
        return ranges.lastIndex { $0.location <= index } ?? 0
    }
}

enum ReadingTapAction { case previous, next, controls }
enum ReaderInteraction {
    static func acceptsPageDrag(_ movement: CGPoint, mode: ReadingMode, selectedLength: Int) -> Bool {
        guard selectedLength == 0 else { return false }
        return mode == .verticalPaged ? abs(movement.y) > abs(movement.x) : abs(movement.x) > abs(movement.y)
    }
    static func action(at fraction: Double, settings: ReadingSettings) -> ReadingTapAction {
        guard settings.tapToTurn else { return .controls }
        if fraction > 0.3 && fraction < 0.7 { return .controls }
        return .next
    }
}
