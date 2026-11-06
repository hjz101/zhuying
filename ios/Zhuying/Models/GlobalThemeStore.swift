import Foundation
import Combine
import UIKit

struct GlobalThemeRestorePoint: Codable, Equatable {
    var appID: String?
    var readerID: String?
    var settings: ReadingSettings
}
struct GlobalThemeSelection: Codable, Equatable {
    var appID: String?
    var readerID: String?
    var previous: GlobalThemeRestorePoint?
}
struct ThemeApplicationOptions {
    var app = true
    var readerColors = true
    var readerLayout = true
    var readerDecorations = true
    var readingBehavior = false
    static let interfaceOnly = Self(readerColors: false, readerLayout: false, readerDecorations: false)
}

@MainActor
final class GlobalThemeStore: ObservableObject {
    static let shared = GlobalThemeStore()
    @Published private(set) var bundles = GlobalThemeBundle.originals
    @Published private(set) var active = GlobalThemeBundle.originals[0]
    @Published private(set) var readerBundle: GlobalThemeBundle?
    @Published private(set) var busy = false
    @Published var message: String?
    private var directory: URL?
    private weak var library: LibraryStore?
    private var packageDigests: [String: String] = [:]
    private var imageCache: [String: UIImage] = [:]
    private let writer: any AtomicFileWriting
    init(writer: any AtomicFileWriting = AtomicFileWriter()) { self.writer = writer }

