import Foundation
import Combine

struct Book: Codable, Identifiable, Hashable, Sendable {
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
    var media: MediaBookReference? = nil
    var cover: ResourceFileReference? = nil

    func metadataOnly() -> Book {
        .init(id: id, title: title, author: author, genre: genre, category: category, status: status, words: words,
              color: color, subtitle: subtitle, intro: intro, tags: tags, chapters: chapters, content: Array(repeating: [], count: chapters.count),media:media,cover:cover)
    }

    func chapterTitle(_ index: Int) -> String {
        guard chapters.indices.contains(index) else { return "章节不可用" }
        if id.hasPrefix("local-") || id.hasPrefix("remote-") { return chapters[index] }
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
    var unreadChapterIDs: [String]? = nil
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
    var groupNames: [String]? = nil
    var activitySessions: [ActivitySession]? = nil
    var subscribedSourceIDs: [String]? = nil
    var narrationSettings: NarrationSettings? = nil
    var narrationAnchor: ReadingAnchor? = nil
    var mediaLocations: [String:MediaReadingLocation]? = nil
    var mediaBookmarks: [MediaBookmark]? = nil
    var userSettingsEdited: Bool? = nil
    var farthestPositions: [String:ReadingAnchor]? = nil
}

struct ReaderSession: Identifiable {
    let id = UUID()
    let book: Book
    let chapter: Int
    var resume = true
    var anchor: ReadingAnchor? = nil
}

enum LibraryLoadState: Equatable { case ready, loading, failed }

@MainActor
final class LibraryStore: ObservableObject {
    static let storageKey = "zhuying.ios.demo.v1"
    let isDemo: Bool
    @Published private(set) var books: [Book]
    @Published private(set) var importedGroups: [String: String] = [:]
    @Published private(set) var favorites: [String]
    @Published private(set) var progress: [String: ReadingProgress]
    @Published var settings: ReadingSettings {
        didSet {
            if productionPersistence != nil {
                let resolved = ReadingStyleResolver.resolve(settings, previous: oldValue)
                // Assigning this property from its own didSet does not invoke
                // didSet again. The normalized value still needs to be saved.
                if resolved != settings { settings = resolved }
            }
            if !suppressPersistence && settings != oldValue { defaults.set(true,forKey:"reader.user-settings-edited.v1") }
            persist()
        }
    }
    @Published private(set) var themeLibrary: ThemeLibrarySnapshot?
    @Published var sort: ShelfSort = .recent { didSet { persist() } }
    @Published var shelfLayout: ShelfLayout = .standard { didSet { persist() } }
    @Published private(set) var updates: [String: UpdateNotice] = [:]
    @Published private(set) var hasSeenReadingGuide = false
    @Published var reader: ReaderSession?
    @Published var storageMessage: String?
    @Published private(set) var loadState: LibraryLoadState = .ready
    @Published private(set) var unresolvedBookIDs: Set<String> = []
    @Published private(set) var bookmarks: [LibraryBookmarkRecord] = []
    @Published private(set) var sources: [DemoSource] = []
    @Published private(set) var onlineRevision = 0
    @Published private(set) var groupNames: [String] = []
    @Published private(set) var activitySessions: [ActivitySession] = []
    @Published private(set) var subscribedSourceIDs: Set<String> = []
    @Published var narrationSettings = NarrationSettings() { didSet { if oldValue != narrationSettings { audioCoordinator?.updateSettings(); persist() } } }
    var narrationAnchor: ReadingAnchor? { didSet { if oldValue != narrationAnchor { persist() } } }
    @Published private(set) var followingNarrationAnchor: ReadingAnchor?
    @Published private(set) var mediaLocations: [String:MediaReadingLocation] = [:]
    @Published private(set) var mediaBookmarks: [MediaBookmark] = []
    private var audioCoordinator: LibraryAudioCoordinator?
    var audio: LibraryAudioCoordinator {
        if let audioCoordinator { return audioCoordinator }
        let value = LibraryAudioCoordinator(library:self); audioCoordinator = value; return value
    }
    private var readingActivityClock = ReadingActivityClock()
    private var activityBookID: String?
    private var activityForeground = true
    private var narrationIsPlaying = false
    private var textIndex: TextSearchIndex?
    private(set) var onlineService: OnlineReadingService?
    private(set) var workspace: LibraryWorkspace?
    private var remoteBooks: [String: LibraryBookRecord] = [:]
    private let defaults: UserDefaults
    private var managedSettingsDirectory: URL { workspace?.root ?? productionPersistence?.storageDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(AppEnvironment().databaseComponent) }
    lazy var cloudSync = RecordSyncController(library:self,directory:managedSettingsDirectory.appendingPathComponent("CloudSync-v1"),defaults:defaults)
    lazy var browserSessions = SourceBrowserSessions(defaults:defaults)
    lazy var networkProfiles = SourceNetworkProfiles(defaults:defaults)
    lazy var backendProfiles = RemoteBackendProfiles(defaults:defaults,vault:ServiceKeychain(service:"com.zhuying.backend." + (ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "tests" : "production")))
    func networkTransport(for source: DemoSource,maximumBytes: Int = 20 * 1024 * 1024) throws -> SourceNetworkTransport {
        let origin = try ShushanClient.host(source.url),profile = try networkProfiles.profile(sourceID:source.id,origin:origin)
        return try SourceNetworkTransport(origin:origin,profile:profile,maximumBytes:maximumBytes)
    }
    func requestTransport(for source: DemoSource,maximumBytes: Int = 20 * 1024 * 1024) throws -> any HTTPTransport {
        let origin = try ShushanClient.host(source.url),profile = try backendProfiles.profile(sourceID:source.id,origin:origin)
        let direct = try networkTransport(for:source,maximumBytes:maximumBytes)
        guard profile.enabled else { return direct }
        guard direct.profile.mode == .system else { throw RemoteBackendError.conflictingRoute }
        return RemoteBackendTransport(sourceID:source.id,origin:origin,profile:profile,key:try backendProfiles.key(sourceID:source.id,origin:origin,profile:profile),direct:direct)
    }
    func sourceTransport(for source: DemoSource,maximumBytes: Int = 20 * 1024 * 1024) throws -> any HTTPTransport {
        BrowserSessionTransport(sourceID:source.id,origin:try ShushanClient.host(source.url),sessions:browserSessions,base:try requestTransport(for:source,maximumBytes:maximumBytes))
    }
    func commentClient(credential: ShushanCredential) -> ShushanCommentsClient? {
        guard let source = sources.first(where:{$0.id == "shushan" && $0.enabled}),let host = try? ShushanClient.host(source.url),host == credential.host,let transport = try? sourceTransport(for:source,maximumBytes:2 * 1024 * 1024) else { return nil }
        return .init(credential:credential,transport:ResilientSourceTransport(base:transport))
    }
    private var processingStore: ContentProcessingStore?
    var contentProcessor: ContentProcessingStore {
        if let processingStore { return processingStore }
        let root = productionPersistence?.storageDirectory ?? managedSettingsDirectory
        let store = ContentProcessingStore(directory:root.appendingPathComponent("resources/processing")); processingStore = store; return store
    }
    private let importsURL: URL?
    private var importedBooks: [Book] = []
    private var productionPersistence: ProductionLibraryPersistence?
    private let productionFactory: (() throws -> ProductionLibraryPersistence)?
    private var usesProductionStorage: Bool { productionPersistence != nil || productionFactory != nil }
    private var suppressPersistence = false
    private var bootstrapStarted = false
    private var pendingSave: Task<Void, Never>?
    private var writeTail: Task<Void, Never>?
    private var saveQueued = false
    private var hasPendingChanges = false
    private var changeRevision = 0
    private var queueRevision = 0
    private var lastWriteFailed = false
    private var lastWriteMessage: String?
    private var appearancePreparation: (() throws -> AppearanceMigrationInput)?
    private var chapterCatalogs: [String: [ChapterRecord]] = [:]
    private var stableProgress: [String: ReadingAnchor] = [:]
    private var farthestPositions: [String:ReadingAnchor] = [:]
    private var activeDocuments = ChapterMemoryCache()

