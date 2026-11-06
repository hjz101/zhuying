import Foundation

struct LibraryDatabaseArchive: Codable, Sendable {
    var books: [LibraryBookRecord]
    var chapters: [ChapterRecord]
    var progress: [ReadingAnchor]
    var bookmarks: [LibraryBookmarkRecord]
    var favorites: [String]
    var groups: [String: String]
    var preferences: [String: Data]
}

struct LibraryBackup: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let data: Data
        let digest: String
        init(path: String, data: Data) { self.path = path; self.data = data; digest = FileResourceStore.digest(data) }
    }
    let createdAt: Date
    let database: LibraryDatabaseArchive
    let documents: [ChapterDocument]
    let resources: [File]
    private struct Envelope: Codable { let format: String; let version: Int; let digest: String; let payload: Data }
    static let maximumBytes = 256 * 1024 * 1024
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(self)
        let data = try encoder.encode(Envelope(format: "yueshan-native-backup", version: 1, digest: FileResourceStore.digest(payload), payload: payload))
        guard data.count <= Self.maximumBytes else { throw ContentFailure.storageFailure }
        return data
    }
    static func decode(_ data: Data) throws -> LibraryBackup {
        guard data.count <= maximumBytes else { throw ContentFailure.invalidResponse }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "yueshan-native-backup", envelope.version == 1,
              FileResourceStore.digest(envelope.payload) == envelope.digest else { throw ContentFailure.invalidResponse }
        let result = try JSONDecoder().decode(Self.self, from: envelope.payload)
        try result.validate(); return result
    }
    func validate() throws {
        let bookIDs = Set(database.books.map(\.id)), chapterIDs = Set(database.chapters.map(\.id))
        guard bookIDs.count == database.books.count, chapterIDs.count == database.chapters.count,
              database.preferences[ProductionLibraryPersistence.migrationKey] == Data("1".utf8),
              Set(documents.map(\.chapterID)).count == documents.count,
              Set(database.favorites).count == database.favorites.count, Set(database.favorites).isSubset(of: bookIDs),
              Set(database.groups.keys).isSubset(of: bookIDs),
              database.chapters.allSatisfy({ bookIDs.contains($0.bookID) && $0.order >= 0 }),
              database.progress.allSatisfy({ bookIDs.contains($0.bookID) }),
              database.bookmarks.allSatisfy({ bookIDs.contains($0.anchor.bookID) }),
              Set(resources.map(\.path)).count == resources.count,
              database.preferences.keys.allSatisfy({ Self.allowedPreferenceKeys.contains($0) }) else { throw ContentFailure.invalidResponse }
        let locals = Set(database.books.filter { $0.source == nil }.map(\.id))
        let required = Set(database.chapters.filter { locals.contains($0.bookID) }.map(\.id))
        guard Set(documents.map(\.chapterID)) == required,
              documents.allSatisfy({ !$0.paragraphs.isEmpty && $0 == ChapterDocument(chapterID: $0.chapterID, paragraphs: $0.paragraphs.map(\.text)) }) else { throw ContentFailure.invalidResponse }
        for file in resources {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, ["fonts", "themes","media","processing"].contains(components[0]),
                  !components[1].contains(".."), !components[1].contains("\\"), !file.data.isEmpty,
                  FileResourceStore.digest(file.data) == file.digest else { throw ContentFailure.invalidResponse }
            if components[0] == "processing" {
                guard components[1] == "rules.json" else { throw ContentFailure.invalidResponse }; _ = try ContentProcessingStore.decode(file.data)
            } else if components[0] == "fonts" && components[1] == "fonts.json" {
                let manifest = try JSONDecoder().decode(FontLibraryManifest.self, from: file.data)
                var names = Set<String>()
                guard manifest.version == 2, manifest.entries.allSatisfy({
                    !$0.postScriptName.isEmpty && names.insert($0.postScriptName).inserted &&
                    URL(fileURLWithPath: $0.filename).lastPathComponent == $0.filename && !$0.filename.contains("\\")
                }) else { throw ContentFailure.invalidResponse }
            } else {
                let suffix = String(components[1].split(separator: ".").last ?? "")
                guard let kind = ResourceFileReference.Kind(rawValue: suffix),
                      String(components[1]) == file.digest + "." + kind.rawValue,
                      ResourceFileReference(digest: file.digest, bytes: file.data.count, kind: kind).isValid,
                      components[0] == "fonts" ? kind == .font : components[0] == "media" ? [.pdf,.image].contains(kind) : [.css, .svg, .png].contains(kind) else { throw ContentFailure.invalidResponse }
            }
        }
        let requiredMedia = Set(database.books.flatMap { ($0.media?.resources ?? []) + [$0.cover].compactMap{$0} })
        guard Set(resources.filter{$0.path.hasPrefix("media/")}.map(\.path)) == Set(requiredMedia.map{"media/" + $0.filename}) else { throw ContentFailure.invalidResponse }
        for book in database.books {
            if let media = book.media { try media.validate(); guard database.chapters.filter({$0.bookID == book.id}).count == media.pageCount else { throw ContentFailure.invalidResponse } }
            for ref in (book.media?.resources ?? []) + [book.cover].compactMap({$0}) {
                guard let file = resources.first(where:{$0.path == "media/" + ref.filename}),file.data.count == ref.bytes else { throw ContentFailure.invalidResponse }
                if ref.kind == .image { try MediaBookImporter.validateImage(file.data) }
                else if ref.kind == .pdf { let parsed = try MediaBookImporter.originalPDF(file.data,name:book.title); guard parsed.book.media?.pageCount == book.media?.pageCount else { throw ContentFailure.invalidResponse } }
                else { throw ContentFailure.invalidResponse }
            }
        }
        if let data = resources.first(where: { $0.path == "fonts/fonts.json" })?.data {
            let manifest = try JSONDecoder().decode(FontLibraryManifest.self, from: data)
            for entry in manifest.entries {
                guard let reference = entry.resource else { continue } // A previously missing legacy font keeps its fallback metadata.
                guard reference.isValid, reference.kind == .font, entry.filename == reference.digest + ".font",
                      let file = resources.first(where: { $0.path == "fonts/" + entry.filename }),
                      file.digest == reference.digest, file.data.count == reference.bytes else { throw ContentFailure.invalidResponse }
            }
        }
    }
    static let allowedPreferenceKeys: Set<String> = ["library.view-preferences.v1", "library.unresolved-history.v1", "appearance.theme-library.v1", "sources.configuration.v1", "migration.legacy-library.v1", "migration.appearance.v1"]
}

