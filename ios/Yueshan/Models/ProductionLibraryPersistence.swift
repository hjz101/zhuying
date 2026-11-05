import Foundation

struct ProductionLibraryState {
    var books: [Book]
    var snapshot: LibrarySnapshot
    var unresolvedBookIDs: Set<String>
    var themeLibrary: ThemeLibrarySnapshot? = nil
    var warnings: [String] = []
    var bookmarks: [LibraryBookmarkRecord] = []
    var catalogs: [String: [ChapterRecord]] = [:]
    var anchors: [String: ReadingAnchor] = [:]
}

struct AppearanceMigrationInput {
    let fallbackThemeLibrary: ThemeLibrarySnapshot
    let originalFontManifest: Data?
    let fontHashes: [String: String]
    var warnings: [String] = []
}

private struct LibraryViewPreferences: Codable {
    var settings: ReadingSettings
    var sort: ShelfSort
    var shelfLayout: String?
    var hasSeenReadingGuide: Bool
    init(_ snapshot: LibrarySnapshot) {
        settings = snapshot.settings; sort = snapshot.sort
        if settings.preferences.bubbleSVG != nil { settings.preferences.bubbleImageData = nil }
        if settings.preferences.customBubbleSVG != nil { settings.preferences.customBubbleImageData = nil }
        shelfLayout = snapshot.shelfLayout; hasSeenReadingGuide = snapshot.hasSeenReadingGuide ?? false
    }
}