    init(books: [Book], defaults: UserDefaults = .standard, importsURL: URL? = nil, seedDemoData: Bool = true,
         productionPersistence: ProductionLibraryPersistence? = nil,
         productionFactory: (() throws -> ProductionLibraryPersistence)? = nil, onlineService: OnlineReadingService? = nil, workspace: LibraryWorkspace? = nil) {
        self.productionPersistence = productionPersistence
        self.productionFactory = productionFactory
        self.onlineService = onlineService
        self.workspace = workspace
        self.isDemo = seedDemoData
        self.books = books
        BrandCompatibility.migrateKeys(defaults)
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
        if productionPersistence != nil || productionFactory != nil { loadState = .loading; return }
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
            activitySessions = snapshot.activitySessions ?? []
            narrationSettings = snapshot.narrationSettings ?? .init(); narrationAnchor = snapshot.narrationAnchor
            mediaLocations = snapshot.mediaLocations ?? [:]; mediaBookmarks = snapshot.mediaBookmarks ?? []
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
        if let unread = notice.unreadChapterIDs { return unread.count }
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
        for entry in receipt.entries.sorted(by: { $0.index < $1.index }) where !favorites.contains(entry.id) && books.contains(where: { $0.id == entry.id }) {
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
        guard let value = progress[book.id], book.chapters.indices.contains(value.chapter), book.content.indices.contains(value.chapter) else { return 0 }
        let loadedCount = prose(book, chapter: value.chapter).count
        let savedCount = stableProgress[book.id]?.paragraphCount ?? 0
        let count = loadedCount > 0 ? loadedCount : savedCount
        let fraction = count > 0 ? Double(min(max(0, value.paragraph), count - 1)) / Double(count) : 0
        return min(99, Int((Double(value.chapter) + fraction) / Double(book.chapters.count) * 100))
    }

    @discardableResult
    func record(_ book: Book, chapter: Int, paragraph: Int = 0, characterOffset: Int = 0, now: Date = Date()) -> Bool {
        guard loadState == .ready, books.contains(where: { $0.id == book.id }), book.chapters.indices.contains(chapter) else { return false }
        let paragraphs = prose(book, chapter: chapter)
        guard !paragraphs.isEmpty else { return false }
        let changedChapter = progress[book.id]?.chapter != chapter
        let paragraph = min(max(0, paragraph), paragraphs.count - 1)
        let offset = ReadingAnchor.safeOffset(characterOffset, in: paragraphs[paragraph] as NSString)
        progress[book.id] = .init(chapter: chapter, paragraph: paragraph, updatedAt: now, characterOffset: offset)
        if let record = chapterCatalogs[book.id]?[safe: chapter] {
            let document = activeDocuments[record.id] ?? ChapterDocument(chapterID: record.id, paragraphs: paragraphs)
            activeDocuments[record.id] = document
            stableProgress[book.id] = try? ReadingAnchor(bookID: book.id, document: document, paragraph: paragraph, offset: offset, now: now)
            if let candidate = stableProgress[book.id] {
                let previous = farthestPositions[book.id]
                let previousChapter = previous.flatMap{chapterIndex(bookID:book.id,chapterID:$0.chapterID)} ?? -1
                let rank = [chapter,paragraph,offset],oldRank = [previousChapter,previous?.paragraphIndex ?? 0,previous?.utf16Offset ?? 0]
                if previous == nil || oldRank.lexicographicallyPrecedes(rank) { farthestPositions[book.id] = candidate }
            }
        }
        unresolvedBookIDs.remove(book.id)
        if var notice = updates[book.id], chapter >= notice.firstChapter {
            notice.readThrough = max(notice.readThrough, chapter)
            updates[book.id] = notice
        }
        if let chapterID = chapterCatalogs[book.id]?[safe:chapter]?.id, var notice = updates[book.id], let unread = notice.unreadChapterIDs {
            notice.unreadChapterIDs = unread.filter { $0 != chapterID }; updates[book.id] = notice
        }
        persist()
        if changedChapter && productionPersistence != nil { enqueueSave() }
        return true
    }

    func read(_ book: Book, chapter: Int? = nil) {
        guard loadState == .ready, books.contains(where: { $0.id == book.id }) else { return }
        if chapter == nil && unresolvedBookIDs.contains(book.id) {
            storageMessage = "原阅读章节已不可用，历史记录已保留。请从作品详情的章节目录重新选章。"
            return
        }
        let target = chapter ?? progress[book.id]?.chapter ?? 0
        guard book.chapters.indices.contains(target) else { return }
        if usesProductionStorage { reader = ReaderSession(book: book, chapter: target, resume: chapter == nil); return }
        let paragraph = progress[book.id]?.chapter == target ? progress[book.id]?.paragraph ?? 0 : 0
        guard record(book, chapter: target, paragraph: paragraph, characterOffset: progress[book.id]?.chapter == target ? progress[book.id]?.characterOffset ?? 0 : 0) else { return }
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
        guard productionPersistence == nil else { throw ContentFailure.storageFailure }
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
        guard !suppressPersistence else { return }
        if usesProductionStorage {
            guard loadState == .ready else { return }
            changeRevision += 1; hasPendingChanges = true
            scheduleSave()
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.storageKey)
        } catch {
            storageMessage = "阅读记录保存失败，请稍后重试。"
        }
    }

