import Foundation
import CoreText
import UIKit
import CryptoKit

struct ReadingFontEntry: Codable, Identifiable, Equatable {
    var id: String { postScriptName }
    let postScriptName: String
    let displayName: String
    let filename: String
}

@MainActor
final class ReadingFontLibrary: ObservableObject {
    static let shared = ReadingFontLibrary()
    @Published private(set) var entries: [ReadingFontEntry] = []
    @Published var message: String?
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppEnvironment().fontsComponent)
        reload()
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
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("fonts.json")),
              let saved = try? JSONDecoder().decode([ReadingFontEntry].self, from: data) else { return }
        var names = Set<String>()
        var registeredFiles = Set<URL>()
        for item in saved where URL(fileURLWithPath: item.filename).lastPathComponent == item.filename {
            let url = directory.appendingPathComponent(item.filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if registeredFiles.insert(Self.canonical(url)).inserted { _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            guard Self.usesFile(item.postScriptName, url: url), names.insert(item.postScriptName).inserted else { continue }
            entries.append(item)
        }
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
        var names = Set(entries.map(\.postScriptName))
        let additions = descriptors.compactMap { descriptor -> ReadingFontEntry? in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  names.insert(name).inserted else { return nil }
            let display = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? originalName
            return .init(postScriptName: name, displayName: display, filename: filename)
        }
        guard !additions.isEmpty else { throw ReadingFontError.invalid("该字体已在本地字体库中。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(filename)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if !existed { try data.write(to: target, options: .atomic) }
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
        let next = entries + usable
        do { try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("fonts.json"), options: .atomic) }
        catch { rollback(); throw error }
        entries = next
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
