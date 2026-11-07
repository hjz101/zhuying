#if DEBUG
import Foundation

/// Original text, available only with the isolated UI-test launch flag.
/// Passing these fixtures is never counted as real-source acceptance.
actor OnlineDevelopmentFixtures: DiscoveryBookSource {
    nonisolated let supportsDiscovery = true
    nonisolated let sourceID = "shushan"
    private let filterFixtures: Bool
    private var filterRevision = 0
    private var selections = ["线路": "自动线路", "模式": "小说模式", "频道": "男频", "平台": "全部平台", "字数": "不限字数", "状态": "不限状态", "排序": "热门排序"]
    private let filterNames = ["线路", "模式", "频道", "平台", "字数", "状态", "排序"]
    private let categoryNames = ["热门书单", "编辑推荐", "经典重读", "新作速递", "完结精选", "短篇故事", "都市夜读", "山海奇谈", "历史长卷", "末项书单"]
    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        filterFixtures = arguments.contains("--ui-testing") && arguments.contains("--discovery-filter-fixtures")
    }
    private func choices(for name: String) -> [String] {
        switch name {
        case "线路": return ["自动线路", "备用线路"]
        case "模式": return ["小说模式", "听书模式"]
        case "频道": return ["男频", "女频"]
        case "平台": return selections["频道"] == "女频" ? ["全部平台", "女频原创", "女频精选"] : ["全部平台", "男频原创", "男频精品"]
        case "字数": return ["不限字数", "百万字以上"]
        case "状态": return ["不限状态", "已完结"]
        case "排序": return ["热门排序", "最近更新"]
        default: return []
        }
    }
    func discoveryCategories() async throws -> [SourceDiscoveryCategory] {
        guard filterFixtures else { return [.init(title: "排行榜", request: "rank"), .init(title: "全部", request: "all")] }
        let filters = filterNames.map { name in
            SourceDiscoveryCategory(title: name, request: "", filter: .init(choices: choices(for: name), selectedValue: selections[name] ?? "", action: "fixture-filter:" + name))
        }
        let routes = categoryNames.map { SourceDiscoveryCategory(title: $0, request: "fixture-list/" + $0 + "?revision=\(filterRevision)") }
        return filters + [.init(title: "原创榜单", request: "")] + Array(routes.prefix(5)) + [.init(title: "更多故事", request: "")] + Array(routes.dropFirst(5))
    }
    func applyDiscoveryFilter(category: SourceDiscoveryCategory, value: String) async throws -> SourceDiscoveryFilterResult {
        guard filterFixtures, let filter = category.filter, filter.action == "fixture-filter:" + category.title,
              choices(for: category.title).contains(value) else { throw ContentFailure.invalidResponse }
        selections[category.title] = value
        if category.title == "频道", !choices(for: "平台").contains(selections["平台"] ?? "") { selections["平台"] = "全部平台" }
        filterRevision += 1
        return .init(categories: try await discoveryCategories(), feedback: "已选择" + value)
    }
    func discover(category: String, page: Int) async throws -> BookSearchPage {
        guard filterFixtures else { return try await search(query: category, page: page) }
        let name = String(category.dropFirst("fixture-list/".count).split(separator: "?").first ?? "")
        let id = "remote-discovery-filter-result-\(filterRevision)"
        let summary = filterNames.map { $0 + "：" + (selections[$0] ?? "") }.joined(separator: " · ")
        let book = LibraryBookRecord(id: id, title: "筛选结果 \(filterRevision) · " + name, author: "竹影原创测试", summary: summary,
            source: .init(sourceID: sourceID, nativeBookID: id, provider: "原创筛选来源", bookURL: "https://fixture.invalid/discovery/\(filterRevision)"), addedAt: Date())
        return .init(books: page == 1 ? [book] : [], nextPage: nil)
    }
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