    private var snapshot: LibrarySnapshot {
        .init(favorites: favorites, progress: progress.filter{mediaLocations[$0.key] == nil}, settings: settings, sort: sort, updates: updates,
              hasSeenReadingGuide: hasSeenReadingGuide, shelfLayout: shelfLayout.rawValue, importedGroups: importedGroups, groupNames: groupNames, activitySessions: activitySessions, subscribedSourceIDs:subscribedSourceIDs.sorted(),narrationSettings:narrationSettings,narrationAnchor:narrationAnchor,mediaLocations:mediaLocations,mediaBookmarks:mediaBookmarks,userSettingsEdited:defaults.bool(forKey:"reader.user-settings-edited.v1"),farthestPositions:farthestPositions)
    }

    func bootstrapProductionIfNeeded(prepareAppearance: (() throws -> AppearanceMigrationInput)? = nil, forceReload: Bool = false) async {
        if let prepareAppearance { appearancePreparation = prepareAppearance }
        guard usesProductionStorage, !bootstrapStarted || loadState == .failed || forceReload else { return }
        if forceReload && loadState == .ready {
            guard await flushPendingWrites() else { return }
        }
        bootstrapStarted = true; loadState = .loading
        do {
            if productionPersistence == nil { productionPersistence = try productionFactory?() }
            guard let backend = productionPersistence else { throw ContentFailure.storageFailure }
            let appearance = try appearancePreparation?()
            let restored = try await backend.bootstrap(legacySnapshot: defaults.data(forKey: Self.storageKey), archiveURL: importsURL,
                                                       legacyThemeData: defaults.data(forKey: "zhuying.reader.theme-library.v1"), appearance: appearance,
                                                       legacySources: defaults.data(forKey: "zhuying.production.sources.v1"))
            suppressPersistence = true
            books = restored.books; importedBooks = restored.books
            favorites = restored.snapshot.favorites; progress = restored.snapshot.progress
            importedGroups = restored.snapshot.importedGroups ?? [:]
            groupNames = Array(Set((restored.snapshot.groupNames ?? []) + Array(importedGroups.values))).sorted()
            settings = restored.snapshot.settings
            defaults.set(restored.snapshot.userSettingsEdited ?? false,forKey:"reader.user-settings-edited.v1")
            settings.fontSize = ReaderPreferenceBounds.clamp(settings.fontSize, 14...30, fallback: 20)
            settings.lineSpacing = ReaderPreferenceBounds.clamp(settings.lineSpacing, 0...24, fallback: 12)
            settings.preferences.normalize()
            sort = restored.snapshot.sort
            shelfLayout = ShelfLayout(rawValue: restored.snapshot.shelfLayout ?? "") ?? .standard
            hasSeenReadingGuide = restored.snapshot.hasSeenReadingGuide ?? false
            activitySessions = restored.snapshot.activitySessions ?? []
            narrationSettings = restored.snapshot.narrationSettings ?? .init(); narrationAnchor = restored.snapshot.narrationAnchor
            mediaLocations = (restored.snapshot.mediaLocations ?? [:]).filter { id,_ in books.contains(where:{$0.id == id && $0.media != nil}) }
            mediaBookmarks = (restored.snapshot.mediaBookmarks ?? []).filter { mark in books.contains(where:{$0.id == mark.bookID && $0.media != nil}) }
            for (id,location) in mediaLocations { if let media = books.first(where:{$0.id == id})?.media { let saved = location.validated(pages:media.pageCount); mediaLocations[id] = saved; progress[id] = .init(chapter:saved.page,paragraph:0,updatedAt:saved.updatedAt) } }
            subscribedSourceIDs = Set(restored.snapshot.subscribedSourceIDs ?? [])
            updates = restored.snapshot.updates ?? [:]
            themeLibrary = restored.themeLibrary
            unresolvedBookIDs = restored.unresolvedBookIDs
            bookmarks = restored.bookmarks
            chapterCatalogs = restored.catalogs; stableProgress = restored.anchors
            farthestPositions = (restored.snapshot.farthestPositions ?? restored.anchors).filter{ id,_ in books.contains(where:{$0.id == id}) }
            remoteBooks = restored.remoteBooks; sources = restored.sources
            suppressPersistence = false; loadState = .ready
            var messages = restored.warnings
            if !unresolvedBookIDs.intersection(Set(books.map(\.id))).isEmpty { messages.append("部分旧阅读位置无法定位，历史记录已保留，请从章节目录重新选章。") }
            storageMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
        } catch {
            suppressPersistence = false; loadState = .failed
            storageMessage = "书库读取或升级失败，原有文件和记录已保留，请重试。"
        }
    }
    func updateThemeLibrary(_ value: ThemeLibrarySnapshot) {
        guard loadState == .ready, themeLibrary != value else { return }
        themeLibrary = value; persist()
    }