/// Restore builds an independent generation and switches one small pointer only
/// after complete validation. Existing databases and original files remain as
/// rollback generations; interruptions before activation cannot replace them.
final class LibraryWorkspace: @unchecked Sendable {
    let root: URL
    let legacyFonts: URL
    private let writer: any AtomicFileWriting
    private struct Pointer: Codable { let version: Int; let generation: String }
    init(root: URL, legacyFonts: URL, writer: any AtomicFileWriting = AtomicFileWriter()) { self.root = root; self.legacyFonts = legacyFonts; self.writer = writer }
    private func activeGeneration() throws -> URL? {
        let url = root.appendingPathComponent("active-generation.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: url))
        guard value.version == 1, UUID(uuidString: value.generation) != nil else { throw ContentFailure.storageFailure }
        return root.appendingPathComponent("RestoredGenerations", isDirectory: true).appendingPathComponent(value.generation, isDirectory: true)
    }
    func databaseDirectory() throws -> URL { try activeGeneration()?.appendingPathComponent("database", isDirectory: true) ?? root }
    func fontDirectory() throws -> URL { try activeGeneration()?.appendingPathComponent("fonts", isDirectory: true) ?? legacyFonts }
    func restore(_ backup: LibraryBackup) async throws {
        try backup.validate()
        let generation = UUID().uuidString, folder = root.appendingPathComponent("RestoredGenerations", isDirectory: true).appendingPathComponent(generation, isDirectory: true)
        do {
            let database = folder.appendingPathComponent("database", isDirectory: true)
            let files = try FileChapterRepository(directory: database.appendingPathComponent("chapters", isDirectory: true), writer: writer)
            try await files.saveBatch(backup.documents)
            for resource in backup.resources {
                try Task.checkCancellation()
                let components = resource.path.split(separator: "/")
                let directory = components[0] == "fonts" ? folder.appendingPathComponent("fonts", isDirectory: true) : database.appendingPathComponent("resources/" + components[0], isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try writer.write(resource.data, to: directory.appendingPathComponent(String(components[1])))
            }
            let records = try SQLiteLibraryRepository(url: database.appendingPathComponent("library.sqlite"))
            try await records.restoreBackup(backup.database)
            let reopened = try ProductionLibraryPersistence(directory: database)
            let restored = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
            guard restored.warnings.isEmpty else { throw ContentFailure.storageFailure }
            try Task.checkCancellation()
            try writer.write(JSONEncoder().encode(Pointer(version: 1, generation: generation)), to: root.appendingPathComponent("active-generation.json"))
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
