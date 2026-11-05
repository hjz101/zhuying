import Foundation
import GRDB

struct LibraryBookmarkRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String { StableContentID.make(anchor.bookID, anchor.chapterID, anchor.paragraphID, String(anchor.utf16Offset)) }
    var title: String
    var anchor: ReadingAnchor
}

/// Serializes writes outside MainActor. Metadata never embeds a whole book's text.
actor SQLiteLibraryRepository: LibraryRecordRepository {
    private let database: DatabaseQueue

    init(url: URL? = nil) throws {
        let queue: DatabaseQueue
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            queue = try DatabaseQueue(path: url.path)
        } else { queue = try DatabaseQueue() }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-library-records") { db in
            try db.create(table: "book_records") { t in
                t.primaryKey("id", .text)
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "source_bindings") { t in
                t.primaryKey("id", .text)
                t.column("bookID", .text).notNull().references("book_records", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                t.column("nativeBookID", .text).notNull()
                t.uniqueKey(["sourceID", "nativeBookID"])
            }
            try db.create(table: "chapter_records") { t in
                t.primaryKey("id", .text)
                t.column("bookID", .text).notNull().indexed().references("book_records", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("payload", .blob).notNull()
            }
            // Intentionally no chapter foreign key: refreshed catalogs can remove chapters,
            // but must retain the user's last valid location for recovery.
            try db.create(table: "reading_progress") { t in
                t.primaryKey("bookID", .text).references("book_records", onDelete: .cascade)
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "shelf_entries") { t in
                t.primaryKey("bookID", .text).references("book_records", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "book_groups") { t in
                t.primaryKey("bookID", .text).references("book_records", onDelete: .cascade)
                t.column("name", .text).notNull()
            }
            try db.create(table: "bookmarks") { t in
                t.primaryKey("id", .text)
                t.column("bookID", .text).notNull().indexed().references("book_records", onDelete: .cascade)
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "preferences") { t in
                t.primaryKey("key", .text)
                t.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("v2-shelf-order") { db in
            try db.alter(table: "shelf_entries") { $0.add(column: "position", .integer) }
        }
        try migrator.migrate(queue)
        database = queue
    }

    func books() throws -> [LibraryBookRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM book_records ORDER BY id").map {
                try JSONDecoder().decode(LibraryBookRecord.self, from: $0["payload"] as Data)
            }
        }
    }

    func save(book: LibraryBookRecord, chapters: [ChapterRecord]) throws {
        try commitBook(book, chapters: chapters, importedGroup: nil)
    }

    func importBook(_ book: LibraryBookRecord, chapters: [ChapterRecord], group: String) throws {
        try commitBook(book, chapters: chapters, importedGroup: group)
    }

    private func commitBook(_ book: LibraryBookRecord, chapters: [ChapterRecord], importedGroup: String?) throws {
        guard !book.id.isEmpty, !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              chapters.allSatisfy({ $0.bookID == book.id && !$0.id.isEmpty && $0.order >= 0 }),
              Set(chapters.map(\.id)).count == chapters.count,
              Set(chapters.map(\.order)).count == chapters.count else { throw ContentFailure.invalidResponse }
        let bookData = try JSONEncoder().encode(book)
        let records = try chapters.map { ($0, try JSONEncoder().encode($0)) }
        try database.write { db in
            try db.execute(sql: "INSERT INTO book_records(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [book.id, bookData])
            try db.execute(sql: "DELETE FROM source_bindings WHERE bookID = ?", arguments: [book.id])
            if let source = book.source {
                try db.execute(sql: "INSERT INTO source_bindings(id, bookID, sourceID, nativeBookID) VALUES (?, ?, ?, ?)", arguments: [source.id, book.id, source.sourceID, source.nativeBookID])
            }
            try db.execute(sql: "DELETE FROM chapter_records WHERE bookID = ?", arguments: [book.id])
            for (record, data) in records {
                try db.execute(sql: "INSERT INTO chapter_records(id, bookID, position, payload) VALUES (?, ?, ?, ?)", arguments: [record.id, book.id, record.order, data])
            }
            if let group = importedGroup {
                let position = (try Int.fetchOne(db, sql: "SELECT MIN(position) FROM shelf_entries") ?? 0) - 1
                try db.execute(sql: "INSERT INTO shelf_entries(bookID, addedAt, position) VALUES (?, ?, ?) ON CONFLICT(bookID) DO NOTHING", arguments: [book.id, book.addedAt, position])
                try db.execute(sql: "INSERT INTO book_groups(bookID, name) VALUES (?, ?) ON CONFLICT(bookID) DO UPDATE SET name=excluded.name", arguments: [book.id, group])
            }
        }
    }

    func chapters(bookID: String) throws -> [ChapterRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM chapter_records WHERE bookID = ? ORDER BY position, id", arguments: [bookID]).map {
                try JSONDecoder().decode(ChapterRecord.self, from: $0["payload"] as Data)
            }
        }
    }

    func progress(bookID: String) throws -> ReadingAnchor? {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM reading_progress WHERE bookID = ?", arguments: [bookID]) else { return nil }
            return try JSONDecoder().decode(ReadingAnchor.self, from: data)
        }
    }

    func save(progress: ReadingAnchor) throws {
        let data = try JSONEncoder().encode(progress)
        try database.write { db in
            guard let chapter = try Data.fetchOne(db, sql: "SELECT payload FROM chapter_records WHERE id = ? AND bookID = ?", arguments: [progress.chapterID, progress.bookID]),
                  try JSONDecoder().decode(ChapterRecord.self, from: chapter).access == .readable else { throw ContentFailure.missingChapter }
            try db.execute(sql: "INSERT INTO reading_progress(bookID, payload) VALUES (?, ?) ON CONFLICT(bookID) DO UPDATE SET payload=excluded.payload", arguments: [progress.bookID, data])
        }
    }

    func setFavorite(bookID: String, enabled: Bool, now: Date = Date()) throws {
        try database.write { db in
            if enabled {
                let position = (try Int.fetchOne(db, sql: "SELECT MIN(position) FROM shelf_entries") ?? 0) - 1
                try db.execute(sql: "INSERT INTO shelf_entries(bookID, addedAt, position) VALUES (?, ?, ?) ON CONFLICT(bookID) DO NOTHING", arguments: [bookID, now, position])
            } else { try db.execute(sql: "DELETE FROM shelf_entries WHERE bookID = ?", arguments: [bookID]) }
        }
    }
    func favoriteIDs() throws -> [String] {
        try database.read { try String.fetchAll($0, sql: "SELECT bookID FROM shelf_entries ORDER BY position IS NULL, position, addedAt DESC, bookID") }
    }
    func setGroup(bookID: String, name: String) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO book_groups(bookID, name) VALUES (?, ?) ON CONFLICT(bookID) DO UPDATE SET name=excluded.name", arguments: [bookID, name])
        }
    }
    func groups() throws -> [String: String] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT bookID, name FROM book_groups").map { ($0["bookID"] as String, $0["name"] as String) })
        }
    }
    func save(bookmark: LibraryBookmarkRecord) throws {
        let data = try JSONEncoder().encode(bookmark)
        try database.write { db in
            guard let chapter = try Data.fetchOne(db, sql: "SELECT payload FROM chapter_records WHERE id = ? AND bookID = ?", arguments: [bookmark.anchor.chapterID, bookmark.anchor.bookID]),
                  try JSONDecoder().decode(ChapterRecord.self, from: chapter).access == .readable else { throw ContentFailure.missingChapter }
            try db.execute(sql: "INSERT INTO bookmarks(id, bookID, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [bookmark.id, bookmark.anchor.bookID, data])
        }
    }
    func bookmarks(bookID: String) throws -> [LibraryBookmarkRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM bookmarks WHERE bookID = ? ORDER BY id", arguments: [bookID]).map {
                try JSONDecoder().decode(LibraryBookmarkRecord.self, from: $0["payload"] as Data)
            }
        }
    }
    func removeBookmark(id: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM bookmarks WHERE id = ?", arguments: [id]) }
    }
    func allBookmarks() throws -> [LibraryBookmarkRecord] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM bookmarks ORDER BY id").map { try JSONDecoder().decode(LibraryBookmarkRecord.self, from: $0) }
        }
    }
    /// Explicit permanent deletion; removing a favorite never calls this.
    func deleteBook(id: String, preferences: [String: Data]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM book_records WHERE id = ?", arguments: [id])
            for (key, data) in preferences {
                try db.execute(sql: "INSERT INTO preferences(key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", arguments: [key, data])
            }
        }
    }
    func savePreference(_ data: Data, key: String) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO preferences(key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", arguments: [key, data])
        }
    }
    func preference(key: String) throws -> Data? {
        try database.read { try Data.fetchOne($0, sql: "SELECT payload FROM preferences WHERE key = ?", arguments: [key]) }
    }
    func savePreferences(_ values: [String: Data]) throws {
        try database.write { db in
            for (key, data) in values {
                try db.execute(sql: "INSERT INTO preferences(key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", arguments: [key, data])
            }
        }
    }

    func allChapterIDs() throws -> Set<String> {
        try database.read { Set(try String.fetchAll($0, sql: "SELECT id FROM chapter_records")) }
    }

    func allProgress() throws -> [String: ReadingAnchor] {
        try database.read { db in
            var result: [String: ReadingAnchor] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT bookID, payload FROM reading_progress") {
                let id: String = row["bookID"]
                let anchor = try JSONDecoder().decode(ReadingAnchor.self, from: row["payload"] as Data)
                guard anchor.bookID == id else { throw ContentFailure.storageFailure }
                result[id] = anchor
            }
            return result
        }
    }

    /// One commit point for settings, shelf order, groups and confirmed locations.
    /// Missing locations are retained rather than interpreted as a deletion.
    func commitState(favorites: [String], groups: [String: String], progress: [ReadingAnchor], preferences: [String: Data]) throws {
        guard Set(favorites).count == favorites.count else { throw ContentFailure.invalidResponse }
        let anchors = try progress.map { ($0, try JSONEncoder().encode($0)) }
        try database.write { db in
            let dates = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT bookID, addedAt FROM shelf_entries").map { ($0["bookID"] as String, $0["addedAt"] as Date) })
            for (anchor, _) in anchors {
                guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM chapter_records WHERE id = ? AND bookID = ?", arguments: [anchor.chapterID, anchor.bookID]),
                      try JSONDecoder().decode(ChapterRecord.self, from: data).access == .readable else { throw ContentFailure.missingChapter }
            }
            try db.execute(sql: "DELETE FROM shelf_entries")
            for (index, id) in favorites.enumerated() {
                try db.execute(sql: "INSERT INTO shelf_entries(bookID, addedAt, position) VALUES (?, ?, ?)", arguments: [id, dates[id] ?? Date(), index])
            }
            try db.execute(sql: "DELETE FROM book_groups")
            for (id, name) in groups {
                try db.execute(sql: "INSERT INTO book_groups(bookID, name) VALUES (?, ?)", arguments: [id, name])
            }
            for (anchor, data) in anchors {
                try db.execute(sql: "INSERT INTO reading_progress(bookID, payload) VALUES (?, ?) ON CONFLICT(bookID) DO UPDATE SET payload=excluded.payload", arguments: [anchor.bookID, data])
            }
            for (key, data) in preferences {
                try db.execute(sql: "INSERT INTO preferences(key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", arguments: [key, data])
            }
        }
    }
}