    private func prose(_ book: Book, chapter: Int) -> [String] {
        if let record = chapterCatalogs[book.id]?[safe: chapter], let document = activeDocuments[record.id] { return document.paragraphs.map(\.text) }
        return book.content.indices.contains(chapter) ? book.content[chapter] : []
    }
    func chapterRepository(for book: Book) -> any ChapterDocumentLoading {
        let repository = rawChapterRepository(for:book)
        guard !isDemo,book.media == nil else { return repository }
        return ProcessedChapterRepository(base:repository,processor:contentProcessor,bookID:book.id,sourceID:remoteBooks[book.id]?.source?.sourceID)
    }
    private func rawChapterRepository(for book: Book) -> any ChapterDocumentLoading {
        if let remote = remoteBooks[book.id], let service = onlineService {
            return OnlineChapterRepository(service: service, book: remote, catalog: chapterCatalogs[book.id] ?? [])
        }
        if let backend = productionPersistence { return backend }
        return EmbeddedChapterRepository(book: book)
    }
    func chapterRequest(for book: Book, chapter: Int, resume: Bool = false, atEnd: Bool = false) throws -> ReadingChapterRequest {
        guard book.chapters.indices.contains(chapter) else { throw ContentFailure.missingChapter }
        let record: ChapterRecord
        if usesProductionStorage {
            guard let saved = chapterCatalogs[book.id]?[safe: chapter] else { throw ContentFailure.missingChapter }
            record = saved
        } else { record = EmbeddedChapterRepository.chapter(book, index: chapter) }
        var anchor: ReadingAnchor?
        if resume, progress[book.id]?.chapter == chapter {
            anchor = stableProgress[book.id]
            if anchor == nil, !usesProductionStorage, let saved = progress[book.id] {
                anchor = try? ReadingAnchor(bookID: book.id, document: .init(chapterID: record.id, paragraphs: prose(book, chapter: chapter)), paragraph: saved.paragraph, offset: saved.characterOffset, now: saved.updatedAt)
            }
        }
        return .init(bookID: book.id, chapter: record, anchor: anchor, atEnd: atEnd)
    }
    @discardableResult func confirmChapter(_ book: Book, chapter: Int, document: ChapterDocument, anchor: ReaderAnchor) -> Bool {
        guard let request = try? chapterRequest(for: book, chapter: chapter), request.chapter.id == document.chapterID else { return false }
        activeDocuments[document.chapterID] = document
        let result = record(book, chapter: chapter, paragraph: anchor.paragraph, characterOffset: anchor.offset)
        if result, let remote = remoteBooks[book.id], let service = onlineService, let catalog = chapterCatalogs[book.id] {
            Task { await service.prefetchNext(book: remote, current: request.chapter, next: catalog[safe: chapter + 1]) }
        }
        return result
    }
    func chapterAccess(_ book: Book, chapter: Int) -> ChapterRecord.Access { chapterCatalogs[book.id]?[safe: chapter]?.access ?? .readable }
    func remoteMetadata(_ id: String) -> LibraryBookRecord? { remoteBooks[id] }
    func chapterRecord(bookID: String,index: Int) -> ChapterRecord? { chapterCatalogs[bookID]?[safe:index] }
    func trackReading(_ bookID: String?, foreground: Bool? = nil, interacted: Bool = false,
                      now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isDemo else { return }
        if let foreground { activityForeground = foreground }
        let session = readingActivityClock.advance(bookID: bookID, active: activityForeground && bookID != nil && !narrationIsPlaying,
                                                  interacted: interacted, wall: now, uptime: uptime)
        activityBookID = bookID
        guard let session else { return }
        appendActivity(session)
    }
    func appendActivity(_ session: ActivitySession) {
        guard !isDemo,session.seconds > 0,session.seconds <= 900 else { return }
        if let last = activitySessions.last, last.bookID == session.bookID, last.kind == session.kind,
           abs(last.end.timeIntervalSince(session.start)) < 0.01, last.seconds + session.seconds <= 900 {
            activitySessions[activitySessions.count - 1] = .init(bookID: last.bookID, start: last.start, seconds: last.seconds + session.seconds, kind: last.kind)
        } else { activitySessions.append(session) }
        persist()
    }
    func followNarration(_ anchor: ReadingAnchor) { followingNarrationAnchor = anchor }
    func readingHeartbeat(foreground: Bool? = nil) { trackReading(activityBookID, foreground: foreground) }
    func narrationPlaybackChanged(_ playing: Bool,now: Date = Date(),uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard narrationIsPlaying != playing else { return }; narrationIsPlaying = playing
        trackReading(activityBookID,now:now,uptime:uptime)
    }
    struct SearchResult { let hits: [TextSearchHit]; let indexed: Int; let uncached: Int }
    func searchText(_ query: String, bookID: String? = nil) async throws -> SearchResult {
        let processingVersion = isDemo ? "demo" : (try? await contentProcessor.revision()) ?? "invalid"
        var indexed: [IndexedChapter] = [], missing = 0
        for book in books where book.media == nil && (bookID == nil || book.id == bookID) {
            for chapter in book.chapters.indices {
                try Task.checkCancellation()
                let request = try chapterRequest(for: book, chapter: chapter)
                guard request.chapter.access == .readable else { continue }
                let document: ChapterDocument?
                if let remote = remoteBooks[book.id] {
                    if let raw = try await onlineService?.cachedDocument(book:remote,chapter:request.chapter) { document = try await contentProcessor.process(raw,bookID:book.id,sourceID:remote.source?.sourceID).document } else { document = nil }
                }
                else { document = try await chapterRepository(for: book).document(chapterID: request.chapter.id) }
                if let document { indexed.append(.init(bookID: book.id, document: document)) } else { missing += 1 }
            }
        }
        if !isDemo { let current = (try? await contentProcessor.revision()) ?? "invalid"; guard current == processingVersion else { throw ContentFailure.unavailable } }
        if textIndex == nil { textIndex = try TextSearchIndex(url: workspace?.root.appendingPathComponent("ContentIndex.sqlite")) }
        guard let textIndex else { throw ContentFailure.storageFailure }
        try await textIndex.replace(indexed)
        return .init(hits: try await textIndex.search(query, bookID: bookID), indexed: indexed.count, uncached: missing)
    }
    func openSearchHit(_ hit: TextSearchHit, present: Bool = true) async throws -> ReadingAnchor {
        guard let book = books.first(where: { $0.id == hit.bookID }), let chapter = chapterIndex(bookID: hit.bookID, chapterID: hit.chapterID),
              let document = try await chapterRepository(for: book).document(chapterID: hit.chapterID), document.version == hit.version,
              document.paragraphs[safe: hit.paragraph]?.text == hit.text else { throw BookImportError.message("正文或缓存已更新，请重新检索后打开；原进度已保留。") }
        let anchor = try ReadingAnchor(bookID: hit.bookID, document: document, paragraph: hit.paragraph, offset: hit.offset)
        if present { reader = .init(book: book, chapter: chapter, resume: false, anchor: anchor) }
        return anchor
    }
    func updateSources(_ value: [DemoSource]) {
        guard loadState == .ready, sources != value else { return }
        sources = value; onlineRevision += 1; persist()
    }
    func sourceSwitchSuggestion(bookID: String, catalog: [ChapterRecord]) -> Int? {
        guard let book = books.first(where: { $0.id == bookID }), let chapter = progress[bookID]?.chapter, book.chapters.indices.contains(chapter) else { return nil }
        return SourceChapterMapping.suggestion(title: book.chapterTitle(chapter),order:chapter,catalog:catalog)
    }
    func subscribe(sourceID: String, enabled: Bool) {
        if enabled { subscribedSourceIDs.insert(sourceID) } else { subscribedSourceIDs.remove(sourceID) }; persist()
    }
    func checkSubscribedUpdates() async throws -> (checked: Int, failed: Int, added: Int) {
        guard let service = onlineService else { throw ContentFailure.sourceDisabled }
        var checked = 0, failed = 0, added = 0
        let candidates = shelf.compactMap { remoteBooks[$0.id] }.filter { subscribedSourceIDs.contains($0.source?.sourceID ?? "") }
        for book in candidates {
            try Task.checkCancellation()
            do {
                let (detail,catalog) = try await service.details(book)
                try Task.checkCancellation()
                let previous = Set((chapterCatalogs[book.id] ?? []).map(\.id)), current = Set(catalog.map(\.id))
                let newlyAdded = current.subtracting(previous)
                _ = try await registerRemoteBook(detail,chapters:catalog)
                let unread = Set(updates[book.id]?.unreadChapterIDs ?? []).union(newlyAdded).intersection(current)
                updates[book.id] = .init(firstChapter:0,unreadChapterIDs:unread.sorted())
                added += newlyAdded.count; checked += 1
            } catch is CancellationError { throw CancellationError() }
            catch { failed += 1 }
        }
        persist(); guard await flushPendingWrites() else { throw ContentFailure.storageFailure }
        return (checked,failed,added)
    }
    func switchSource(from oldID: String, to book: LibraryBookRecord, catalog: [ChapterRecord], chapter: Int, allowChapterStart: Bool) async throws {
        guard let backend = productionPersistence, let service = onlineService, catalog.indices.contains(chapter), await flushPendingWrites() else { throw ContentFailure.storageFailure }
        let document = try await service.document(book:book,chapter:catalog[chapter])
        try Task.checkCancellation()
        let anchor = try SourceChapterMapping.anchor(from: stableProgress[oldID],bookID:book.id,document:document,allowChapterStart:allowChapterStart)
        try await backend.switchSource(from:oldID,book:book,chapters:catalog,anchor:anchor,document:document)
        await bootstrapProductionIfNeeded(forceReload:true)
        guard loadState == .ready, let presentation = books.first(where: { $0.id == book.id }) else { throw ContentFailure.storageFailure }
        reader = .init(book:presentation,chapter:chapter,resume:false,anchor:anchor)
    }
    func configureOnline(credential: ShushanCredential?, expired: Bool = false) async {
        guard let service = onlineService else { return }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") && arguments.contains("--online-fixtures") {
            await service.configure(source: OnlineDevelopmentFixtures()); await service.prepareDownloads(); onlineRevision += 1; return
        }
        #endif
        let source = sources.first { $0.id == "shushan" && $0.enabled && $0.kind == .novel }
        var configuredFailure: ContentFailure = source == nil ? .sourceDisabled : .authenticationRequired
        var providers: [any BookSource] = sources.filter { $0.enabled && $0.kind == .novel && $0.id != "shushan" }.compactMap { source -> (any BookSource)? in
            guard let rules = try? SourcePackages.rules(source) else { return nil }
            guard let transport = try? sourceTransport(for:source,maximumBytes:rules.extraction == nil ? 4 * 1024 * 1024 : 2 * 1024 * 1024) else { return nil }
            if rules.extraction != nil { return try? ExtractionBookSource(source:source,transport:transport) }
            return try? ConfigurableBookSource(source:source,transport:transport)
        }
        if let source, let credential, (try? ShushanClient.host(source.url)) == credential.host, !expired {
            if let transport = try? sourceTransport(for:source) { providers.append(ShushanBookSource(credential:credential,transport:ResilientSourceTransport(base:transport))) }
            else { configuredFailure = .sourceDisabled }
        }
        await service.configure(sources:providers,failure:configuredFailure)
        await service.prepareDownloads()
        onlineRevision += 1
    }
    func enqueueDownload(bookID: String, count: Int?, wifiOnly: Bool) async throws {
        guard let book = remoteBooks[bookID], let catalog = chapterCatalogs[bookID] else { throw ContentFailure.sourceDisabled }
        guard let downloads = onlineService?.downloads else { throw ContentFailure.storageFailure }
        let start = min(catalog.count, (progress[bookID]?.chapter ?? -1) + 1)
        let selected = count.map { Array(catalog.dropFirst(start).prefix($0)) } ?? catalog
        _ = try await downloads.enqueue(book:book,chapters:selected.filter { $0.access == .readable },wifiOnly:wifiOnly)
    }
    @discardableResult func registerRemoteBook(_ record: LibraryBookRecord, chapters: [ChapterRecord]) async throws -> Book {
        guard let backend = productionPersistence, loadState == .ready else { throw ContentFailure.storageFailure }
        guard await flushPendingWrites() else { throw ContentFailure.storageFailure }
        let previous = writeTail
        let operation = Task { @MainActor in
            await previous?.value
            try await backend.saveRemoteBook(record, chapters: chapters)
            let book = record.presentation(chapters: chapters)
            self.books.removeAll { $0.id == book.id }; self.books.append(book)
            self.remoteBooks[book.id] = record.withDisplayMetadata(); self.chapterCatalogs[book.id] = chapters
            if let anchor = self.stableProgress[book.id] {
                if let index = chapters.firstIndex(where: { $0.id == anchor.chapterID }) {
                    self.progress[book.id] = .init(chapter: index, paragraph: anchor.paragraphIndex, updatedAt: anchor.updatedAt, characterOffset: anchor.utf16Offset)
                } else {
                    self.progress.removeValue(forKey: book.id); self.unresolvedBookIDs.insert(book.id)
                    self.storageMessage = "原阅读章节已不可用，历史记录保留，请从目录重新选章。"
                }
            }
            return book
        }
        queueRevision += 1; writeTail = Task { _ = await operation.result }
        return try await operation.value
    }

