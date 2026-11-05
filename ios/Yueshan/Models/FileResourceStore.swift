import Foundation
import CryptoKit

struct ResourceFileReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case font, css, svg, png
        var limit: Int { self == .font ? 20 * 1024 * 1024 : self == .png ? 512_000 : 60_000 }
    }
    let digest: String
    let bytes: Int
    let kind: Kind
    var filename: String { digest + "." + kind.rawValue }
    var isValid: Bool {
        digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) } && bytes > 0 && bytes <= kind.limit
    }
}

/// Immutable blobs. The owning module commits its manifest or database only
/// after staging, then reclaims unreferenced blobs on the next successful open.
/// A lock protects individual file operations; owners serialize whole commits.
final class FileResourceStore: @unchecked Sendable {
    let directory: URL
    private let writer: any AtomicFileWriting
    private let lock = NSLock()
    init(directory: URL, writer: any AtomicFileWriting = AtomicFileWriter()) {
        self.directory = directory; self.writer = writer
    }
    static func digest(_ data: Data) -> String { StableContentID.hex(SHA256.hash(data: data)) }
    func url(for reference: ResourceFileReference) throws -> URL {
        guard reference.isValid else { throw ContentFailure.storageFailure }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(reference.filename).standardizedFileURL.resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path else { throw ContentFailure.storageFailure }
        return url
    }
    func read(_ reference: ResourceFileReference) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try verified(reference)
    }
    private func verified(_ reference: ResourceFileReference) throws -> Data {
        let data = try Data(contentsOf: url(for: reference))
        guard data.count == reference.bytes, Self.digest(data) == reference.digest else { throw ContentFailure.storageFailure }
        return data
    }
    @discardableResult func stage(_ data: Data, kind: ResourceFileReference.Kind, repairingCorruptFile: Bool = false) throws -> (reference: ResourceFileReference, created: Bool) {
        lock.lock(); defer { lock.unlock() }
        let reference = ResourceFileReference(digest: Self.digest(data), bytes: data.count, kind: kind)
        guard reference.isValid else { throw ContentFailure.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = try url(for: reference)
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists {
            if (try? verified(reference)) == data { return (reference, false) }
            guard repairingCorruptFile else { throw ContentFailure.storageFailure }
            let backup = directory.appendingPathComponent(reference.filename + ".damaged-" + UUID().uuidString)
            try FileManager.default.copyItem(at: target, to: backup)
        }
        try writer.write(data, to: target)
        return (reference, !exists)
    }
    func discard(_ references: Set<ResourceFileReference>) {
        lock.lock(); defer { lock.unlock() }
        for reference in references {
            if let url = try? url(for: reference) { try? FileManager.default.removeItem(at: url) }
        }
    }
    func collect(referenced: Set<ResourceFileReference>, preserving filenames: Set<String> = []) throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard referenced.allSatisfy(\.isValid) else { throw ContentFailure.storageFailure }
        let keep = Set(referenced.map(\.filename)).union(filenames)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let pieces = url.lastPathComponent.split(separator: ".")
            guard pieces.count == 2, let kind = ResourceFileReference.Kind(rawValue: String(pieces[1])),
                  ResourceFileReference(digest: String(pieces[0]), bytes: 1, kind: kind).isValid,
                  !keep.contains(url.lastPathComponent), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
