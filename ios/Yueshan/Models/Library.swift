import Foundation
import Combine

struct Book: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let genre: String
    let category: String
    let status: String
    let words: String
    let color: String
    let subtitle: String
    let intro: String
    let tags: [String]
    let chapters: [String]
    let content: [[String]]

    func chapterTitle(_ index: Int) -> String {
        guard chapters.indices.contains(index) else { return "章节不可用" }
        if id.hasPrefix("local-") { return chapters[index] }
        let numerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        return "第\(index < numerals.count ? numerals[index] : String(index + 1))章 \(chapters[index])"
    }

    static func load(bundle: Bundle = .main) throws -> [Book] {
        guard let url = bundle.url(forResource: "library", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Book].self, from: Data(contentsOf: url))
    }
}

struct ReadingProgress: Codable, Equatable {
    var chapter: Int
    var paragraph: Int
    var updatedAt: Date
    var characterOffset: Int = 0

    init(chapter: Int, paragraph: Int, updatedAt: Date, characterOffset: Int = 0) {
        self.chapter = chapter; self.paragraph = paragraph
        self.updatedAt = updatedAt; self.characterOffset = characterOffset
    }
    private enum CodingKeys: String, CodingKey { case chapter, paragraph, updatedAt, characterOffset }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        chapter = try box.decode(Int.self, forKey: .chapter)
        paragraph = try box.decode(Int.self, forKey: .paragraph)
        updatedAt = try box.decode(Date.self, forKey: .updatedAt)
        characterOffset = try box.decodeIfPresent(Int.self, forKey: .characterOffset) ?? 0
    }
}

enum ReadingTheme: String, Codable, CaseIterable {
    case paper, light, dark
    var title: String { switch self { case .paper: "暖纸"; case .light: "明亮"; case .dark: "夜读" } }
}

enum ReadingMode: String, Codable, CaseIterable {
    case scroll, paged, verticalPaged
    var title: String { switch self { case .scroll: "上下滚动"; case .paged: "左右翻页"; case .verticalPaged: "上下翻页" } }
    var isPaged: Bool { self != .scroll }
}

enum ShelfSort: String, Codable, CaseIterable {
    case recent, added, title
    var title: String { switch self { case .recent: "最近阅读"; case .added: "加入时间"; case .title: "书名排序" } }
}

enum ShelfLayout: String, CaseIterable {
    case spacious, standard, compact, list, spines
    var title: String {
        switch self {
        case .spacious: "两列 · 大封面"; case .standard: "三列 · 标准"
        case .compact: "四列 · 紧凑"; case .list: "列表"
        case .spines: "书脊与封面"
        }
    }
    var columns: Int {
        switch self { case .spacious: 2; case .standard: 3; case .compact: 4; case .list: 1; case .spines: 5 }
    }
}

struct ShelfSpineRow: Identifiable {
    let books: [Book]
    let featuredID: String?
    var id: String { books.first?.id ?? "" }
}

struct ReadingSettings: Codable, Equatable {
    var fontSize: Double = 20
    var lineSpacing: Double = 12
    var theme: ReadingTheme = .paper
    var mode: ReadingMode = .scroll
    var tapToTurn = false
    var haptics = true
    var preferences: ReaderPreferences = .init()

    private enum CodingKeys: String, CodingKey { case fontSize, lineSpacing, theme, mode, tapToTurn, haptics, preferences }
    init(fontSize: Double = 20, lineSpacing: Double = 12, theme: ReadingTheme = .paper,
         mode: ReadingMode = .scroll, tapToTurn: Bool = false, haptics: Bool = true, preferences: ReaderPreferences = .init()) {
        self.fontSize = fontSize; self.lineSpacing = lineSpacing; self.theme = theme
        self.mode = mode; self.tapToTurn = tapToTurn; self.haptics = haptics; self.preferences = preferences
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try box.decodeIfPresent(Double.self, forKey: .fontSize) ?? 20
        lineSpacing = try box.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 12
        theme = try box.decodeIfPresent(ReadingTheme.self, forKey: .theme) ?? .paper
        mode = try box.decodeIfPresent(ReadingMode.self, forKey: .mode) ?? .scroll
        tapToTurn = try box.decodeIfPresent(Bool.self, forKey: .tapToTurn) ?? false
        haptics = try box.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        preferences = try box.decodeIfPresent(ReaderPreferences.self, forKey: .preferences) ?? .init()
    }
}