    func retryStorage() async {
        if loadState == .failed { await bootstrapProductionIfNeeded() }
        else if hasPendingChanges { _ = await flushPendingWrites() }
        else { await bootstrapProductionIfNeeded(forceReload: true) }
    }
    func createBackup() async throws -> Data {
        guard let backend = productionPersistence, let workspace, await flushPendingWrites() else { throw ContentFailure.storageFailure }
        return try await backend.backup(fontDirectory: workspace.fontDirectory()).encoded()
    }
    func synchronizeRecords(_ records: CloudRecordStore,account: String,transport: any CloudDocumentTransport,resolutions: [String:SyncEntry] = [:]) async throws -> RecordSyncState {
        guard reader == nil else { throw RecordSyncError.reading }
        guard let backend = productionPersistence,loadState == .ready,await flushPendingWrites() else { throw ContentFailure.storageFailure }
        audio.stop(); loadState = .loading
        do {
            let desired = try await backend.recordSyncDesired()
            let result = try await records.synchronize(desired,account:account,resolutions:resolutions) { state in
                try Task.checkCancellation(); guard try await transport.account() == account else { throw CloudAccessError.accountChanged }
                try await backend.applyRecordSync(state)
            }
            await bootstrapProductionIfNeeded(forceReload:true)
            guard loadState == .ready else { throw ContentFailure.storageFailure }; return result
        } catch {
            await bootstrapProductionIfNeeded(forceReload:true)
            throw error
        }
    }
    func localFiles() async throws -> [LocalBookFile] {
        guard let backend = productionPersistence else { throw ContentFailure.storageFailure }
        return try await backend.localFiles()
    }
    func exportLocalText(id: String) async throws -> Data {
        guard let backend = productionPersistence else { throw ContentFailure.storageFailure }
        return try await backend.exportText(bookID: id)
    }
    func renameLocalBook(id: String, title: String) async throws {
        guard let backend = productionPersistence, remoteBooks[id] == nil, await flushPendingWrites() else { throw ContentFailure.storageFailure }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await backend.renameBook(id: id, title: title)
        if let index = books.firstIndex(where: { $0.id == id }) {
            let book = books[index]
            books[index] = .init(id: id, title: title, author: book.author, genre: book.genre, category: book.category, status: book.status, words: book.words, color: book.color, subtitle: book.subtitle, intro: book.intro, tags: book.tags, chapters: book.chapters, content: book.content,media:book.media,cover:book.cover)
        }
    }
    func restoreBackup(_ backup: LibraryBackup) async throws {
        guard let workspace, productionFactory != nil else { throw ContentFailure.storageFailure }
        audioCoordinator?.stop(); await onlineService?.downloads?.pauseForBackground()
        guard await flushPendingWrites() else {
            if activityForeground { await onlineService?.downloads?.returnToForeground() }
            throw ContentFailure.storageFailure
        }
        loadState = .loading
        do { try await workspace.restore(backup) }
        catch { loadState = .ready; if activityForeground { await onlineService?.downloads?.returnToForeground() }; throw error }
        reader = nil; productionPersistence = nil; processingStore = nil; bootstrapStarted = false
        activeDocuments = ChapterMemoryCache(); stableProgress = [:]; remoteBooks = [:]; chapterCatalogs = [:]
        hasPendingChanges = false; lastWriteFailed = false
        await bootstrapProductionIfNeeded()
        if activityForeground { await onlineService?.downloads?.returnToForeground() }
        guard loadState == .ready else { throw ContentFailure.storageFailure }
    }

