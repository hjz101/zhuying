import Foundation

actor RecentChapterCache {
    struct Entry: Codable {
        let chapterID: String
        let bookID: String
        let fingerprint: String
        let filename: String
        let bytes: Int
        let cachedAt: Date?
        var accessedAt: Date
    }
    private struct Manifest: Codable { var version = 1; var entries: [String: Entry] = [:] }
    private let root: URL
    private let writer: any AtomicFileWriting
    private let maximumBytes: Int
    private let maximumCount: Int
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private var manifest: Manifest
    init(directory: URL, maximumBytes: Int = 32 * 1024 * 1024, maximumCount: Int = 60, maximumAge: TimeInterval = 86_400,
         now: @escaping @Sendable () -> Date = { Date() }, writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        root = directory; self.writer = writer; self.maximumBytes = maximumBytes; self.maximumCount = maximumCount
        self.maximumAge = maximumAge; self.now = now
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cache.json")
        if FileManager.default.fileExists(atPath: url.path) {
            if let saved = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)), saved.version == 1,
               saved.entries.allSatisfy({ $0.key == $0.value.chapterID && Self.valid($0.value.filename) && $0.value.bytes > 0 }) { manifest = saved }
            else {
                try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("cache.damaged-" + UUID().uuidString))
                manifest = .init()
            }
        } else { manifest = .init() }
        try collect()
    }
    static func fingerprint(book: LibraryBookRecord, chapter: ChapterRecord) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return StableContentID.make(book.id, chapter.id, String(decoding: (try? encoder.encode(chapter)) ?? Data(), as: UTF8.self))
    }
    func document(bookID: String, chapterID: String, fingerprint: String, allowStale: Bool = false) throws -> ChapterDocument? {
        guard var entry = manifest.entries[chapterID], entry.bookID == bookID, entry.fingerprint == fingerprint else { return nil }
        guard allowStale || entry.cachedAt.map({ now().timeIntervalSince($0) < maximumAge }) == true else { return nil }
        let url = try fileURL(entry.filename)
        guard let bytes = try? Data(contentsOf: url), bytes.count == entry.bytes,
              FileResourceStore.digest(bytes) + ".json" == entry.filename,
              let document = try? JSONDecoder().decode(ChapterDocument.self, from: bytes), document.chapterID == chapterID,
              document == ChapterDocument(chapterID: chapterID, paragraphs: document.paragraphs.map(\.text)) else { return nil }
        entry.accessedAt = now(); manifest.entries[chapterID] = entry
        return document
    }
    /// Prefetch never evicts the visible chapter; oversized speculative content
    /// is skipped. A failed manifest write cannot discard a committed entry.
    @discardableResult func save(_ document: ChapterDocument, bookID: String, fingerprint: String, protecting currentID: String?, speculative: Bool = false) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(document)
        guard bytes.count <= maximumBytes else { if speculative { return false }; throw ContentFailure.storageFailure }
        let filename = FileResourceStore.digest(bytes) + ".json", url = try fileURL(filename)
        let existed = FileManager.default.fileExists(atPath: url.path)
        var next = manifest
        next.entries[document.chapterID] = .init(chapterID: document.chapterID, bookID: bookID, fingerprint: fingerprint, filename: filename, bytes: bytes.count, cachedAt: now(), accessedAt: now())
        while next.entries.count > maximumCount || next.entries.values.reduce(0, { $0 + $1.bytes }) > maximumBytes {
            guard let victim = next.entries.values.filter({ $0.chapterID != currentID && $0.chapterID != document.chapterID }).min(by: { $0.accessedAt < $1.accessedAt }) else { return false }
            next.entries.removeValue(forKey: victim.chapterID)
        }
        do {
            try writer.write(bytes, to: url)
            try writer.write(encoder.encode(next), to: root.appendingPathComponent("cache.json"))
        } catch { if !existed { try? FileManager.default.removeItem(at: url) }; throw error }
        manifest = next; try? collect(); return true
    }
    func clear(bookID: String? = nil) throws {
        var next = manifest
        next.entries = next.entries.filter { bookID != nil && $0.value.bookID != bookID }
        try writer.write(JSONEncoder().encode(next), to: root.appendingPathComponent("cache.json"))
        manifest = next; try collect()
    }
    func usage() -> (bytes: Int, chapters: Int) {
        // Report bytes actually on disk, including a blob awaiting collection
        // after an interrupted commit, rather than trusting manifest sizes.
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        var sizes: [String: Int] = [:]
        for file in files where Self.valid(file.lastPathComponent) {
            guard let safe = try? fileURL(file.lastPathComponent),
                  let values = try? safe.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            sizes[file.lastPathComponent] = values.fileSize ?? 0
        }
        return (sizes.values.reduce(0, +), manifest.entries.values.filter { sizes[$0.filename] != nil }.count)
    }
    private static func valid(_ value: String) -> Bool {
        value.hasSuffix(".json") && value.count == 69 && value.prefix(64).allSatisfy { "0123456789abcdef".contains($0) }
    }
    private func fileURL(_ name: String) throws -> URL {
        guard Self.valid(name) else { throw ContentFailure.storageFailure }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == root.path else { throw ContentFailure.storageFailure }
        return target
    }
    private func collect() throws {
        let keep = Set(manifest.entries.values.map(\.filename))
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where Self.valid(url.lastPathComponent) && !keep.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
