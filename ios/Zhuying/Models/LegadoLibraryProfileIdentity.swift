import Foundation

/// A logical library identity travels with its data when iOS replaces the app
/// container. Filesystem paths and backup generation paths are not identities.
struct LegadoLibraryProfileIdentity: Codable, Equatable, Sendable {
    let version: Int
    let namespace: String
    let id: UUID
    var libraryProfile: String { namespace + ":" + id.uuidString.lowercased() }
    private static let lock = NSLock()

    static func load(directory: URL, namespace: String,
                     writer: any AtomicFileWriting = AtomicFileWriter()) throws -> Self {
        guard directory.isFileURL, namespace.range(of: #"^[a-z0-9][a-z0-9.-]{0,63}$"#, options: .regularExpression) != nil else { throw LegadoStateError.limit }
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("legado-library-profile-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let properties = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= 4096 else { throw LegadoStateError.corrupt }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard value.version == 1, value.namespace == namespace else { throw LegadoStateError.corrupt }
            return value
        }
        let value = Self(version: 1, namespace: namespace, id: UUID())
        try writer.write(JSONEncoder().encode(value), to: file)
        return value
    }
}