    func moveBooks(_ ids: Set<String>, toGroup name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadState == .ready, !name.isEmpty, name.count <= 100 else { return }
        for book in books where ids.contains(book.id) { importedGroups[book.id] = name }
        persist()
    }
    @discardableResult func renameGroup(_ oldName: String, to newName: String) -> Bool {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Set(groupNames + Array(importedGroups.values))
        guard loadState == .ready, names.contains(oldName), !["全部", "未分组"].contains(oldName),
              !newName.isEmpty, newName.count <= 100, !["全部", "未分组"].contains(newName),
              oldName == newName || !names.contains(newName) else { return false }
        moveBooks(Set(importedGroups.filter { $0.value == oldName }.keys), toGroup: newName)
        groupNames.removeAll { $0 == oldName }; if !groupNames.contains(newName) { groupNames.append(newName) }; persist()
        return true
    }
    func removeGroup(_ name: String) {
        moveBooks(Set(importedGroups.filter { $0.value == name }.keys), toGroup: "未分组")
        groupNames.removeAll { $0 == name }; persist()
    }
    @discardableResult func createGroup(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadState == .ready, !value.isEmpty, value.count <= 100, !["全部", "未分组"].contains(value),
              !groupNames.contains(value), !importedGroups.values.contains(value) else { return false }
        groupNames.append(value); persist()
        return true
    }
    func chapterIndex(bookID: String, chapterID: String) -> Int? { chapterCatalogs[bookID]?.firstIndex { $0.id == chapterID } }
    func openBookmark(_ mark: LibraryBookmarkRecord) {
        guard let book = books.first(where: { $0.id == mark.anchor.bookID }), let index = chapterIndex(bookID: book.id, chapterID: mark.anchor.chapterID) else {
            storageMessage = "书签原章节已不可用，书签和历史已保留。"; return
        }
        reader = .init(book: book, chapter: index, resume: false, anchor: mark.anchor)
    }
    func saveCurrentBookmark(_ book: Book, progress value: ReadingProgress) async throws {
        let request = try chapterRequest(for: book, chapter: value.chapter, resume: true)
        guard let document = try await chapterRepository(for: book).document(chapterID: request.chapter.id) else { throw ContentFailure.missingChapter }
        if let saved = request.anchor {
            switch ReadingAnchorResolver.resolve(saved, in: document) {
            case let .exact(p, o), let .recovered(p, o):
                activeDocuments[document.chapterID] = document
                _ = try await saveBookmark(book, chapter: value.chapter, paragraph: p, offset: o, title: book.chapterTitle(value.chapter))
            default: throw ContentFailure.missingChapter
            }
        } else { throw ContentFailure.missingChapter }
    }

