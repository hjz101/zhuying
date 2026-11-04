import UIKit

struct ReaderAnchor: Equatable {
    var paragraph: Int = 0
    var offset: Int = 0
}

/// Shared UTF-16 text locations let vertical and paged reading restore the same words.
struct ReaderDocument {
    let text: NSAttributedString
    let paragraphRanges: [NSRange]

    init(book: Book, chapter: Int, settings: ReadingSettings) {
        let text = NSMutableAttributedString(string: "")
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacing = 15
        let ink = UIColor(settings.theme.ink)
        text.append(NSAttributedString(string: book.chapterTitle(chapter) + "\n", attributes: [.font: UIFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: ink, .paragraphStyle: heading]))
        let meta = NSMutableParagraphStyle()
        meta.paragraphSpacing = 32
        text.append(NSAttributedString(string: "\(book.author) 著  ·  原创示例章节\n", attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor(settings.theme.secondary), .paragraphStyle: meta]))
        var ranges: [NSRange] = []
        let body = NSMutableParagraphStyle()
        body.lineSpacing = settings.lineSpacing
        body.paragraphSpacing = 22
        body.firstLineHeadIndent = settings.fontSize * 2
        for paragraph in book.content[chapter] {
            ranges.append(NSRange(location: text.length, length: (paragraph as NSString).length))
            text.append(NSAttributedString(string: paragraph + "\n", attributes: [.font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: ink, .paragraphStyle: body, .kern: 0.6]))
        }
        self.text = text
        paragraphRanges = ranges
    }

    func index(for anchor: ReaderAnchor) -> Int {
        guard !paragraphRanges.isEmpty else { return 0 }
        let range = paragraphRanges[min(max(0, anchor.paragraph), paragraphRanges.count - 1)]
        return range.location + min(max(0, anchor.offset), max(0, range.length - 1))
    }

    func anchor(at index: Int) -> ReaderAnchor {
        guard !paragraphRanges.isEmpty else { return .init() }
        let paragraph = paragraphRanges.lastIndex { $0.location <= index } ?? 0
        let range = paragraphRanges[paragraph]
        return ReaderAnchor(paragraph: paragraph, offset: min(max(0, index - range.location), max(0, range.length - 1)))
    }

    func pageText(in range: NSRange) -> NSAttributedString {
        let page = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        // A page beginning in the middle of a paragraph is a continuation, not a new indent.
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
}

@MainActor
enum ReaderPaginator {
    static func ranges(document: ReaderDocument, size: CGSize) -> [NSRange] {
        guard size.width >= 40, size.height >= 40, document.text.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: document.text)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        var result: [NSRange] = []
        var previousEnd = 0
        // Each container represents an actual screen, including the active font and spacing.
        while previousEnd < document.text.length {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { break }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let end = NSMaxRange(characters)
            guard end > previousEnd else { break }
            result.append(NSRange(location: previousEnd, length: end - previousEnd))
            previousEnd = end
        }
        return result
    }

    static func page(containing anchor: ReaderAnchor, document: ReaderDocument, ranges: [NSRange]) -> Int {
        let index = document.index(for: anchor)
        return ranges.lastIndex { $0.location <= index } ?? 0
    }
}

enum ReadingTapAction { case previous, next, controls }
enum ReaderInteraction {
    static func action(at fraction: Double, settings: ReadingSettings) -> ReadingTapAction {
        guard settings.tapToTurn else { return .controls }
        if fraction > 0.3 && fraction < 0.7 { return .controls }
        return .next
    }
}
