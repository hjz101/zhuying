import Foundation

/// A source may be replaced or invalidated on logout without allowing an old
/// response to write into the cache. Local archives use their own repository.
actor OnlineReadingService {
    private var source: (any BookSource)?
    private var failure: ContentFailure = .authenticationRequired
    private var generation = 0
    private var prefetch: Task<Void, Never>?
    private let cache: RecentChapterCache
    private var authenticationHandler: (@Sendable () async -> Void)?
    func setAuthenticationHandler(_ handler: @escaping @Sendable () async -> Void) { authenticationHandler = handler }
    private func recordFailure(_ error: Error, revision: Int) async {
        guard revision == generation, error as? ContentFailure == .authenticationRequired else { return }
        generation += 1; source = nil; failure = .authenticationRequired
        prefetch?.cancel(); prefetch = nil
        await authenticationHandler?()
    }
    init(cache: RecentChapterCache) { self.cache = cache }
    func configure(source: (any BookSource)?, failure: ContentFailure = .authenticationRequired) {
        generation += 1; prefetch?.cancel(); prefetch = nil
        self.source = source; self.failure = failure
    }
    func search(query: String, page: Int) async throws -> BookSearchPage {
        guard let source else { throw failure }
        let revision = generation
        let result: BookSearchPage
        do { result = try await source.search(query: query, page: page) }
        catch { await recordFailure(error, revision: revision); throw error }
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        return result
    }
    func details(_ book: LibraryBookRecord) async throws -> (LibraryBookRecord, [ChapterRecord]) {
        guard let source else { throw failure }
        let revision = generation
        let detail: LibraryBookRecord, catalog: [ChapterRecord]
        do {
            detail = try await source.details(for: book)
            catalog = try await source.chapters(for: detail)
        } catch { await recordFailure(error, revision: revision); throw error }
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        guard !catalog.isEmpty else { throw ContentFailure.missingChapter }
        return (detail, catalog)
    }
    func document(book: LibraryBookRecord, chapter: ChapterRecord) async throws -> ChapterDocument {
        prefetch?.cancel(); prefetch = nil
        guard chapter.bookID == book.id, chapter.access == .readable else { throw ContentFailure.restricted }
        let key = RecentChapterCache.fingerprint(book: book, chapter: chapter)
        if let document = try await cache.document(bookID: book.id, chapterID: chapter.id, fingerprint: key) { return document }
        guard let source else { throw failure }
        guard book.source?.sourceID == source.sourceID else { throw ContentFailure.sourceDisabled }
        let revision = generation
        let document: ChapterDocument
        do { document = try await source.document(for: chapter, book: book) }
        catch { await recordFailure(error, revision: revision); throw error }
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        guard document.chapterID == chapter.id else { throw ContentFailure.invalidResponse }
        // Content may still be shown if disposable cache storage is unavailable.
        _ = try? await cache.save(document, bookID: book.id, fingerprint: key, protecting: chapter.id)
        return document
    }
    func prefetchNext(book: LibraryBookRecord, current: ChapterRecord, next: ChapterRecord?) {
        prefetch?.cancel(); prefetch = nil
        guard let source, let next, next.access == .readable, next.bookID == book.id else { return }
        let revision = generation, cache = cache
        prefetch = Task { [weak self] in
            do {
                let key = RecentChapterCache.fingerprint(book: book, chapter: next)
                if try await cache.document(bookID: book.id, chapterID: next.id, fingerprint: key) != nil { return }
                let document = try await source.document(for: next, book: book)
                try Task.checkCancellation()
                guard await self?.generation == revision, document.chapterID == next.id else { return }
                _ = try await cache.save(document, bookID: book.id, fingerprint: key, protecting: current.id, speculative: true)
            } catch { /* Speculation never changes the visible reading state. */ }
        }
    }
    func cancelPrefetch() { prefetch?.cancel(); prefetch = nil }
    func cacheUsage() async -> (bytes: Int, chapters: Int) { await cache.usage() }
    func clearCache(bookID: String? = nil) async throws { prefetch?.cancel(); try await cache.clear(bookID: bookID) }
}

struct OnlineChapterRepository: ChapterDocumentLoading {
    let service: OnlineReadingService
    let book: LibraryBookRecord
    let catalog: [ChapterRecord]
    func document(chapterID: String) async throws -> ChapterDocument? {
        guard let chapter = catalog.first(where: { $0.id == chapterID }) else { throw ContentFailure.missingChapter }
        return try await service.document(book: book, chapter: chapter)
    }
}