    @discardableResult
    func saveBookmark(_ book: Book, chapter: Int, paragraph: Int, offset: Int = 0, title: String) async throws -> LibraryBookmarkRecord {
        guard let backend = productionPersistence, loadState == .ready, books.contains(where: { $0.id == book.id }),
              let record = chapterCatalogs[book.id]?[safe: chapter] else { throw ContentFailure.missingChapter }
        let paragraphs = prose(book, chapter: chapter)
        let document = ChapterDocument(chapterID: record.id, paragraphs: paragraphs)
        let bookmark = LibraryBookmarkRecord(title: title, anchor: try ReadingAnchor(bookID: book.id, document: document, paragraph: paragraph, offset: offset))
        let previous = writeTail
        let operation = Task { @MainActor in
            await previous?.value
            try await backend.saveBookmark(bookmark, document: document)
            self.bookmarks.removeAll { $0.id == bookmark.id }; self.bookmarks.append(bookmark)
        }
        queueRevision += 1; writeTail = Task { _ = await operation.result }
        try await operation.value
        return bookmark
    }

    func removeBookmark(id: String) async throws {
        guard let backend = productionPersistence, loadState == .ready else { throw ContentFailure.storageFailure }
        let previous = writeTail
        let operation = Task { @MainActor in
            await previous?.value
            try await backend.removeBookmark(id: id)
            self.bookmarks.removeAll { $0.id == id }
        }
        queueRevision += 1; writeTail = Task { _ = await operation.result }
        try await operation.value
    }