struct UpdateNotice: Codable, Equatable {
    var firstChapter: Int
    var readThrough: Int = -1
}

struct ShelfRemoval {
    let entries: [(id: String, index: Int)]
    var count: Int { entries.count }
}

struct LibrarySnapshot: Codable {
    var version = 1
    var favorites: [String]
    var progress: [String: ReadingProgress]
    var settings: ReadingSettings = .init()
    var sort: ShelfSort = .recent
    var updates: [String: UpdateNotice]? = nil
    var hasSeenReadingGuide: Bool? = nil
    var shelfLayout: String? = nil
    var importedGroups: [String: String]? = nil
}

struct ReaderSession: Identifiable {
    let id = UUID()
    let book: Book
    let chapter: Int
}

@MainActor
final class LibraryStore: ObservableObject {
    static let storageKey = "yueshan.ios.demo.v1"
    let isDemo: Bool
    @Published private(set) var books: [Book]
    @Published private(set) var importedGroups: [String: String] = [:]
    @Published private(set) var favorites: [String]
    @Published private(set) var progress: [String: ReadingProgress]
    @Published var settings: ReadingSettings { didSet { persist() } }
    @Published var sort: ShelfSort = .recent { didSet { persist() } }
    @Published var shelfLayout: ShelfLayout = .standard { didSet { persist() } }
    @Published private(set) var updates: [String: UpdateNotice] = [:]
    @Published private(set) var hasSeenReadingGuide = false
    @Published var reader: ReaderSession?
    @Published var storageMessage: String?
    private let defaults: UserDefaults
    private let importsURL: URL?
    private var importedBooks: [Book] = []