    func configure(directory: URL, reset: Bool = false) {
        self.directory = directory; library = nil
        bundles = GlobalThemeBundle.originals; active = bundles[0]; readerBundle = nil
        packageDigests = [:]; imageCache = [:]; message = nil
        do {
            if reset { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let index = directory.appendingPathComponent("catalog.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let digests = try JSONDecoder().decode([String].self, from: Data(contentsOf: index))
                guard digests.count <= 64, Set(digests).count == digests.count else { throw ContentFailure.storageFailure }
                for digest in digests {
                    guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ContentFailure.storageFailure }
                    let data = try Data(contentsOf: directory.appendingPathComponent(digest + ".zhuyingtheme"))
                    guard FileResourceStore.digest(data) == digest else { throw ContentFailure.storageFailure }
                    let bundle = try GlobalThemePackage.decode(data)
                    guard !bundles.contains(where: { $0.id == bundle.id }) else { throw ContentFailure.storageFailure }
                    guard bundles.reduce(bundle.resources.values.reduce(0) { $0 + $1.count }, { $0 + $1.resources.values.reduce(0) { $0 + $1.count } }) <= 64 * 1024 * 1024 else { throw ContentFailure.storageFailure }
                    bundles.append(bundle); packageDigests[bundle.id] = digest
                }
            }
        } catch { message = "部分全局主题无法读取，原文件已保留：\(error.localizedDescription)" }
    }
    func attach(_ library: LibraryStore) {
        if library.loadState == .ready, let workspace = library.workspace,
           let location = try? workspace.databaseDirectory().appendingPathComponent("resources/global-themes"), location != directory {
            configure(directory: location)
        }
        self.library = library
        syncSelection()
    }
    func syncSelection() {
        guard let library else { return }
        let selection = library.globalThemeSelection
        active = bundles.first { $0.id == selection?.appID } ?? bundles[0]
        readerBundle = bundles.first { $0.id == selection?.readerID }
        imageCache = [:]
        if let id = selection?.appID, !bundles.contains(where: { $0.id == id }) { message = "当前全局主题资源缺失，暂用竹影原色。可重新导入原包恢复。" }
        if let bundle = readerBundle { do { try registerFont(bundle) } catch { message = error.localizedDescription } }
    }
    @discardableResult func importPackage(_ data: Data) throws -> GlobalThemeBundle {
        let bundle = try GlobalThemePackage.decode(data)
        guard !bundle.manifest.themeID.hasPrefix("zhuying.builtin.") else { throw GlobalThemeError.invalid("导入包不能覆盖内置主题。") }
        let digest = FileResourceStore.digest(data)
        if let old = bundles.first(where: { $0.id == bundle.id }) {
            var oldManifest = old.manifest, newManifest = bundle.manifest
            oldManifest.files.sort { $0.path < $1.path }; newManifest.files.sort { $0.path < $1.path }
            guard old.document == bundle.document, old.resources == bundle.resources, oldManifest == newManifest else { throw GlobalThemeError.invalid("同名版本内容冲突，请修改主题版本后重新导入。") }
            return old
        }
        guard bundles.reduce(bundle.resources.values.reduce(0) { $0 + $1.count }, { $0 + $1.resources.values.reduce(0) { $0 + $1.count } }) <= 64 * 1024 * 1024 else {
            throw GlobalThemeError.invalid("本机主题资源已达 64 MB，请先删除不再使用的主题。")
        }
        guard packageDigests.count < 64 else { throw GlobalThemeError.invalid("本机最多保存 64 套导入主题，请先删除不再使用的主题。") }
        guard let directory else { throw ContentFailure.storageFailure }
        let path = directory.appendingPathComponent(digest + ".zhuyingtheme")
        try writer.write(data, to: path)
        let next = packageDigests.merging([bundle.id: digest]) { _, new in new }
        do { try writer.write(JSONEncoder().encode(next.values.sorted()), to: directory.appendingPathComponent("catalog.json")) }
        catch { if !packageDigests.values.contains(digest) { try? FileManager.default.removeItem(at: path) }; throw error }
        packageDigests = next; bundles.append(bundle)
        return bundle
    }
    func remove(_ bundle: GlobalThemeBundle) throws {
        guard let digest = packageDigests[bundle.id], let directory else { throw GlobalThemeError.invalid("内置主题不能删除。") }
        let selection = library?.globalThemeSelection
        guard ![selection?.appID, selection?.readerID, selection?.previous?.appID, selection?.previous?.readerID].contains(bundle.id) else { throw GlobalThemeError.invalid("该主题正在使用或用于恢复，请先切换并清除恢复点。") }
        var next = packageDigests; next.removeValue(forKey: bundle.id)
        try writer.write(JSONEncoder().encode(next.values.sorted()), to: directory.appendingPathComponent("catalog.json"))
        packageDigests = next; bundles.removeAll { $0.id == bundle.id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(digest + ".zhuyingtheme"))
    }
    func apply(_ bundle: GlobalThemeBundle, options: ThemeApplicationOptions = .init()) async throws {
        guard !busy, let library, library.loadState == .ready else { throw GlobalThemeError.invalid("书库正在保存，请稍后重试。") }
        busy = true; defer { busy = false }
        try GlobalThemePackage.validate(bundle)
        guard bundles.contains(where: { $0.id == bundle.id && $0.document == bundle.document && $0.resources == bundle.resources }) else { throw GlobalThemeError.invalid("请先将主题加入库中，再应用。") }
        var selection = library.globalThemeSelection ?? .init()
        selection.previous = .init(appID: selection.appID, readerID: selection.readerID, settings: library.settings)
        if options.app && bundle.manifest.scopes.contains("app") { selection.appID = bundle.id }
        var settings = library.settings
        if let reader = bundle.document.reader {
            if options.readerLayout { try registerFont(bundle) }
            settings = try Self.settings(for: bundle, current: settings, options: options)
            if options.readerLayout, let binding = bundle.document.fontBindings["reader.body"] {
                settings.preferences.fontName = binding.postScriptName
                settings.preferences.fontResourceHash = bundle.resources[binding.path].map(FileResourceStore.digest)
            }
            if options.readerDecorations { selection.readerID = bundle.id }
            if options.readingBehavior, let behavior = reader.optionalReadingBehavior { settings.mode = behavior.mode; settings.tapToTurn = behavior.tapToTurn; settings.haptics = behavior.haptics }
        }
        try await library.commitGlobalTheme(selection, settings: settings)
        syncSelection()
    }
    func restore() async throws {
        guard !busy, let library, let old = library.globalThemeSelection?.previous else { throw GlobalThemeError.invalid("暂无可恢复的外观。") }
        busy = true; defer { busy = false }
        let current = library.globalThemeSelection
        if let bundle = bundles.first(where: { $0.id == old.readerID }) { try registerFont(bundle) }
        let selection = GlobalThemeSelection(appID: old.appID, readerID: old.readerID, previous: .init(appID: current?.appID, readerID: current?.readerID, settings: library.settings))
        try await library.commitGlobalTheme(selection, settings: old.settings)
        syncSelection()
    }
    func clearRestorePoint() async throws {
        guard !busy, let library, var selection = library.globalThemeSelection else { throw GlobalThemeError.invalid("暂无可清除的恢复点。") }
        busy = true; defer { busy = false }
        selection.previous = nil
        try await library.commitGlobalTheme(selection, settings: library.settings)
    }
    static func settings(for bundle: GlobalThemeBundle, current: ReadingSettings, options: ThemeApplicationOptions) throws -> ReadingSettings {
        guard let reader = bundle.document.reader else { return current }
        var next = current
        let source = reader.appearance
        if options.readerLayout {
            let old = next.preferences
            next.fontSize = source.fontSize; next.lineSpacing = source.lineSpacing
            next.preferences = source.preferences
            next.preferences.fontName = reader.systemFont == "serif" ? "__serif__" : nil
            if !options.readerDecorations {
                next.preferences.showCommentBubbles = old.showCommentBubbles; next.preferences.showGodComments = old.showGodComments
                next.preferences.titleCSS = old.titleCSS; next.preferences.themeTitleCSS = old.themeTitleCSS
                next.preferences.bubbleSVG = old.bubbleSVG; next.preferences.customBubbleSVG = old.customBubbleSVG
                next.preferences.bubbleImageData = old.bubbleImageData; next.preferences.customBubbleImageData = old.customBubbleImageData
                next.preferences.bubbleFollowsTheme = old.bubbleFollowsTheme; next.preferences.godFollowsTheme = old.godFollowsTheme; next.preferences.themeGodStyle = old.themeGodStyle
                next.preferences.bubbleStyle = old.bubbleStyle; next.preferences.bubbleRadius = old.bubbleRadius; next.preferences.bubbleColor = old.bubbleColor
                next.preferences.godStyle = old.godStyle; next.preferences.godRadius = old.godRadius; next.preferences.godBackground = old.godBackground; next.preferences.godBorder = old.godBorder
            }
            if !options.readerColors { next.preferences.colors = old.colors }
        }
        if options.readerColors { next.preferences.colors = source.preferences.colors; next.theme = source.preferences.colors?.dark == true ? .dark : .paper }
        if options.readerDecorations {
            next.preferences.titleCSS = nil
            next.preferences.themeTitleCSS = try reader.resources["title"].map { try GlobalThemePackage.text($0.path, in: bundle) }
            next.preferences.bubbleFollowsTheme = true; next.preferences.customBubbleSVG = nil; next.preferences.customBubbleImageData = nil
            next.preferences.bubbleSVG = try reader.resources["bubble"].map { try GlobalThemePackage.text($0.path, in: bundle) }
            next.preferences.bubbleImageData = nil
            next.preferences.godFollowsTheme = true; next.preferences.themeGodStyle = source.preferences.godStyle
            next.preferences.showCommentBubbles = source.preferences.showCommentBubbles; next.preferences.showGodComments = source.preferences.showGodComments
            next.preferences.bubbleStyle = source.preferences.bubbleStyle; next.preferences.bubbleRadius = source.preferences.bubbleRadius; next.preferences.bubbleColor = source.preferences.bubbleColor
            next.preferences.godStyle = source.preferences.godStyle; next.preferences.godRadius = source.preferences.godRadius; next.preferences.godBackground = source.preferences.godBackground; next.preferences.godBorder = source.preferences.godBorder
        }
        return next
    }
    func exportCurrent(name: String, fontLicense: String? = nil) throws -> Data {
        guard let library else { throw ContentFailure.storageFailure }
        var settings = library.settings
        let palette = ReaderPalette(settings: settings)
        func hex(_ color: UIColor) -> UInt32 {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return UInt32(red * 255) << 16 | UInt32(green * 255) << 8 | UInt32(blue * 255)
        }
        settings.preferences.colors = .init(background: hex(palette.background), ink: hex(palette.ink), accent: hex(palette.accent), name: name, dark: settings.preferences.colors?.dark ?? (settings.theme == .dark))
        settings.preferences.godStyle = settings.preferences.effectiveGodStyle
        settings.preferences.rules = settings.preferences.rules.filter { $0.scope == "全部书籍" && $0.bookID == nil && $0.sourceID == nil }
        var reader = PortableReaderTheme(appearance: .init(settings), optionalReadingBehavior: .init(mode: settings.mode, tapToTurn: settings.tapToTurn, haptics: settings.haptics))
        reader.systemFont = settings.preferences.fontName == "__serif__" ? "serif" : "default"
        var resources = active.resources.filter { path, _ in path.hasPrefix("licenses/") || active.document.app.icons.values.contains(where: { [$0.path, $0.selected, $0.disabled, $0.pressed, $0.focused, $0.loading].contains(path) }) || active.document.app.backgrounds.values.contains(where: { $0.path == path }) }
        if let css = settings.preferences.effectiveTitleCSS { reader.resources["title"] = .init(path: "assets/reader/title.css"); resources["assets/reader/title.css"] = Data(css.utf8) }
        let svg = settings.preferences.bubbleFollowsTheme ? settings.preferences.bubbleSVG : settings.preferences.customBubbleSVG
        if let svg { reader.resources["bubble"] = .init(path: "assets/reader/bubble.svg"); resources["assets/reader/bubble.svg"] = Data(svg.utf8) }
        if let source = readerBundle, var background = source.document.reader?.background, let bytes = source.resources[background.path] {
            let path = "assets/reader/background." + (background.path as NSString).pathExtension
            resources[path] = bytes; background.path = path; reader.background = background
        }
        var document = GlobalThemeDocument(app: active.document.app, reader: reader)
        if let name = settings.preferences.fontName, name != "__serif__" {
            guard let license = fontLicense?.trimmingCharacters(in: .whitespacesAndNewlines), !license.isEmpty,
                  let entry = ReadingFontLibrary.shared.entries.first(where: { $0.postScriptName == name }) else { throw GlobalThemeError.invalid("当前使用自定义字体。请提供字体分发许可原文后导出，或先在阅读偏好中切回系统字体。") }
            let bytes = try Data(contentsOf: ReadingFontLibrary.shared.directory.appendingPathComponent(entry.filename))
            let path = "assets/fonts/reader.ttf"
            resources[path] = bytes; resources["licenses/reader-font.txt"] = Data(license.utf8)
            document.fontBindings["reader.body"] = .init(path: path, postScriptName: name, licensePath: "licenses/reader-font.txt")
        }
        let manifest = GlobalThemeManifest(themeID: "zhuying.user." + UUID().uuidString.lowercased(), name: name, packageKind: "full", scopes: ["app", "reader"], appearanceModes: [document.app.dark ? "dark" : "light"], requiredCapabilities: Array(GlobalThemePackage.capabilities).sorted())
        return try GlobalThemePackage.encode(.init(manifest: manifest, document: document, resources: resources))
    }
    private func registerFont(_ bundle: GlobalThemeBundle) throws {
        guard let font = bundle.document.fontBindings["reader.body"], let data = bundle.resources[font.path] else { return }
        if let existing = ReadingFontLibrary.shared.entries.first(where: { $0.postScriptName == font.postScriptName }) {
            let bytes = try Data(contentsOf: ReadingFontLibrary.shared.directory.appendingPathComponent(existing.filename))
            guard FileResourceStore.digest(bytes) == FileResourceStore.digest(data) else { throw GlobalThemeError.invalid("本机存在同名字体但文件不同，请先处理字体冲突。") }
            return
        }
        _ = try ReadingFontLibrary.shared.importFont(data: data, originalName: (font.path as NSString).lastPathComponent)
    }
    func image(_ path: String, bundle: GlobalThemeBundle? = nil) -> UIImage? {
        let bundle = bundle ?? active
        let key = bundle.id + ":" + path
        if let image = imageCache[key] { return image }
        guard let bytes = bundle.resources[path], let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return nil }
        let result = UIImage(cgImage: image)
        if imageCache.count >= 24 { imageCache.removeAll() }
        imageCache[key] = result
        return result
    }
}
