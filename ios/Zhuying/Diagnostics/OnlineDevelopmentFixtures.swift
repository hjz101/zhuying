#if DEBUG
import Foundation

/// Original text, available only with the isolated UI-test launch flag.
/// Passing these fixtures is never counted as real-source acceptance.
struct OnlineDevelopmentFixtures: DiscoveryBookSource {
    var supportsDiscovery: Bool { true }
    func discoveryCategories() async throws -> [SourceDiscoveryCategory] { [.init(title: "排行榜", request: "rank"), .init(title: "全部", request: "all")] }
    func discover(category: String, page: Int) async throws -> BookSearchPage { try await search(query: category, page: page) }
    let sourceID = "shushan"
    func search(query: String, page: Int) async throws -> BookSearchPage {
        if query == "精准测试" {
            return .init(books: ["精准测试", "无关推荐"].enumerated().map { index, title in
                .init(id: "remote-precision-\(index)", title: title, author: "竹影测试", summary: "原创精准搜索测试", source: .init(sourceID: sourceID, nativeBookID: "precision-\(index)", provider: "测试来源", bookURL: "https://fixture.invalid/precision/\(index)"), addedAt: Date())
            }, nextPage: nil)
        }
        return .init(books: (1...2).map { index in
            .init(id: "remote-ui-fixture-\(index)", title: "原生联调作品\(index)", author: "竹影测试", summary: "用于端到端验证的原创测试正文。",
                  source: .init(sourceID: sourceID, nativeBookID: "fixture-\(index)", provider: "测试来源", bookURL: "https://fixture.invalid/\(index)"), addedAt: Date())
        }, nextPage: nil)
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { book }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] {
        (0..<4).map { .init(id: book.id + "-\($0)", bookID: book.id, nativeChapterID: "\($0)", title: "第\($0 + 1)章 原创联调", order: $0, access: $0 == 3 ? .restricted : .readable) }
    }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        .init(chapterID: chapter.id, paragraphs: ["\(book.title)的\(chapter.title)，原创内容用于验证真实的原生阅读链路。", "不同章节保留独立位置，失败不覆盖先前确认的阅读记录。"])
    }
}
#endif
