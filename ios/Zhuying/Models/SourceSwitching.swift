import Foundation

enum SourceChapterMapping {
    static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "^第[零〇一二三四五六七八九十百千万两0-9]+[章回节卷]", with: "", options: .regularExpression)
            .lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    static func suggestion(title: String, order: Int, catalog: [ChapterRecord]) -> Int? {
        let name = normalizedTitle(title)
        guard !name.isEmpty else { return nil }
        let matches = catalog.indices.filter { catalog[$0].access == .readable && normalizedTitle(catalog[$0].title) == name }
        guard matches.count == 1, let index = matches.first, abs(catalog[index].order - order) <= 3 else { return nil }
        return index
    }
    static func anchor(from old: ReadingAnchor?, bookID: String, document: ChapterDocument, allowChapterStart: Bool) throws -> ReadingAnchor {
        if let old, !old.quote.isEmpty {
            var matches: [(Int,Int)] = []
            for (index,paragraph) in document.paragraphs.enumerated() {
                let text = paragraph.text as NSString
                var start = 0
                while start < text.length {
                    let range = text.range(of: old.quote, range: NSRange(location: start,length: text.length - start))
                    if range.location == NSNotFound { break }
                    matches.append((index,range.location + old.offsetInQuote)); start = range.location + max(1,range.length)
                }
            }
            if matches.count == 1, let match = matches.first { return try .init(bookID: bookID,document: document,paragraph: match.0,offset: match.1) }
        }
        guard allowChapterStart else { throw BookImportError.message("新来源的正文位置无法唯一确认，请明确选择章节后从章首继续。原来源与位置保留。") }
        return try .init(bookID: bookID,document: document,paragraph: 0,offset: 0)
    }
}
