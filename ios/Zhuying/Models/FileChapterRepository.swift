import Foundation
import CryptoKit

protocol AtomicFileWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}
struct AtomicFileWriter: AtomicFileWriting {
    func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// Content files are immutable. The manifest is the commit point, so interrupted
/// writes cannot replace the last successfully committed chapter.
actor FileChapterRepository: ChapterContentRepository {
    private struct Manifest: Codable {
        var version = 1
        var entries: [String: String] = [:]
    }
    private let root: URL
    private let writer: any AtomicFileWriting
    private var manifest: Manifest

    init(directory: URL, writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        root = directory
        self.writer = writer
        let manager = FileManager.default
        let objects = directory.appendingPathComponent("objects", isDirectory: true)
        try manager.createDirectory(at: objects, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: index.path) {
            let loaded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: index))
            guard loaded.version == 1, loaded.entries.allSatisfy({ !$0.key.isEmpty && Self.validFilename($0.value) }) else { throw ContentFailure.storageFailure }
            for filename in loaded.entries.values {
                let url = try Self.objectURL(filename, root: directory)
                guard manager.fileExists(atPath: url.path) else { throw ContentFailure.storageFailure }
            }
            manifest = loaded
        } else { manifest = .init() }
        // Only reclaim our immutable objects; preserve unknown files and bad manifests.
        let referenced = Set(manifest.entries.values)
        for url in try manager.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) {
            if Self.validFilename(url.lastPathComponent), !referenced.contains(url.lastPathComponent) {
                try manager.removeItem(at: url)
            }
        }
    }

    func document(chapterID: String) throws -> ChapterDocument? {
        guard let filename = manifest.entries[chapterID] else { return nil }
        let url = try Self.objectURL(filename, root: root)
        let data = try Data(contentsOf: url)
        guard Self.digest(data) + ".json" == filename else { throw ContentFailure.storageFailure }
        let result = try JSONDecoder().decode(ChapterDocument.self, from: data)
        guard result.chapterID == chapterID,
              result == ChapterDocument(chapterID: chapterID, paragraphs: result.paragraphs.map(\.text)) else { throw ContentFailure.storageFailure }
        return result
    }

    func save(_ document: ChapterDocument) throws {
        try saveBatch([document])
    }

    func chapterIDs() -> Set<String> { Set(manifest.entries.keys) }
    func byteCount(chapterIDs: Set<String>) throws -> Int {
        var names = Set<String>(), total = 0
        for id in chapterIDs {
            guard let name = manifest.entries[id], names.insert(name).inserted else { continue }
            let url = try Self.objectURL(name, root: root)
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        return total
    }

    func saveBatch(_ documents: [ChapterDocument]) throws {
        guard Set(documents.map(\.chapterID)).count == documents.count else { throw ContentFailure.invalidResponse }
        for document in documents {
          guard !document.chapterID.isEmpty, !document.paragraphs.isEmpty,
              document.paragraphs.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              document == ChapterDocument(chapterID: document.chapterID, paragraphs: document.paragraphs.map(\.text)) else { throw ContentFailure.invalidResponse }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var created: [URL] = []
        var next = manifest
        do {
          for document in documents {
            try Task.checkCancellation()
            let data = try encoder.encode(document)
            let filename = Self.digest(data) + ".json"
            let target = try Self.objectURL(filename, root: root)
            if FileManager.default.fileExists(atPath: target.path) {
            guard Self.digest(try Data(contentsOf: target)) == Self.digest(data) else { throw ContentFailure.storageFailure }
            } else {
                try writer.write(data, to: target)
                created.append(target)
            }
            next.entries[document.chapterID] = filename
          }
          try Task.checkCancellation()
          try writer.write(encoder.encode(next), to: root.appendingPathComponent("manifest.json"))
        } catch {
            for target in created { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        manifest = next
        // Old versions are reclaimed at the next successful open; they can safely
        // remain during a session, including across a crash after the commit point.
    }

    func remove(chapterID: String) throws {
        try removeBatch([chapterID])
    }

    func removeBatch(_ chapterIDs: Set<String>) throws {
        guard chapterIDs.contains(where: { manifest.entries[$0] != nil }) else { return }
        var next = manifest
        for id in chapterIDs { next.entries.removeValue(forKey: id) }
        try writer.write(JSONEncoder().encode(next), to: root.appendingPathComponent("manifest.json"))
        manifest = next
    }
    func collectUnreferenced() throws {
        let keep = Set(manifest.entries.values), folder = root.appendingPathComponent("objects")
        for file in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {
            if Self.validFilename(file.lastPathComponent), !keep.contains(file.lastPathComponent) { try FileManager.default.removeItem(at:file) }
        }
    }

    private static func validFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let digest = name.dropLast(5)
        return digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func objectURL(_ filename: String, root: URL) throws -> URL {
        guard validFilename(filename) else { throw ContentFailure.storageFailure }
        let folder = root.appendingPathComponent("objects").standardizedFileURL.resolvingSymlinksInPath()
        let url = folder.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == folder else { throw ContentFailure.storageFailure }
        return url
    }
    private static func digest(_ data: Data) -> String {
        StableContentID.hex(SHA256.hash(data: data))
    }
}