    init(books: [Book], defaults: UserDefaults = .standard, importsURL: URL? = nil, seedDemoData: Bool = true) {
        self.isDemo = seedDemoData
        self.books = books
        self.defaults = defaults
        self.importsURL = importsURL
        favorites = seedDemoData ? Array(books.prefix(6)).map(\.id) : []
        let now = Date()
        let initial: [(String, Int, Double)] = seedDemoData ? [("changfeng", 2, 3600), ("stars", 1, 86400), ("sunset", 3, 172800)] : []
        progress = Dictionary(uniqueKeysWithValues: initial.compactMap { id, chapter, seconds in
            guard let book = books.first(where: { $0.id == id }), book.chapters.indices.contains(chapter) else { return nil }
            return (id, ReadingProgress(chapter: chapter, paragraph: 0, updatedAt: now.addingTimeInterval(-seconds)))
        })
        settings = .init()
        updates = seedDemoData ? Dictionary(uniqueKeysWithValues: books.filter { $0.status == "连载中" }.map { ($0.id, UpdateNotice(firstChapter: max(0, $0.chapters.count - 3))) }) : [:]
        if let importsURL, FileManager.default.fileExists(atPath: importsURL.path) {
            do {
                let saved = try JSONDecoder().decode([Book].self, from: Data(contentsOf: importsURL))
                var ids = Set(books.map(\.id))
                importedBooks = saved.filter { book in
                    book.id.hasPrefix("local-") && !book.chapters.isEmpty && book.chapters.count == book.content.count &&
                    book.content.allSatisfy { !$0.isEmpty && $0.allSatisfy { !$0.isEmpty } } && ids.insert(book.id).inserted
                }
                self.books.append(contentsOf: importedBooks)
            } catch { storageMessage = "本地导入书库读取失败，请保留原文件后重试。" }
        }
        let books = self.books
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            // Add defaults to old v1 snapshots before decoding the expanded schema.
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if object["sort"] == nil { object["sort"] = ShelfSort.recent.rawValue }
            let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            guard snapshot.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            hasSeenReadingGuide = snapshot.hasSeenReadingGuide ?? false
            var seen = Set<String>()
            let ids = Set(books.map(\.id))
            importedGroups = (snapshot.importedGroups ?? [:]).filter { ids.contains($0.key) }
            favorites = snapshot.favorites.filter { ids.contains($0) && seen.insert($0).inserted }
            progress = snapshot.progress.reduce(into: [:]) { result, entry in
                guard let book = books.first(where: { $0.id == entry.key }), !book.chapters.isEmpty else { return }
                let chapter = min(max(0, entry.value.chapter), book.chapters.count - 1)
                let count = book.content.indices.contains(chapter) ? book.content[chapter].count : 0
                let paragraph = min(max(0, entry.value.paragraph), max(0, count - 1))
                let length = count > 0 ? (book.content[chapter][paragraph] as NSString).length : 0
                result[entry.key] = ReadingProgress(chapter: chapter, paragraph: paragraph, updatedAt: entry.value.updatedAt, characterOffset: min(max(0, entry.value.characterOffset), max(0, length - 1)))
            }
            sort = snapshot.sort
            shelfLayout = ShelfLayout(rawValue: snapshot.shelfLayout ?? "") ?? .standard
            if let savedUpdates = snapshot.updates {
                updates = savedUpdates.filter { ids.contains($0.key) }.mapValues { UpdateNotice(firstChapter: max(0, $0.firstChapter), readThrough: max(-1, $0.readThrough)) }
            }
            settings = snapshot.settings
            settings.fontSize = ReaderPreferenceBounds.clamp(settings.fontSize, 14...30, fallback: 20)
            settings.lineSpacing = ReaderPreferenceBounds.clamp(settings.lineSpacing, 0...24, fallback: 12)
            settings.preferences.normalize()
        } catch {
            storageMessage = seedDemoData ? "本地记录暂时无法读取，已载入示例书架。" : "本地记录暂时无法读取，原始记录已保留，请稍后重试。"
        }
    }

    var shelf: [Book] {
        favorites.compactMap { id in books.first { $0.id == id } }.sorted { a, b in
            if sort == .added { return (favorites.firstIndex(of: a.id) ?? 0) < (favorites.firstIndex(of: b.id) ?? 0) }
            if sort == .title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            switch (progress[a.id], progress[b.id]) {
            case let (a?, b?): return a.updatedAt > b.updatedAt
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (favorites.firstIndex(of: a.id) ?? 0) < (favorites.firstIndex(of: b.id) ?? 0)
            }
        }
    }

    /// Preserve the active sort while reserving two spine slots for one visible cover.
    func spineRows(for visibleBooks: [Book], columns: Int) -> [ShelfSpineRow] {
        guard var featured = visibleBooks.first else { return [] }
        for book in visibleBooks.dropFirst() {
            guard let candidate = progress[book.id] else { continue }
            if progress[featured.id].map({ candidate.updatedAt > $0.updatedAt }) ?? true {
                featured = book
            }
        }

        let capacity = max(3, columns)
        var rows: [ShelfSpineRow] = []
        var rowBooks: [Book] = []
        var occupiedSlots = 0
        for book in visibleBooks {
            let slots = book.id == featured.id ? 2 : 1
            if occupiedSlots + slots > capacity {
                rows.append(ShelfSpineRow(books: rowBooks, featuredID: rowBooks.contains { $0.id == featured.id } ? featured.id : nil))
                rowBooks = []
                occupiedSlots = 0
            }
            rowBooks.append(book)
            occupiedSlots += slots
        }
        if !rowBooks.isEmpty {
            rows.append(ShelfSpineRow(books: rowBooks, featuredID: rowBooks.contains { $0.id == featured.id } ? featured.id : nil))
        }
        return rows
    }

    var history: [Book] {
        books.filter { progress[$0.id] != nil }.sorted {
            let a = progress[$0.id]!.updatedAt, b = progress[$1.id]!.updatedAt
            return a == b ? $0.id < $1.id : a > b
        }
    }
    var recent: Book? { history.first { favorites.contains($0.id) } }
    var updatedBooks: [Book] { shelf.filter { updateCount($0) > 0 } }
    func updateCount(_ book: Book) -> Int {
        guard let notice = updates[book.id] else { return 0 }
        return max(0, book.chapters.count - max(notice.firstChapter, notice.readThrough + 1))
    }
    func simulateUpdates() {
        guard isDemo else { return }
        for book in books where book.status == "连载中" {
            updates[book.id] = UpdateNotice(firstChapter: max(0, book.chapters.count - 3))
        }
        persist()
    }
    func removeFavorites(_ ids: Set<String>) -> ShelfRemoval {
        let receipt = ShelfRemoval(entries: favorites.enumerated().filter { ids.contains($0.element) }.map { ($0.element, $0.offset) })
        favorites.removeAll { ids.contains($0) }
        persist()
        return receipt
    }
    func undoRemoval(_ receipt: ShelfRemoval) {
        for entry in receipt.entries.sorted(by: { $0.index < $1.index }) where !favorites.contains(entry.id) {
            favorites.insert(entry.id, at: min(entry.index, favorites.count))
        }
        persist()
    }
    var readingCount: Int { shelf.filter { progress[$0.id] != nil }.count }
    func isFavorite(_ book: Book) -> Bool { favorites.contains(book.id) }

    func search(_ query: String, category: String = "全部") -> [Book] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { book in
            (category == "全部" || book.category == category) &&
            (key.isEmpty || book.title.localizedCaseInsensitiveContains(key) || book.author.localizedCaseInsensitiveContains(key))
        }
    }

    @discardableResult
    func toggleFavorite(_ book: Book) -> Bool {
        guard books.contains(where: { $0.id == book.id }) else { return false }
        if favorites.contains(book.id) { favorites.removeAll { $0 == book.id } }
        else { favorites.insert(book.id, at: 0) }
        persist()
        return isFavorite(book)
    }

    func percent(_ book: Book) -> Int {
        guard let value = progress[book.id], !book.chapters.isEmpty else { return 0 }
        let count = max(1, book.content[value.chapter].count)
        return min(99, Int((Double(value.chapter) + Double(value.paragraph) / Double(count)) / Double(book.chapters.count) * 100))
    }

    @discardableResult
    func record(_ book: Book, chapter: Int, paragraph: Int = 0, characterOffset: Int = 0, now: Date = Date()) -> Bool {
        guard books.contains(where: { $0.id == book.id }), book.chapters.indices.contains(chapter), book.content.indices.contains(chapter) else { return false }
        let paragraph = min(max(0, paragraph), max(0, book.content[chapter].count - 1))
        let length = (book.content[chapter][paragraph] as NSString).length
        progress[book.id] = .init(chapter: chapter, paragraph: paragraph, updatedAt: now, characterOffset: min(max(0, characterOffset), max(0, length - 1)))
        if var notice = updates[book.id], chapter >= notice.firstChapter {
            notice.readThrough = max(notice.readThrough, chapter)
            updates[book.id] = notice
        }
        persist()
        return true
    }

    func read(_ book: Book, chapter: Int? = nil) {
        let target = chapter ?? progress[book.id]?.chapter ?? 0
        guard book.chapters.indices.contains(target) else { return }
        let paragraph = progress[book.id]?.chapter == target ? progress[book.id]?.paragraph ?? 0 : 0
        record(book, chapter: target, paragraph: paragraph, characterOffset: progress[book.id]?.chapter == target ? progress[book.id]?.characterOffset ?? 0 : 0)
        reader = ReaderSession(book: book, chapter: target)
    }

    func completeReadingGuide() {
        guard !hasSeenReadingGuide else { return }
        hasSeenReadingGuide = true
        persist()
    }

    func moveImportedBook(_ id: String, group: String) {
        guard importedBooks.contains(where: { $0.id == id }) else { return }
        importedGroups[id] = group; persist()
    }

    @discardableResult
    func importBook(_ book: Book, group: String = "未分组") throws -> Bool {
        guard !books.contains(where: { $0.id == book.id }) else { return false }
        guard book.id.hasPrefix("local-"), !book.chapters.isEmpty, book.chapters.count == book.content.count,
              book.content.allSatisfy({ !$0.isEmpty && $0.allSatisfy { !$0.isEmpty } }) else { throw CocoaError(.fileReadCorruptFile) }
        let additions = importedBooks + [book]
        if let importsURL {
            try FileManager.default.createDirectory(at: importsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(additions).write(to: importsURL, options: .atomic)
        }
        importedBooks = additions; books.append(book); favorites.insert(book.id, at: 0)
        importedGroups[book.id] = group
        persist()
        return true
    }

    func persist() {
        do {
            let snapshot = LibrarySnapshot(favorites: favorites, progress: progress, settings: settings, sort: sort, updates: updates, hasSeenReadingGuide: hasSeenReadingGuide, shelfLayout: shelfLayout.rawValue, importedGroups: importedGroups)
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.storageKey)
        } catch {
            storageMessage = "阅读记录保存失败，请稍后重试。"
        }
    }
}