    func permanentlyDeleteBook(id: String) async throws {
        if audioCoordinator?.state.bookID == id { audioCoordinator?.stop() }
        guard let backend = productionPersistence, loadState == .ready, await flushPendingWrites() else { throw ContentFailure.storageFailure }
        let previous = writeTail
        let operation = Task { @MainActor in
            await previous?.value
            let cleaned = try await backend.deleteBook(id: id)
            self.books.removeAll { $0.id == id }; self.importedBooks.removeAll { $0.id == id }
            self.favorites.removeAll { $0 == id }; self.progress.removeValue(forKey: id)
            self.importedGroups.removeValue(forKey: id); self.updates.removeValue(forKey: id)
            self.unresolvedBookIDs.remove(id); self.bookmarks.removeAll { $0.anchor.bookID == id }
            for chapter in self.chapterCatalogs[id] ?? [] { self.activeDocuments.removeValue(forKey: chapter.id) }
            self.chapterCatalogs.removeValue(forKey: id); self.stableProgress.removeValue(forKey: id)
            self.remoteBooks.removeValue(forKey: id)
            self.activitySessions.removeAll { $0.bookID == id }
            self.mediaLocations.removeValue(forKey:id); self.mediaBookmarks.removeAll{$0.bookID == id}
            self.farthestPositions.removeValue(forKey:id)
            if self.narrationAnchor?.bookID == id { self.narrationAnchor = nil }
            if self.followingNarrationAnchor?.bookID == id { self.followingNarrationAnchor = nil }
            if self.reader?.book.id == id { self.reader = nil }
            if !cleaned { self.storageMessage = "作品记录已删除，部分文件将在下次打开书库时清理。" }
        }
        queueRevision += 1; writeTail = Task { _ = await operation.result }
        try await operation.value
    }

    @discardableResult
    func importBookDurably(_ book: Book, group: String = "未分组",resources: [ResourceFileReference:Data] = [:]) async throws -> Bool {
        guard usesProductionStorage else { guard book.media == nil else { throw BookImportError.message("请在正式模式中导入原版式 PDF 与漫画。") }; return try importBook(book, group: group) }
        guard let backend = productionPersistence else { throw ContentFailure.storageFailure }
        guard loadState == .ready else { throw ContentFailure.storageFailure }
        enqueueSave()
        let previous = writeTail
        let operation = Task { @MainActor in
            await previous?.value
            guard !self.books.contains(where: { $0.id == book.id }) else { return false }
            let imported = try await backend.importBook(book, group: group,resources:resources)
            if imported {
                self.books.append(book.metadataOnly()); self.importedBooks.append(book.metadataOnly())
                self.chapterCatalogs[book.id] = book.chapters.indices.map { EmbeddedChapterRepository.chapter(book, index: $0) }
                self.favorites.insert(book.id, at: 0); self.importedGroups[book.id] = group
            }
            return imported
        }
        queueRevision += 1
        writeTail = Task { _ = await operation.result }
        return try await operation.value
    }

    func mediaURL(_ reference: ResourceFileReference) async throws -> URL {
        guard let backend = productionPersistence else { throw ContentFailure.storageFailure }; return try await backend.mediaURL(reference)
    }
    func saveCover(bookID: String,data: Data?) async throws {
        guard let backend = productionPersistence,loadState == .ready,await flushPendingWrites(),books.contains(where:{$0.id == bookID}) else { throw ContentFailure.storageFailure }
        let reference = try await backend.saveCover(bookID:bookID,data:data)
        if let index = books.firstIndex(where:{$0.id == bookID}) { books[index].cover = reference }
        if let index = importedBooks.firstIndex(where:{$0.id == bookID}) { importedBooks[index].cover = reference }
        remoteBooks[bookID]?.cover = reference
    }
    func recordMedia(_ book: Book,location: MediaReadingLocation) {
        guard let media = book.media,books.contains(where:{$0.id == book.id}) else { return }
        let valid = location.validated(pages:media.pageCount); mediaLocations[book.id] = valid
        progress[book.id] = .init(chapter:valid.page,paragraph:0,updatedAt:valid.updatedAt)
        trackReading(book.id,interacted:true); persist()
    }
    func saveMediaBookmark(_ book: Book) {
        guard let location = mediaLocations[book.id] else { return }
        let id = StableContentID.make(book.id,"media",String(location.page),String(Int(location.x * 1000)),String(Int(location.y * 1000)))
        mediaBookmarks.removeAll{$0.id == id}; mediaBookmarks.append(.init(id:id,bookID:book.id,title:"第 \(location.page + 1) 页",location:location)); persist()
    }
    func removeMediaBookmark(_ id: String) { mediaBookmarks.removeAll{$0.id == id}; persist() }

    private func scheduleSave() {
        guard pendingSave == nil, !saveQueued, hasPendingChanges else { return }
        // Throttle rather than postpone forever while the reader keeps scrolling.
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.pendingSave = nil
            self.enqueueSave()
        }
    }

    private func enqueueSave() {
        guard let backend = productionPersistence, hasPendingChanges, !saveQueued, loadState == .ready else { return }
        pendingSave?.cancel(); pendingSave = nil
        saveQueued = true
        let previous = writeTail
        queueRevision += 1
        writeTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            // Read state after earlier imports commit and publish their new shelf entries.
            let revision = self.changeRevision
            let current = self.snapshot
            let themes = self.themeLibrary
            let sources = self.sources
            let anchors = Array(self.stableProgress.values)
            do {
                try await backend.saveState(current, themeLibrary: themes, sources: sources, confirmedAnchors: anchors)
                if self.changeRevision == revision { self.hasPendingChanges = false }
                self.lastWriteFailed = false
                if self.storageMessage == self.lastWriteMessage { self.storageMessage = nil }
                self.lastWriteMessage = nil
            } catch {
                self.lastWriteFailed = true
                self.lastWriteMessage = "阅读记录保存失败，已有记录保留，请检查设备空间后重试。"
                self.storageMessage = self.lastWriteMessage
            }
            self.saveQueued = false
            if !self.lastWriteFailed { self.scheduleSave() }
        }
    }

    @discardableResult
    func flushPendingWrites() async -> Bool {
        guard usesProductionStorage else { persist(); return true }
        guard loadState == .ready else { return false }
        while true {
            pendingSave?.cancel(); pendingSave = nil
            enqueueSave()
            let revision = queueRevision
            await writeTail?.value
            if lastWriteFailed { return false }
            if revision == queueRevision && !hasPendingChanges { return true }
        }
    }
}
