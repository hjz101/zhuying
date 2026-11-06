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
    var remoteBooks: [String: LibraryBookRecord] = [:]
    var sources: [DemoSource] = []
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
    var groupNames: [String]? = nil
    init(_ snapshot: LibrarySnapshot) {
        settings = snapshot.settings; sort = snapshot.sort
        if settings.preferences.bubbleSVG != nil { settings.preferences.bubbleImageData = nil }
        if settings.preferences.customBubbleSVG != nil { settings.preferences.customBubbleImageData = nil }
        shelfLayout = snapshot.shelfLayout; hasSeenReadingGuide = snapshot.hasSeenReadingGuide ?? false
        groupNames = snapshot.groupNames
    }
}

/// Coordinates immutable chapter files with the database commit. All public
/// operations share one queue, including calls arriving while another awaits I/O.
actor ProductionLibraryPersistence: ChapterDocumentLoading {
    static let migrationKey = "migration.legacy-library.v1"
    static let legacySnapshotKey = "migration.legacy-library.original-snapshot"
    static let appearanceMigrationKey = "migration.appearance.v1"
    static let themeLibraryKey = "appearance.theme-library.v1"
    static let sourcesKey = "sources.configuration.v1"
    private static let viewKey = "library.view-preferences.v1"
    private static let unresolvedKey = "library.unresolved-history.v1"
    private let records: SQLiteLibraryRepository
    private let files: FileChapterRepository
    private let themes: ThemeLibraryRepository?
    private var tail: Task<Void, Never>?
    private var documents = ChapterMemoryCache()
    private var savedAnchors: [String: ReadingAnchor] = [:]
    private var catalogs: [String: [ChapterRecord]] = [:]
    private var remoteDocuments = ChapterMemoryCache()

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

    func bootstrap(legacySnapshot: Data?, archiveURL: URL?, legacyThemeData: Data? = nil, appearance: AppearanceMigrationInput? = nil, legacySources: Data? = nil) async throws -> ProductionLibraryState {
        try await serialized {
            try await $0.performBootstrap(legacySnapshot: legacySnapshot, archiveURL: archiveURL)
            if let appearance { try await $0.migrateAppearance(legacyThemeData: legacyThemeData, input: appearance) }
            try await $0.migrateSources(legacySources)
            var state = try await $0.loadState()
            state.warnings.append(contentsOf: appearance?.warnings ?? [])
            return state
        }
    }

    func importBook(_ book: Book, group: String) async throws -> Bool {
        try await serialized { try await $0.performImport(book, group: group) }
    }

    func saveState(_ snapshot: LibrarySnapshot, themeLibrary: ThemeLibrarySnapshot? = nil, sources: [DemoSource]? = nil, confirmedAnchors: [ReadingAnchor]? = nil) async throws {
        try await serialized { try await $0.performSave(snapshot, themeLibrary: themeLibrary, sources: sources, confirmedAnchors: confirmedAnchors) }
    }

    func document(chapterID: String) async throws -> ChapterDocument? {
        try await serialized { try await $0.cachedDocument(chapterID) }
    }
    func saveRemoteBook(_ book: LibraryBookRecord, chapters: [ChapterRecord]) async throws {
        try await serialized { backend in try await backend.performSaveRemoteBook(book, chapters: chapters) }
    }
    private func performSaveRemoteBook(_ book: LibraryBookRecord, chapters: [ChapterRecord]) async throws {
        guard book.source != nil, !chapters.isEmpty else { throw ContentFailure.invalidResponse }
        try await records.save(book: book.withDisplayMetadata(), chapters: chapters)
        catalogs[book.id] = chapters
    }
    func confirmRemoteAnchor(_ anchor: ReadingAnchor, document: ChapterDocument) async throws {
        try await serialized { backend in try await backend.performConfirmRemoteAnchor(anchor, document: document) }
    }
    private func performConfirmRemoteAnchor(_ anchor: ReadingAnchor, document: ChapterDocument) async throws {
        guard case .exact = ReadingAnchorResolver.resolve(anchor, in: document) else { throw ContentFailure.missingChapter }
        try await records.save(progress: anchor)
        savedAnchors[anchor.bookID] = anchor; remoteDocuments[document.chapterID] = document
    }
    func cachedChapterCount() -> Int { documents.count }
    func localFiles() async throws -> [LocalBookFile] {
        try await serialized { backend in try await backend.performLocalFiles() }
    }
    private func performLocalFiles() async throws -> [LocalBookFile] {
        var result: [LocalBookFile] = []
        for book in try await records.books() where book.source == nil {
            let catalog = try await catalog(book.id)
            result.append(.init(id: book.id, name: book.title, bytes: try await files.byteCount(chapterIDs: Set(catalog.map(\.id))), chapters: catalog.count))
        }
        return result
    }
    func exportText(bookID: String) async throws -> Data {
        try await serialized { backend in try await backend.performExportText(bookID: bookID) }
    }
    private func performExportText(bookID: String) async throws -> Data {
        guard let book = try await records.books().first(where: { $0.id == bookID }), book.source == nil else { throw ContentFailure.invalidResponse }
        var text: [String] = []
        for chapter in try await catalog(bookID) { text.append(chapter.title); text.append(contentsOf: try await cachedDocument(chapter.id).paragraphs.map(\.text)); text.append("") }
        return Data(text.joined(separator: "\n").utf8)
    }
    func renameBook(id: String, title: String) async throws {
        try await serialized { try await $0.records.renameBook(id: id, title: title) }
    }
    func backup(fontDirectory: URL) async throws -> LibraryBackup {
        try await serialized { backend in try await backend.performBackup(fontDirectory: fontDirectory) }
    }
    private func performBackup(fontDirectory: URL) async throws -> LibraryBackup {
        let archive = try await records.backupArchive()
        let localIDs = Set(archive.books.filter { $0.source == nil }.map(\.id))
        var content: [ChapterDocument] = []
        for chapter in archive.chapters where localIDs.contains(chapter.bookID) { content.append(try await cachedDocument(chapter.id)) }
        var resources = try themes?.backupResources() ?? []
        let manifestURL = fontDirectory.appendingPathComponent("fonts.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(FontLibraryManifest.self, from: data)
            guard manifest.version == 2 else { throw ContentFailure.storageFailure }
            resources.append(.init(path: "fonts/fonts.json", data: data))
            var copied = Set<String>()
            for entry in manifest.entries where copied.insert(entry.filename).inserted {
                guard URL(fileURLWithPath: entry.filename).lastPathComponent == entry.filename else { throw ContentFailure.storageFailure }
                let url = fontDirectory.appendingPathComponent(entry.filename)
                if FileManager.default.fileExists(atPath: url.path) { resources.append(.init(path: "fonts/" + entry.filename, data: try Data(contentsOf: url))) }
                else if entry.resource != nil { throw ContentFailure.storageFailure }
            }
        }
        let result = LibraryBackup(createdAt: Date(), database: archive, documents: content, resources: resources)
        try result.validate(); return result
    }

    func saveBookmark(_ bookmark: LibraryBookmarkRecord, document supplied: ChapterDocument? = nil) async throws {
        try await serialized { backend in
            let document: ChapterDocument
            if let supplied { document = supplied } else { document = try await backend.cachedDocument(bookmark.anchor.chapterID) }
            guard case .exact = ReadingAnchorResolver.resolve(bookmark.anchor, in: document) else { throw ContentFailure.missingChapter }
            try await backend.records.save(bookmark: bookmark)
        }
    }

    private func migrateSources(_ data: Data?) async throws {
        guard try await records.preference(key: Self.sourcesKey) == nil else { return }
        let sources = try data.map { try JSONDecoder().decode([DemoSource].self, from: $0) } ?? [.init(id: "shushan", name: "书山聚合", detail: "固定原生书源", url: ShushanClient.defaultHost)]
        try Self.validateSources(sources)
        var values = [Self.sourcesKey: try JSONEncoder().encode(sources)]
        if let data { values["migration.sources.original.v1"] = data }
        try await records.savePreferences(values)
    }
    private static func validateSources(_ sources: [DemoSource]) throws {
        guard Set(sources.map(\.id)).count == sources.count, sources.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? ShushanClient.host($0.url)) != nil }) else { throw ContentFailure.invalidResponse }
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
        if let saved = remoteDocuments[id] { return saved }
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

    private func performSave(_ snapshot: LibrarySnapshot, themeLibrary: ThemeLibrarySnapshot?, sources: [DemoSource]?, confirmedAnchors: [ReadingAnchor]?) async throws {
        var unresolved = Set<String>()
        let progress: [ReadingAnchor]
        if let confirmedAnchors {
            let byBook = Dictionary(uniqueKeysWithValues: confirmedAnchors.map { ($0.bookID, $0) })
            var locations: [ReadingAnchor] = []
            for (id, value) in snapshot.progress {
                let chapters = try await self.catalog(id)
                guard let saved = byBook[id], chapters[safe: value.chapter]?.id == saved.chapterID,
                      saved.paragraphIndex == value.paragraph, saved.utf16Offset == value.characterOffset else { throw ContentFailure.missingChapter }
                locations.append(saved)
            }
            progress = locations
        } else { progress = try await anchors(from: snapshot.progress, unresolved: &unresolved) }
        // A UI bug must not replace valid locations with guessed chapter indices.
        guard unresolved.isEmpty else { throw ContentFailure.missingChapter }
        var preferences = [Self.viewKey: try JSONEncoder().encode(LibraryViewPreferences(snapshot))]
        if let sources { try Self.validateSources(sources); preferences[Self.sourcesKey] = try JSONEncoder().encode(sources) }
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
            snapshot.groupNames = view.groupNames
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
        state.remoteBooks = Dictionary(uniqueKeysWithValues: metadata.filter { $0.source != nil }.map { ($0.id, $0) })
        if let data = try await records.preference(key: Self.sourcesKey) { state.sources = try JSONDecoder().decode([DemoSource].self, from: data) }
        if let data = try await records.preference(key: Self.themeLibraryKey) {
            guard let themes else { throw ContentFailure.storageFailure }
            let loaded = try themes.load(data)
            state.themeLibrary = loaded.snapshot
            if !loaded.warnings.isEmpty { state.warnings.append("部分主题资源缺失或校验失败，已保留记录并暂用有效样式。") }
        }
        return state
    }
}
