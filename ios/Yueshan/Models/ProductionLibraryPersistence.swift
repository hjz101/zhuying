import Foundation

struct ProductionLibraryState {
    var books: [Book]
    var snapshot: LibrarySnapshot
    var unresolvedBookIDs: Set<String>
}

private struct LibraryViewPreferences: Codable {
    var settings: ReadingSettings
    var sort: ShelfSort
    var shelfLayout: String?
    var hasSeenReadingGuide: Bool
    init(_ snapshot: LibrarySnapshot) {
        settings = snapshot.settings; sort = snapshot.sort
        shelfLayout = snapshot.shelfLayout; hasSeenReadingGuide = snapshot.hasSeenReadingGuide ?? false
    }
}

/// Coordinates immutable chapter files with the database commit. All public
/// operations share one queue, including calls arriving while another awaits I/O.
actor ProductionLibraryPersistence {
    static let migrationKey = "migration.legacy-library.v1"
    static let legacySnapshotKey = "migration.legacy-library.original-snapshot"
    private static let viewKey = "library.view-preferences.v1"
    private static let unresolvedKey = "library.unresolved-history.v1"
    private let records: SQLiteLibraryRepository
    private let files: FileChapterRepository
    private var tail: Task<Void, Never>?
    private var documents: [String: ChapterDocument] = [:]
    private var catalogs: [String: [ChapterRecord]] = [:]

    init(directory: URL, writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        records = try SQLiteLibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        files = try FileChapterRepository(directory: directory.appendingPathComponent("chapters"), writer: writer)
    }

    // Dependency injection also permits testing a failed metadata commit after files stage.
    init(records: SQLiteLibraryRepository, files: FileChapterRepository) {
        self.records = records; self.files = files
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

    func bootstrap(legacySnapshot: Data?, archiveURL: URL?) async throws -> ProductionLibraryState {
        try await serialized { try await $0.performBootstrap(legacySnapshot: legacySnapshot, archiveURL: archiveURL) }
    }

    func importBook(_ book: Book, group: String) async throws -> Bool {
        try await serialized { try await $0.performImport(book, group: group) }
    }

    func saveState(_ snapshot: LibrarySnapshot) async throws {
        try await serialized { try await $0.performSave(snapshot) }
    }

    private func performBootstrap(legacySnapshot: Data?, archiveURL: URL?) async throws -> ProductionLibraryState {
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
        return try await loadState()
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

    private func document(_ id: String) async throws -> ChapterDocument {
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
            let content = try await document(chapters[value.chapter].id)
            guard content.paragraphs.indices.contains(value.paragraph) else { unresolved.insert(bookID); continue }
            result.append(try ReadingAnchor(bookID: bookID, document: content, paragraph: value.paragraph, offset: value.characterOffset, now: value.updatedAt))
        }
        return result
    }

    private func performSave(_ snapshot: LibrarySnapshot) async throws {
        var unresolved = Set<String>()
        let progress = try await anchors(from: snapshot.progress, unresolved: &unresolved)
        // A UI bug must not replace valid locations with guessed chapter indices.
        guard unresolved.isEmpty else { throw ContentFailure.missingChapter }
        try await records.commitState(favorites: snapshot.favorites, groups: snapshot.importedGroups ?? [:], progress: progress,
                                      preferences: [Self.viewKey: try JSONEncoder().encode(LibraryViewPreferences(snapshot))])
    }

    private func loadState() async throws -> ProductionLibraryState {
        let metadata = try await records.books()
        var books: [Book] = []
        for record in metadata {
            let chapters = try await catalog(record.id)
            var content: [[String]] = []
            for chapter in chapters { content.append(try await document(chapter.id).paragraphs.map(\.text)) }
            guard let display = record.display else { throw ContentFailure.storageFailure }
            books.append(Book(id: record.id, title: record.title, author: record.author, genre: display.genre, category: display.category,
                              status: display.status, words: display.words, color: display.color, subtitle: display.subtitle,
                              intro: record.summary, tags: display.tags, chapters: chapters.map(\.title), content: content))
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
        for (id, anchor) in try await records.allProgress() {
            let chapters = try await catalog(id)
            guard let chapter = chapters.firstIndex(where: { $0.id == anchor.chapterID }) else { unresolved.insert(id); continue }
            let content = try await document(anchor.chapterID)
            let resolved = ReadingAnchorResolver.resolve(anchor, in: content)
            switch resolved {
            case let .exact(paragraph, offset), let .recovered(paragraph, offset):
                snapshot.progress[id] = .init(chapter: chapter, paragraph: paragraph, updatedAt: anchor.updatedAt, characterOffset: offset)
                unresolved.remove(id)
            case .chapterStart:
                snapshot.progress[id] = .init(chapter: chapter, paragraph: 0, updatedAt: anchor.updatedAt)
                unresolved.remove(id)
            case .missingChapter: unresolved.insert(id)
            }
        }
        return .init(books: books, snapshot: snapshot, unresolvedBookIDs: unresolved)
    }
}