/// Coordinates immutable chapter files with the database commit. All public
/// operations share one queue, including calls arriving while another awaits I/O.
actor ProductionLibraryPersistence: ChapterDocumentLoading {
    static let migrationKey = "migration.legacy-library.v1"
    static let legacySnapshotKey = "migration.legacy-library.original-snapshot"
    static let appearanceMigrationKey = "migration.appearance.v1"
    static let themeLibraryKey = "appearance.theme-library.v1"
    private static let viewKey = "library.view-preferences.v1"
    private static let unresolvedKey = "library.unresolved-history.v1"
    private let records: SQLiteLibraryRepository
    private let files: FileChapterRepository
    private let themes: ThemeLibraryRepository?
    private var tail: Task<Void, Never>?
    private var documents = ChapterMemoryCache()
    private var savedAnchors: [String: ReadingAnchor] = [:]
    private var catalogs: [String: [ChapterRecord]] = [:]

    init(directory: URL, writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        records = try SQLiteLibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        files = try FileChapterRepository(directory: directory.appendingPathComponent("chapters"), writer: writer)
        themes = ThemeLibraryRepository(directory: directory.appendingPathComponent("resources/themes"), writer: writer)
    }

    // Dependency injection also permits testing a failed metadata commit after files stage.
    init(records: SQLiteLibraryRepository, files: FileChapterRepository) {
        self.records = records; self.files = files; themes = nil
    }

    private func serialized<T>(_ body: @escaping (ProductionLibraryPersistence) async throws -> T) async throws -> T {
        let previous = tail
        let operation = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await body(self)
        }
        tail = Task { _ = await operation.result }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }

    func bootstrap(legacySnapshot: Data?, archiveURL: URL?, legacyThemeData: Data? = nil, appearance: AppearanceMigrationInput? = nil) async throws -> ProductionLibraryState {
        try await serialized {
            try await $0.performBootstrap(legacySnapshot: legacySnapshot, archiveURL: archiveURL)
            if let appearance { try await $0.migrateAppearance(legacyThemeData: legacyThemeData, input: appearance) }
            var state = try await $0.loadState()
            state.warnings.append(contentsOf: appearance?.warnings ?? [])
            return state
        }
    }

    func importBook(_ book: Book, group: String) async throws -> Bool {
        try await serialized { try await $0.performImport(book, group: group) }
    }

    func saveState(_ snapshot: LibrarySnapshot, themeLibrary: ThemeLibrarySnapshot? = nil) async throws {
        try await serialized { try await $0.performSave(snapshot, themeLibrary: themeLibrary) }
    }

    func document(chapterID: String) async throws -> ChapterDocument? {
        try await serialized { try await $0.cachedDocument(chapterID) }
    }
    func cachedChapterCount() -> Int { documents.count }

    func saveBookmark(_ bookmark: LibraryBookmarkRecord) async throws {
        try await serialized { backend in
            let document = try await backend.cachedDocument(bookmark.anchor.chapterID)
            guard case .exact = ReadingAnchorResolver.resolve(bookmark.anchor, in: document) else { throw ContentFailure.missingChapter }
            try await backend.records.save(bookmark: bookmark)
        }
    }

    func removeBookmark(id: String) async throws {
        try await serialized { try await $0.records.removeBookmark(id: id) }
    }

    /// Commit the cascade before removing files. An interrupted cleanup leaves
    /// only unreferenced files, reclaimed on the next open.
    func deleteBook(id: String) async throws -> Bool {
        try await serialized { try await $0.performDeleteBook(id: id) }
    }

    private func performDeleteBook(id: String) async throws -> Bool {
        let chapters = try await catalog(id)
        var unresolved = Set<String>()
        if let data = try await records.preference(key: Self.unresolvedKey) {
            unresolved = Set(try JSONDecoder().decode([String].self, from: data))
        }
        unresolved.remove(id)
        try await records.deleteBook(id: id, preferences: [Self.unresolvedKey: try JSONEncoder().encode(unresolved.sorted())])
        catalogs.removeValue(forKey: id); savedAnchors.removeValue(forKey: id)
        for chapter in chapters { documents.removeValue(forKey: chapter.id) }
        do { try await files.removeBatch(Set(chapters.map(\.id))); return true }
        catch { return false }
    }

    private func migrateAppearance(legacyThemeData: Data?, input: AppearanceMigrationInput) async throws {
        guard try await records.preference(key: Self.appearanceMigrationKey) == nil else { return }
        guard let themes else { throw ContentFailure.storageFailure }
        let snapshot = try legacyThemeData.map { try JSONDecoder().decode(ThemeLibrarySnapshot.self, from: $0) } ?? input.fallbackThemeLibrary
        let staged = try themes.stage(snapshot)
        do {
            var preferences: [String: Data] = [Self.themeLibraryKey: staged.data, Self.appearanceMigrationKey: Data("1".utf8)]
            if let legacyThemeData { preferences["migration.appearance.original-theme-library"] = legacyThemeData }
            if let original = input.originalFontManifest { preferences["migration.appearance.original-font-manifest"] = original }
            if let data = try await records.preference(key: Self.viewKey) {
                var view = try JSONDecoder().decode(LibraryViewPreferences.self, from: data)
                view.settings = ReadingStyleResolver.resolve(view.settings)
                if let name = view.settings.preferences.fontName { view.settings.preferences.fontResourceHash = input.fontHashes[name] }
                if view.settings.preferences.bubbleSVG != nil { view.settings.preferences.bubbleImageData = nil }
                if view.settings.preferences.customBubbleSVG != nil { view.settings.preferences.customBubbleImageData = nil }
                preferences[Self.viewKey] = try JSONEncoder().encode(view)
            }
            try await records.savePreferences(preferences)
            themes.commit(staged)
        } catch { themes.rollback(staged); throw error }
    }

    private func performBootstrap(legacySnapshot: Data?, archiveURL: URL?) async throws {
        // A failed or unsupported legacy decode must not create a completion marker.
        if try await records.preference(key: Self.migrationKey) == nil {
            let snapshot = try Self.decodeLegacy(legacySnapshot)
            let imported: [Book]
            if let archiveURL, FileManager.default.fileExists(atPath: archiveURL.path) {
                imported = try JSONDecoder().decode([Book].self, from: Data(contentsOf: archiveURL))
            } else { imported = [] }
            guard Set(imported.map(\.id)).count == imported.count else { throw ContentFailure.storageFailure }
            for book in imported { try Self.validate(book) }
            // Reclaim files from interrupted imports only after validating legacy inputs.
            try await recoverUncommittedFiles()
            for book in imported { _ = try await performImport(book, group: snapshot.importedGroups?[book.id] ?? "未分组") }
            let ids = Set(try await records.books().map(\.id))
            var normalized = snapshot
            var seen = Set<String>()
            normalized.favorites = snapshot.favorites.filter { ids.contains($0) && seen.insert($0).inserted }
            normalized.importedGroups = (snapshot.importedGroups ?? [:]).filter { ids.contains($0.key) }
            var unresolved = Set(snapshot.progress.keys.filter { !ids.contains($0) })
            let anchors = try await anchors(from: snapshot.progress, unresolved: &unresolved)
            var preferences: [String: Data] = [
                Self.viewKey: try JSONEncoder().encode(LibraryViewPreferences(normalized)),
                Self.unresolvedKey: try JSONEncoder().encode(Array(unresolved).sorted()),
                Self.migrationKey: Data("1".utf8)
            ]
            if let legacySnapshot { preferences[Self.legacySnapshotKey] = legacySnapshot }
            try await records.commitState(favorites: normalized.favorites, groups: normalized.importedGroups ?? [:], progress: anchors, preferences: preferences)
        } else { try await recoverUncommittedFiles() }
    }

    private static func decodeLegacy(_ data: Data?) throws -> LibrarySnapshot {
        guard let data else { return .init(favorites: [], progress: [:]) }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContentFailure.storageFailure }
        if object["sort"] == nil { object["sort"] = ShelfSort.recent.rawValue }
        let result = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        guard result.version == 1 else { throw ContentFailure.storageFailure }
        return result
    }

    private static func validate(_ book: Book) throws {
        guard book.id.hasPrefix("local-"), !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !book.chapters.isEmpty, book.chapters.count == book.content.count,
              book.content.allSatisfy({ !$0.isEmpty && $0.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else { throw ContentFailure.invalidResponse }
    }

    private func performImport(_ book: Book, group: String) async throws -> Bool {
        try Self.validate(book)
        if try await records.books().contains(where: { $0.id == book.id }) { return false }
        let chapters = book.chapters.enumerated().map { index, title in
            ChapterRecord(id: StableContentID.make(book.id, "local-v1", String(index)), bookID: book.id,
                          nativeChapterID: String(index), title: title, order: index, access: .readable)
        }
        let content = zip(chapters, book.content).map { ChapterDocument(chapterID: $0.0.id, paragraphs: $0.1) }
        let existing = await files.chapterIDs()
        let created = Set(content.map(\.chapterID)).subtracting(existing)
        let metadata = LibraryBookRecord(id: book.id, title: book.title, author: book.author, summary: book.intro, addedAt: Date(),
            display: .init(genre: book.genre, category: book.category, status: book.status, words: book.words, color: book.color, subtitle: book.subtitle, tags: book.tags))
        do {
            try await files.saveBatch(content)
            try Task.checkCancellation()
            try await records.importBook(metadata, chapters: chapters, group: group)
        } catch {
            // A failed rollback leaves unreferenced entries, reclaimed at the next open.
            try? await files.removeBatch(created)
            throw error
        }
        catalogs[book.id] = chapters
        for document in content { documents[document.chapterID] = document }
        return true
    }

    private func recoverUncommittedFiles() async throws {
        let valid = try await records.allChapterIDs()
        let staged = await files.chapterIDs()
        try await files.removeBatch(staged.subtracting(valid))
    }

    private func catalog(_ bookID: String) async throws -> [ChapterRecord] {
        if let saved = catalogs[bookID] { return saved }
        let result = try await records.chapters(bookID: bookID)
        catalogs[bookID] = result
        return result
    }

    private func cachedDocument(_ id: String) async throws -> ChapterDocument {
        if let saved = documents[id] { return saved }
        guard let document = try await files.document(chapterID: id) else { throw ContentFailure.storageFailure }
        documents[id] = document
        return document
    }

    private func anchors(from progress: [String: ReadingProgress], unresolved: inout Set<String>) async throws -> [ReadingAnchor] {
        var result: [ReadingAnchor] = []
        for (bookID, value) in progress {
            let chapters = try await catalog(bookID)
            guard chapters.indices.contains(value.chapter) else { unresolved.insert(bookID); continue }
            if let saved = savedAnchors[bookID], saved.chapterID == chapters[value.chapter].id,
               saved.paragraphIndex == value.paragraph, saved.utf16Offset == value.characterOffset, saved.updatedAt == value.updatedAt {
                result.append(saved); continue
            }
            let content = try await cachedDocument(chapters[value.chapter].id)
            guard content.paragraphs.indices.contains(value.paragraph) else { unresolved.insert(bookID); continue }
            result.append(try ReadingAnchor(bookID: bookID, document: content, paragraph: value.paragraph, offset: value.characterOffset, now: value.updatedAt))
        }
        return result
    }

    private func performSave(_ snapshot: LibrarySnapshot, themeLibrary: ThemeLibrarySnapshot?) async throws {
        var unresolved = Set<String>()
        let progress = try await anchors(from: snapshot.progress, unresolved: &unresolved)
        // A UI bug must not replace valid locations with guessed chapter indices.
        guard unresolved.isEmpty else { throw ContentFailure.missingChapter }
        var preferences = [Self.viewKey: try JSONEncoder().encode(LibraryViewPreferences(snapshot))]
        let staged = try themeLibrary.map { value -> ThemeLibraryRepository.Staged in
            guard let themes else { throw ContentFailure.storageFailure }
            return try themes.stage(value)
        }
        if let staged { preferences[Self.themeLibraryKey] = staged.data }
        do {
            try await records.commitState(favorites: snapshot.favorites, groups: snapshot.importedGroups ?? [:], progress: progress, preferences: preferences)
            for anchor in progress { savedAnchors[anchor.bookID] = anchor }
            if let staged { themes?.commit(staged) }
        } catch { if let staged { themes?.rollback(staged) }; throw error }
    }

    private func loadState() async throws -> ProductionLibraryState {
        let metadata = try await records.books()
        var books: [Book] = []
        for record in metadata {
            let chapters = try await catalog(record.id)
            guard let display = record.display else { throw ContentFailure.storageFailure }
            books.append(Book(id: record.id, title: record.title, author: record.author, genre: display.genre, category: display.category,
                              status: display.status, words: display.words, color: display.color, subtitle: display.subtitle,
                              intro: record.summary, tags: display.tags, chapters: chapters.map(\.title), content: Array(repeating: [], count: chapters.count)))
        }
        var snapshot = LibrarySnapshot(favorites: try await records.favoriteIDs(), progress: [:], importedGroups: try await records.groups())
        if let data = try await records.preference(key: Self.viewKey) {
            let view = try JSONDecoder().decode(LibraryViewPreferences.self, from: data)
            snapshot.settings = view.settings; snapshot.sort = view.sort
            snapshot.shelfLayout = view.shelfLayout; snapshot.hasSeenReadingGuide = view.hasSeenReadingGuide
        }
        var unresolved = Set<String>()
        if let data = try await records.preference(key: Self.unresolvedKey) {
            unresolved = Set(try JSONDecoder().decode([String].self, from: data))
        }
        savedAnchors = try await records.allProgress()
        for (id, anchor) in savedAnchors {
            let chapters = try await catalog(id)
            guard let chapter = chapters.firstIndex(where: { $0.id == anchor.chapterID }) else { unresolved.insert(id); continue }
            // Resolve prose only when opening the chapter. Startup reads catalog
            // and location metadata without loading an entire shelf's content.
            snapshot.progress[id] = .init(chapter: chapter, paragraph: anchor.paragraphIndex,
                                          updatedAt: anchor.updatedAt, characterOffset: anchor.utf16Offset)
            unresolved.remove(id)
        }
        var state = ProductionLibraryState(books: books, snapshot: snapshot, unresolvedBookIDs: unresolved)
        state.bookmarks = try await records.allBookmarks()
        state.catalogs = catalogs; state.anchors = savedAnchors
        if let data = try await records.preference(key: Self.themeLibraryKey) {
            guard let themes else { throw ContentFailure.storageFailure }
            let loaded = try themes.load(data)
            state.themeLibrary = loaded.snapshot
            if !loaded.warnings.isEmpty { state.warnings.append("部分主题资源缺失或校验失败，已保留记录并暂用有效样式。") }
        }
        return state
    }
}
