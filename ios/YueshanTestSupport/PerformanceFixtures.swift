import Foundation
@testable import Yueshan

struct PerformanceBudget: Codable {
    struct Scales: Codable {
        let shelfBooks: Int
        let catalogChapters: Int
        let longBookChapters: Int
        let longBookParagraphsPerChapter: Int
        let longBookParagraphUTF16: Int
        let longChapterParagraphs: Int
        let longChapterParagraphUTF16: Int
    }
    let schemaVersion: Int
    let frozenAt: String
    let profile: String
    let samples: Int
    let storageSamples: Int
    let scales: Scales
    let limits: [String: Double]
    static func load(bundle: Bundle) throws -> (Self, Data) {
        guard let url = bundle.url(forResource: "performance-budget", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(Self.self, from: data), data)
    }
}

enum PerformanceFixtures {
    // Original prose, combining marks, surrogate pairs, ZWJ, flags, RTL, CJK
    // extensions, Latin and punctuation. No third-party novels are bundled.
    static let unicode = "山间来信：读者👩🏽‍🚀与家人👨‍👩‍👧‍👦看见星光。e\u{301} / café / 𠮷 / 🇨🇳 / مرحبا / 12345，‘保留文字位置’。"
    static func paragraph(index: Int, minimumUTF16: Int) -> String {
        var text = "段落 \(index)："
        while text.utf16.count < minimumUTF16 { text += unicode }
        return text
    }
    static func book(id: String, chapters: Int, paragraphs: Int, paragraphUTF16: Int) -> Book {
        Book(id: "local-performance-\(id)", title: "原创性能样本 \(id)", author: "阅山测试", genre: "本地书籍", category: "其他", status: "已完结", words: "测试规模", color: "sage", subtitle: "性能样本", intro: "原创可重复测试数据", tags: ["测试"],
             chapters: (0..<chapters).map { "第\($0 + 1)章 山间来信" },
             content: (0..<chapters).map { chapter in (0..<paragraphs).map { paragraph(index: chapter * paragraphs + $0, minimumUTF16: paragraphUTF16) } })
    }
    static func metadata(_ index: Int) -> LibraryBookRecord {
        .init(id: "performance-\(index)", title: "原创样本 \(index)", author: "阅山测试", summary: "书架负载样本", addedAt: Date(timeIntervalSince1970: Double(index)))
    }
    static func catalog(bookID: String, count: Int) -> [ChapterRecord] {
        (0..<count).map { .init(id: "\(bookID)-chapter-\($0)", bookID: bookID, nativeChapterID: "\($0)", title: "第\($0 + 1)章 原创样本", order: $0, access: .readable) }
    }
}
