import Foundation

extension LibraryBookRecord {
    func presentation(chapters: [ChapterRecord]) -> Book {
        let display = display ?? .init(genre: "网络书籍", category: "其他", status: "以书源为准", words: "未提供",
                                       color: "sage", subtitle: source?.provider ?? "在线来源", tags: ["网络"])
        return .init(id: id, title: title, author: author.isEmpty ? "作者未提供" : author, genre: display.genre,
                     category: display.category, status: display.status, words: display.words, color: display.color,
                     subtitle: display.subtitle, intro: summary.isEmpty ? "书源未提供简介。" : summary, tags: display.tags,
                     chapters: chapters.map(\.title), content: Array(repeating: [], count: chapters.count),media:media,cover:cover)
    }
    func withDisplayMetadata() -> LibraryBookRecord {
        var value = self
        if value.display == nil {
            value.display = .init(genre: "网络书籍", category: "其他", status: "以书源为准", words: "未提供", color: "sage", subtitle: source?.provider ?? "在线来源", tags: ["网络"])
        }
        return value
    }
}
