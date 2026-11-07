import Foundation

/// A source may be replaced or invalidated on logout without allowing an old
/// response to write into the cache. Local archives use their own repository.
actor OnlineReadingService {
    private var source: (any BookSource)?
    private var providers: [String:any BookSource] = [:]
    private let multiSearch = MultiSourceSearch()
    private let discoverySearch = MultiSourceSearch()
    private var failure: ContentFailure = .authenticationRequired
    private var generation = 0
    private var prefetch: Task<Void, Never>?
    private var cacheEpochs: [String: UUID] = [:]
    private func cacheEpoch(bookID: String) -> UUID {
        if let epoch = cacheEpochs[bookID] { return epoch }
        let epoch = UUID(); cacheEpochs[bookID] = epoch; return epoch
    }
    private let cache: RecentChapterCache
    let downloads: OfflineDownloadStore?
    private let networkObserver: DownloadNetworkObserver?
    private var authenticationHandler: (@Sendable () async -> Void)?
    private var authenticationHandlerSourceID: String?
    func setAuthenticationHandler(sourceID: String? = nil, _ handler: @escaping @Sendable () async -> Void) {
        authenticationHandlerSourceID = sourceID; authenticationHandler = handler
    }
    private func recordFailure(_ error: Error, revision: Int, sourceID: String? = nil) async {
        guard revision == generation, error as? ContentFailure == .authenticationRequired else { return }
        let failedSourceID = sourceID ?? source?.sourceID ?? ""
        generation += 1
        providers.removeValue(forKey: failedSourceID)
        source = providers.values.first; failure = .authenticationRequired
        prefetch?.cancel(); prefetch = nil
        if authenticationHandlerSourceID == nil || authenticationHandlerSourceID == failedSourceID { await authenticationHandler?() }
    }
    init(cache: RecentChapterCache, downloads: OfflineDownloadStore? = nil) {
        self.cache = cache; self.downloads = downloads; networkObserver = downloads.map { DownloadNetworkObserver(store:$0) }
    }
    func prepareDownloads() async {
        await downloads?.configure { [weak self] book,chapter in
            guard let self else { throw CancellationError() }; return try await self.networkDocument(book:book,chapter:chapter)
        }
    }
    private func networkDocument(book: LibraryBookRecord, chapter: ChapterRecord) async throws -> ChapterDocument {
        guard let source = providers[book.source?.sourceID ?? ""], chapter.bookID == book.id, chapter.access == .readable else { throw failure }
        let revision = generation
        let document = try await source.document(for:chapter,book:book)
        try Task.checkCancellation(); guard revision == generation, document.chapterID == chapter.id else { throw CancellationError() }
        return document
    }
    func configure(source: (any BookSource)?, failure: ContentFailure = .authenticationRequired) {
        generation += 1; prefetch?.cancel(); prefetch = nil
        self.source = source; self.failure = failure
        providers = source.map { [$0.sourceID:$0] } ?? [:]
    }
    func configure(sources: [any BookSource], failure: ContentFailure = .authenticationRequired) {
        generation += 1; prefetch?.cancel(); prefetch = nil
        providers = Dictionary(sources.map { ($0.sourceID,$0) }, uniquingKeysWith: { first,_ in first })
        source = sources.first; self.failure = failure
    }
    func search(query: String, page: Int, sourceIDs: Set<String>? = nil) async throws -> BookSearchPage {
        let selected = providers.values.filter { sourceIDs?.contains($0.sourceID) ?? true }.sorted { $0.sourceID < $1.sourceID }
        guard let source = selected.first else { throw failure }
        let revision = generation
        let result: BookSearchPage
        do {
            if selected.count <= 1 { result = try await source.search(query: query, page: page) }
            else { result = try await multiSearch.search(query, page: page, sources: selected) }
        }
        catch { await recordFailure(error, revision: revision, sourceID: source.sourceID); throw error }
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        return result
    }
    func details(_ book: LibraryBookRecord) async throws -> (LibraryBookRecord, [ChapterRecord]) {
        guard let source = providers[book.source?.sourceID ?? ""] else { throw failure }
        let revision = generation
        let detail: LibraryBookRecord, catalog: [ChapterRecord]
        do {
            detail = try await source.details(for: book)
            catalog = try await source.chapters(for: detail)
        } catch { await recordFailure(error, revision: revision, sourceID: source.sourceID); throw error }
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        guard !catalog.isEmpty else { throw ContentFailure.missingChapter }
        return (detail, catalog)
    }
    func discoveryCategories(sourceID: String) async throws -> [SourceDiscoveryCategory] {
        guard let provider = providers[sourceID] as? any DiscoveryBookSource, provider.supportsDiscovery else {
            throw SourceImportError.message("此书源未提供发现分类，可使用搜索或打开书源登录。")
        }
        let revision = generation
        let categories = try await provider.discoveryCategories()
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }; return categories
    }
    func applyDiscoveryFilter(sourceID: String, category: SourceDiscoveryCategory, value: String) async throws -> SourceDiscoveryFilterResult {
        guard let provider = providers[sourceID] as? any DiscoveryBookSource, provider.supportsDiscovery else {
            throw SourceImportError.message("此书源暂不支持发现筛选操作。")
        }
        let revision = generation
        let result = try await provider.applyDiscoveryFilter(category: category, value: value)
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }; return result
    }
    func discover(category: String,page: Int,subscribed: Set<String>) async throws -> BookSearchPage {
        let enabled: [any BookSource] = providers.values.compactMap { source in
            guard subscribed.contains(source.sourceID), let provider = source as? any DiscoveryBookSource, provider.supportsDiscovery else { return nil }
            return DiscoverySourceRequest(provider:provider)
        }.sorted { $0.sourceID < $1.sourceID }
        guard !enabled.isEmpty else { throw SourceImportError.message("已订阅来源暂不支持分类发现；可继续搜索或检查书架更新。") }
        let revision = generation
        let page = try await discoverySearch.search(category,page:page,sources:enabled)
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }; return page
    }
    func document(book: LibraryBookRecord, chapter: ChapterRecord) async throws -> ChapterDocument {
        prefetch?.cancel(); prefetch = nil
        guard chapter.bookID == book.id, chapter.access == .readable else { throw ContentFailure.restricted }
        if let document = try await downloads?.document(book:book,chapter:chapter) { return document }
        let key = RecentChapterCache.fingerprint(book: book, chapter: chapter)
        let source = providers[book.source?.sourceID ?? ""]
        if let document = try await cache.document(bookID: book.id, chapterID: chapter.id, fingerprint: key, allowStale: source == nil) { return document }
        guard let source else { throw failure }
        guard book.source?.sourceID == source.sourceID else { throw ContentFailure.sourceDisabled }
        let revision = generation, epoch = cacheEpoch(bookID: book.id)
        let document: ChapterDocument
        do { document = try await source.document(for: chapter, book: book) }
        catch {
            await recordFailure(error, revision: revision, sourceID: source.sourceID)
            if revision == generation, let failure = error as? ContentFailure,
               [.offline, .timedOut, .unavailable, .rateLimited].contains(failure),
               let cached = try await cache.document(bookID: book.id, chapterID: chapter.id, fingerprint: key, allowStale: true) { return cached }
            throw error
        }
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        guard document.chapterID == chapter.id else { throw ContentFailure.invalidResponse }
        // Content may still be shown if disposable cache storage is unavailable.
        if cacheEpochs[book.id] == epoch {
            _ = try? await cache.save(document, bookID: book.id, fingerprint: key, protecting: chapter.id)
        }
        return document
    }
    /// A deliberate refresh never reports an old offline copy as new content.
    /// The previous cache remains available when the network request fails.
    func refreshDocument(book: LibraryBookRecord, chapter: ChapterRecord) async throws -> ChapterDocument {
        prefetch?.cancel(); prefetch = nil
        guard chapter.bookID == book.id, chapter.access == .readable else { throw ContentFailure.restricted }
        guard let source = providers[book.source?.sourceID ?? ""] else { throw failure }
        let revision = generation, epoch = UUID()
        cacheEpochs[book.id] = epoch
        let document: ChapterDocument
        do { document = try await source.document(for: chapter, book: book) }
        catch { await recordFailure(error, revision: revision, sourceID: source.sourceID); throw error }
        try Task.checkCancellation()
        guard revision == generation, cacheEpochs[book.id] == epoch else { throw CancellationError() }
        guard document.chapterID == chapter.id, !document.paragraphs.isEmpty,
              document.paragraphs.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ContentFailure.invalidResponse }
        try await downloads?.replaceDownloaded(document, book: book, chapter: chapter)
        try Task.checkCancellation()
        guard revision == generation, cacheEpochs[book.id] == epoch else { throw CancellationError() }
        _ = try? await cache.save(document, bookID: book.id, fingerprint: RecentChapterCache.fingerprint(book: book, chapter: chapter), protecting: chapter.id)
        return document
    }
    func prefetchNext(book: LibraryBookRecord, current: ChapterRecord, next: ChapterRecord?) {
        prefetch?.cancel(); prefetch = nil
        guard let source = providers[book.source?.sourceID ?? ""], let next, next.access == .readable, next.bookID == book.id else { return }
        let revision = generation, cache = cache, epoch = cacheEpoch(bookID: book.id)
        prefetch = Task { [weak self] in
            do {
                let key = RecentChapterCache.fingerprint(book: book, chapter: next)
                if try await cache.document(bookID: book.id, chapterID: next.id, fingerprint: key) != nil { return }
                let document = try await source.document(for: next, book: book)
                try Task.checkCancellation()
                guard await self?.generation == revision, await self?.cacheEpochs[book.id] == epoch, document.chapterID == next.id else { return }
                _ = try await cache.save(document, bookID: book.id, fingerprint: key, protecting: current.id, speculative: true)
            } catch { /* Speculation never changes the visible reading state. */ }
        }
    }
    func cancelPrefetch() { prefetch?.cancel(); prefetch = nil }
    func cacheUsage() async -> (bytes: Int, chapters: Int) { await cache.usage() }
    func cachedDocument(book: LibraryBookRecord, chapter: ChapterRecord) async throws -> ChapterDocument? {
        if let document = try await downloads?.document(book:book,chapter:chapter) { return document }
        return try await cache.document(bookID: book.id, chapterID: chapter.id, fingerprint: RecentChapterCache.fingerprint(book: book, chapter: chapter), allowStale: true)
    }
    func clearCache(bookID: String? = nil) async throws {
        prefetch?.cancel(); prefetch = nil
        if let bookID { cacheEpochs[bookID] = UUID() }
        else { for id in cacheEpochs.keys { cacheEpochs[id] = UUID() } }
        try await cache.clear(bookID: bookID)
    }
}

struct OnlineChapterRepository: ChapterDocumentLoading {
    let service: OnlineReadingService
    let book: LibraryBookRecord
    let catalog: [ChapterRecord]
    func document(chapterID: String) async throws -> ChapterDocument? {
        guard let chapter = catalog.first(where: { $0.id == chapterID }) else { throw ContentFailure.missingChapter }
        return try await service.document(book: book, chapter: chapter)
    }
    func refreshedDocument(chapterID: String) async throws -> ChapterDocument? {
        guard let chapter = catalog.first(where: { $0.id == chapterID }) else { throw ContentFailure.missingChapter }
        return try await service.refreshDocument(book: book, chapter: chapter)
    }
}
