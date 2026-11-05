import Foundation
import CoreText
import UIKit
import CryptoKit

struct ReadingFontEntry: Codable, Identifiable, Equatable {
    var id: String { postScriptName }
    let postScriptName: String
    let displayName: String
    let filename: String
    var resource: ResourceFileReference? = nil
}

struct FontLibraryManifest: Codable {
    var version = 2
    var entries: [ReadingFontEntry]
}

@MainActor
final class ReadingFontLibrary: ObservableObject {
    static let shared = ReadingFontLibrary()
    @Published private(set) var entries: [ReadingFontEntry] = []
    @Published var message: String?
    let directory: URL
    private(set) var managed: Bool
    private let writer: any AtomicFileWriting
    init(directory: URL? = nil, managed: Bool = false, writer: any AtomicFileWriting = AtomicFileWriter()) {
        self.managed = managed; self.writer = writer
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppEnvironment().fontsComponent)
        reload()
    }
    func useManagedStorage(_ enabled: Bool) { managed = enabled }
    var recordedHashes: [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("fonts.json")), let saved = try? decodeManifest(data) else { return [:] }
        return saved.reduce(into: [:]) { result, entry in
            let digest = entry.resource?.digest ?? String(entry.filename.prefix(64))
            if digest.count == 64 && digest.allSatisfy({ "0123456789abcdef".contains($0) }) { result[entry.postScriptName] = digest }
        }
    }
    private var resources: FileResourceStore { .init(directory: directory, writer: writer) }
    private func decodeManifest(_ data: Data) throws -> [ReadingFontEntry] {
        if let legacy = try? JSONDecoder().decode([ReadingFontEntry].self, from: data) { return legacy }
        let value = try JSONDecoder().decode(FontLibraryManifest.self, from: data)
        guard value.version == 2 else { throw ContentFailure.storageFailure }
        return value.entries
    }
    /// Preserve the original legacy manifest before adopting content hashes.
    /// Missing fonts remain recorded, while the renderer uses a system fallback.
    func prepareManagedStorage() throws -> Data? {
        guard managed else { return nil }
        let manifest = directory.appendingPathComponent("fonts.json")
        let backup = directory.appendingPathComponent("fonts.v1.original.json")
        let data = FileManager.default.fileExists(atPath: manifest.path) ? try Data(contentsOf: manifest) : nil
        let saved = try data.map(decodeManifest) ?? []
        var names = Set<String>()
        guard saved.allSatisfy({ !$0.postScriptName.isEmpty && names.insert($0.postScriptName).inserted && URL(fileURLWithPath: $0.filename).lastPathComponent == $0.filename }) else { throw ContentFailure.storageFailure }
        let alreadyManaged = data.flatMap { try? JSONDecoder().decode(FontLibraryManifest.self, from: $0) } != nil
        if !alreadyManaged {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data, !FileManager.default.fileExists(atPath: backup.path) { try writer.write(data, to: backup) }
            let migrated = try saved.map { entry -> ReadingFontEntry in
                var value = entry
                let path = directory.appendingPathComponent(entry.filename)
                if FileManager.default.fileExists(atPath: path.path) {
                    let bytes = try Data(contentsOf: path)
                    guard Self.filename(for: bytes) == entry.filename else { throw ContentFailure.storageFailure }
                    value.resource = try resources.stage(bytes, kind: .font).reference
                }
                return value
            }
            try writer.write(JSONEncoder().encode(FontLibraryManifest(entries: migrated)), to: manifest)
        }
        let current = try Data(contentsOf: manifest)
        let entries = try decodeManifest(current)
        try resources.collect(referenced: Set(entries.compactMap(\.resource)), preserving: Set(entries.map(\.filename)))
        reload()
        return FileManager.default.fileExists(atPath: backup.path) ? try Data(contentsOf: backup) : data
    }
    func reload(reset: Bool = false) {
        if reset {
            let root = Self.canonical(directory).path + "/"
            for filename in Set(entries.map(\.filename)) {
                let url = directory.appendingPathComponent(filename)
                // Do not unregister a font reached through a link to the OS font directory.
                if Self.canonical(url).path.hasPrefix(root) { _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        entries = []
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("fonts.json")) else { return }
        let saved: [ReadingFontEntry]
        do { saved = try decodeManifest(data) }
        catch { message = "字体记录暂时无法读取，原文件已保留。"; return }
        var names = Set<String>()
        var registeredFiles = Set<URL>()
        for item in saved where URL(fileURLWithPath: item.filename).lastPathComponent == item.filename {
            let url = directory.appendingPathComponent(item.filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let reference = item.resource {
                guard reference.kind == .font, reference.filename == item.filename, (try? resources.read(reference)) != nil else { continue }
            }
            if registeredFiles.insert(Self.canonical(url)).inserted { _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            guard Self.usesFile(item.postScriptName, url: url), names.insert(item.postScriptName).inserted else { continue }
            entries.append(item)
        }
        message = entries.count == saved.count ? nil : "部分字体文件缺失或校验失败，正文将暂用系统字体；可重新导入修复。"
    }
    @discardableResult func importFont(at url: URL) throws -> [ReadingFontEntry] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw ReadingFontError.invalid("请选择 20 MB 以内的 TTF、OTF 或 TTC 文件。") }
        return try importFont(data: Data(contentsOf: url), originalName: url.lastPathComponent)
    }
    @discardableResult func importFont(data: Data, originalName: String) throws -> [ReadingFontEntry] {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw ReadingFontError.invalid("无法读取字体，请检查 TTF、OTF 或 TTC 文件。")
        }
        let filename = Self.filename(for: data)
        let manifestURL = directory.appendingPathComponent("fonts.json")
        let previous = managed && FileManager.default.fileExists(atPath: manifestURL.path) ? try decodeManifest(Data(contentsOf: manifestURL)) : entries
        var names = Set(entries.map(\.postScriptName))
        var additions = descriptors.compactMap { descriptor -> ReadingFontEntry? in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  names.insert(name).inserted else { return nil }
            let display = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? originalName
            return .init(postScriptName: name, displayName: display, filename: filename)
        }
        guard !additions.isEmpty else { throw ReadingFontError.invalid("该字体已在本地字体库中。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(filename)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if managed {
            let reference = try resources.stage(data, kind: .font, repairingCorruptFile: true).reference
            for index in additions.indices { additions[index].resource = reference }
        } else if !existed { try writer.write(data, to: target) }
        let registered = CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
        func rollback() {
            // A failed registration can refer to a system or previously loaded font.
            // Unregister only the registration made by this transaction.
            if registered { _ = CTFontManagerUnregisterFontsForURL(target as CFURL, .process, nil) }
            if !existed { try? FileManager.default.removeItem(at: target) }
        }
        let usable = additions.filter { Self.usesFile($0.postScriptName, url: target) }
        // UIFont(name:) alone may resolve a different font with the same PostScript name.
        // A failed registration is reusable only when every requested face is already
        // resolved from this exact file, including a canonical symlink to that file.
        guard !usable.isEmpty, registered || usable.count == additions.count else {
            rollback()
            throw ReadingFontError.invalid("字体未能加载，或与系统中同名的其他字体冲突，请尝试其他字体文件。")
        }
        let replaced = Set(usable.map(\.postScriptName))
        let next = previous.filter { !replaced.contains($0.postScriptName) } + usable
        do {
            let payload = managed ? try JSONEncoder().encode(FontLibraryManifest(entries: next)) : try JSONEncoder().encode(next)
            try writer.write(payload, to: manifestURL)
        }
        catch { rollback(); throw error }
        if managed { reload() } else { entries = next }
        return usable
    }
    static func filename(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".font"
    }
    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func usesFile(_ postScriptName: String, url: URL) -> Bool {
        guard UIFont(name: postScriptName, size: 18) != nil,
              let source = CTFontCopyAttribute(CTFontCreateWithName(postScriptName as CFString, 18, nil), kCTFontURLAttribute) as? URL else { return false }
        return canonical(source) == canonical(url)
    }
}
enum ReadingFontError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let value): value } }
}
