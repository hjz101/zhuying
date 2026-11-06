import Foundation
import UIKit
import ImageIO
import CoreText
import ZIPFoundation

enum GlobalThemeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct ThemeResource: Codable, Equatable {
    var path: String
}

struct ThemeIconResource: Codable, Equatable {
    var symbol: String?
    var path: String?
    var selected: String?
    var disabled: String?
    var pressed: String?
    var focused: String?
    var loading: String?
    var template = true
}

struct ThemeBackgroundResource: Codable, Equatable {
    var path: String
    var mode = "fill"
    var opacity: Double = 1
    var overlayOpacity: Double = 0
}

struct ThemeMotion: Codable, Equatable {
    var pressOpacity: Double = 0.7
    var duration: Double = 0.12
}

struct AppThemeAppearance: Codable, Equatable {
    var dark = false
    var colors: [String: String]
    var icons: [String: ThemeIconResource] = [:]
    var backgrounds: [String: ThemeBackgroundResource] = [:]
    var motion = ThemeMotion()

    static let original = AppThemeAppearance(colors: [
        "background.page":"#F7F6F0", "text.primary":"#354F40", "text.secondary":"#929986",
        "border":"#E3E6D9", "accent":"#B7815A", "background.card":"#FDFCFB",
        "background.soft":"#EDF0E4", "action.primary.background":"#354F40", "action.primary.foreground":"#FFFFFF"
    ])
    static let green = AppThemeAppearance(colors: [
        "background.page":"#F7FAF8", "text.primary":"#182B25", "text.secondary":"#5F7169",
        "border":"#DCE8E1", "accent":"#16876A", "background.card":"#FFFFFF",
        "background.soft":"#EDF5F0", "action.primary.background":"#16876A", "action.primary.foreground":"#FFFFFF"
    ])
    static let night = AppThemeAppearance(dark: true, colors: [
        "background.page":"#151622", "text.primary":"#F4F2FA", "text.secondary":"#B6B1C9",
        "border":"#403C54", "accent":"#C9B5FF", "background.card":"#242434",
        "background.soft":"#2D2940", "action.primary.background":"#C9B5FF", "action.primary.foreground":"#282039"
    ])
    static let requiredColors = Set(original.colors.keys)
}

struct ThemeFontBinding: Codable, Equatable {
    var path: String
    var postScriptName: String
    var licensePath: String
}

/// Portable appearance projection. Local font IDs, override branches and render caches never leave the device.
struct PortableReaderAppearance: Codable, Equatable {
    var fontSize: Double
    var lineSpacing: Double
    var preferences: ReaderPreferences
    static let excluded = Set(["fontName", "fontResourceHash", "titleCSS", "themeTitleCSS", "bubbleFollowsTheme", "godFollowsTheme", "themeGodStyle", "bubbleSVG", "bubbleImageData", "customBubbleSVG", "customBubbleImageData"])
    static let preferenceKeys: Set<String> = ["paragraphSpacing", "leftMargin", "rightMargin", "topMargin", "bottomMargin", "marginsLinked", "firstLineIndent", "fontWeight", "colors", "headerEnabled", "footerEnabled", "headerHeight", "footerHeight", "headerGap", "footerGap", "pageElements", "horizontalEffect", "verticalEffect", "rules", "showCommentBubbles", "showGodComments", "bubbleStyle", "godStyle", "bubbleRadius", "bubbleColor", "godRadius", "godBackground", "godBorder"]
    enum CodingKeys: String, CodingKey { case fontSize, lineSpacing, preferences }
    init(_ settings: ReadingSettings) {
        fontSize = settings.fontSize; lineSpacing = settings.lineSpacing; preferences = settings.preferences
        preferences.godStyle = settings.preferences.effectiveGodStyle
        preferences.fontName = nil; preferences.fontResourceHash = nil
        preferences.titleCSS = nil; preferences.themeTitleCSS = nil
        preferences.bubbleSVG = nil; preferences.customBubbleSVG = nil
        preferences.bubbleImageData = nil; preferences.customBubbleImageData = nil
        preferences.bubbleFollowsTheme = true; preferences.godFollowsTheme = true; preferences.themeGodStyle = nil
    }
    private static func colors(_ object: Any, toNative: Bool) throws -> Any {
        let colorKeys = Set(["background", "ink", "accent", "color", "bubbleColor", "godBackground", "godBorder"])
        if let dictionary = object as? [String: Any] {
            return try dictionary.reduce(into: [String: Any]()) { result, item in
                if colorKeys.contains(item.key), !(item.value is NSNull) {
                    if toNative {
                        guard let text = item.value as? String, let hex = GlobalThemePackage.hex(text) else { throw GlobalThemeError.invalid("阅读颜色需使用 #RRGGBB。") }
                        result[item.key] = hex
                    } else if let number = item.value as? NSNumber { result[item.key] = String(format: "#%06X", number.uint32Value) }
                    else { throw GlobalThemeError.invalid("阅读颜色无效。") }
                } else { result[item.key] = try colors(item.value, toNative: toNative) }
            }
        }
        if let array = object as? [Any] { return try array.map { try colors($0, toNative: toNative) } }
        return object
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        lineSpacing = try container.decode(Double.self, forKey: .lineSpacing)
        let value = try container.decode(ThemeJSON.self, forKey: .preferences)
        guard let object = value.object as? [String: Any], Set(object.keys).isDisjoint(with: Self.excluded),
              Set(object.keys).isSubset(of: Self.preferenceKeys), Self.preferenceKeys.subtracting(["bubbleColor", "godBackground", "godBorder"]).isSubset(of: Set(object.keys)) else { throw GlobalThemeError.invalid("主题阅读字段缺失，或包含本机引用及冲突样式。") }
        let data = try JSONSerialization.data(withJSONObject: Self.colors(object, toNative: true))
        preferences = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        // Decoder normalization must not silently change imported parameters.
        let normalized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
        for (key, input) in try Self.colors(object, toNative: true) as! [String: Any] {
            guard NSDictionary(dictionary: [key: input]).isEqual(to: [key: normalized[key] ?? NSNull()]) else { throw GlobalThemeError.invalid("阅读参数超出支持范围：\(key)。") }
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontSize, forKey: .fontSize); try container.encode(lineSpacing, forKey: .lineSpacing)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
        for key in Self.excluded { object.removeValue(forKey: key) }
        let value = try JSONDecoder().decode(ThemeJSON.self, from: JSONSerialization.data(withJSONObject: Self.colors(object, toNative: false)))
        try container.encode(value, forKey: .preferences)
    }
}

/// Small lossless JSON bridge used only by the portable color adapter.
enum ThemeJSON: Codable {
    case objectValue([String: ThemeJSON]), array([ThemeJSON]), string(String), number(Double), bool(Bool), null
    var object: Any {
        switch self {
        case .objectValue(let values): return values.mapValues(\.object)
        case .array(let values): return values.map(\.object)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: ThemeJSON].self) { self = .objectValue(v) }
        else { self = .array(try c.decode([ThemeJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .objectValue(let v): try c.encode(v)
        }
    }
}

struct ThemeReadingBehavior: Codable, Equatable {
    var mode: ReadingMode
    var tapToTurn: Bool
    var haptics: Bool
}
struct PortableReaderTheme: Codable, Equatable {
    var appearance: PortableReaderAppearance
    var resources: [String: ThemeResource] = [:]
    var optionalReadingBehavior: ThemeReadingBehavior?
    var background: ThemeBackgroundResource?
    var systemFont: String?
}
struct GlobalThemeDocument: Codable, Equatable {
    var contractVersion = 1
    var app: AppThemeAppearance
    var reader: PortableReaderTheme?
    var fontBindings: [String: ThemeFontBinding] = [:]
}
struct GlobalThemeManifest: Codable, Equatable {
    struct File: Codable, Equatable {
        var path: String
        var bytes: Int
        var sha256: String
        var mediaType: String
        var role: String
    }
    var format = "zhuying-theme"
    var formatVersion = 1
    var themeID: String
    var themeVersion = "1.0.0"
    var name: String
    var author = "竹影用户"
    var packageKind = "component"
    var scopes = ["app"]
    var appearanceModes = ["light"]
    var requiredCapabilities = ["app.appearance.v1"]
    var optionalCapabilities: [String] = []
    var entry = "theme.json"
    var files: [File] = []
}
struct GlobalThemeBundle: Equatable, Identifiable {
    var manifest: GlobalThemeManifest
    var document: GlobalThemeDocument
    var resources: [String: Data] = [:]
    var id: String { manifest.themeID + "@" + manifest.themeVersion }
    static var originals: [Self] {
        [("original", "竹影原色", AppThemeAppearance.original), ("green", "清透青绿", .green), ("night", "幻想夜航", .night)].map { key, name, appearance in
            .init(manifest: .init(themeID: "zhuying.builtin." + key, name: name, appearanceModes: [appearance.dark ? "dark" : "light"]), document: .init(app: appearance))
        }
    }
}

enum GlobalThemePackage {
    static let maximumBytes = 20 * 1024 * 1024
    static let capabilities = Set(["app.appearance.v1", "reader.appearance.v1", "reader.native-title-css.v1", "reader.comment-bubble-svg.v1", "reader.font.v1"])
    static func hex(_ string: String) -> UInt32? {
        guard string.count == 7, string.first == "#" else { return nil }
        return UInt32(string.dropFirst(), radix: 16)
    }
    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 512 && !path.contains("\\") && !path.contains(":") && !parts.contains("") && !parts.contains(".") && !parts.contains("..") && !path.unicodeScalars.contains { $0.value < 32 }
    }
    static func decode(_ data: Data) throws -> GlobalThemeBundle {
        guard !data.isEmpty, data.count <= maximumBytes, try BoundedArchive.identify(data) == .zip else { throw GlobalThemeError.invalid("请选择不超过 20 MB 的竹影主题包。") }
        let entries = try BoundedArchive.read(data)
        guard entries.count <= 512 else { throw GlobalThemeError.invalid("主题包文件超过 512 项。") }
        var files: [String: Data] = [:]
        for entry in entries where !entry.directory {
            guard safePath(entry.path), files[entry.path] == nil else { throw GlobalThemeError.invalid("主题包含不安全或重复路径。") }
            files[entry.path] = entry.data
        }
        guard let manifestData = files.removeValue(forKey: "manifest.json"), manifestData.count <= 256_000 else { throw GlobalThemeError.invalid("主题缺少 manifest.json。") }
        let manifest = try JSONDecoder().decode(GlobalThemeManifest.self, from: manifestData)
        guard manifest.format == "zhuying-theme", manifest.formatVersion == 1, manifest.entry == "theme.json",
              manifest.themeID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$", options: .regularExpression) != nil,
              manifest.themeVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              !manifest.name.isEmpty, manifest.name.count <= 100,
              Set(manifest.requiredCapabilities).isSubset(of: capabilities),
              Set(manifest.scopes).isSubset(of: ["app", "reader"]), !manifest.scopes.isEmpty,
              ["full", "component"].contains(manifest.packageKind), manifest.appearanceModes.count == 1,
              Set(manifest.files.map(\.path)).count == manifest.files.count, Set(manifest.files.map(\.path)) == Set(files.keys) else { throw GlobalThemeError.invalid("主题协议、能力或文件清单不受支持。") }
        for file in manifest.files {
            guard safePath(file.path), let bytes = files[file.path], bytes.count == file.bytes, FileResourceStore.digest(bytes) == file.sha256 else { throw GlobalThemeError.invalid("主题文件校验失败：\(file.path)") }
        }
        guard let theme = files.removeValue(forKey: "theme.json"), theme.count <= 2 * 1024 * 1024 else { throw GlobalThemeError.invalid("主题缺少配置文件。") }
        let document = try JSONDecoder().decode(GlobalThemeDocument.self, from: theme)
        let bundle = GlobalThemeBundle(manifest: manifest, document: document, resources: files)
        try validate(bundle)
        return bundle
    }
    static func validate(_ bundle: GlobalThemeBundle) throws {
        let app = bundle.document.app
        guard bundle.document.contractVersion == 1, AppThemeAppearance.requiredColors.isSubset(of: Set(app.colors.keys)), app.colors.values.allSatisfy({ hex($0) != nil }),
              bundle.manifest.appearanceModes == [app.dark ? "dark" : "light"],
              app.motion.pressOpacity.isFinite, (0.2...1).contains(app.motion.pressOpacity), app.motion.duration.isFinite, (0...0.4).contains(app.motion.duration),
              bundle.document.fontBindings.keys.allSatisfy({ $0 == "reader.body" }), bundle.document.reader?.resources.keys.allSatisfy({ ["title", "bubble"].contains($0) }) != false else { throw GlobalThemeError.invalid("主题颜色、资源角色或交互参数无效。") }
        if bundle.manifest.packageKind == "full" {
            guard Set(bundle.manifest.scopes) == ["app", "reader"], bundle.document.reader != nil else { throw GlobalThemeError.invalid("完整主题必须同时携带界面与阅读外观。") }
        }
        guard bundle.manifest.scopes.contains("reader") == (bundle.document.reader != nil) else { throw GlobalThemeError.invalid("主题范围与阅读配置不匹配。") }
        for icon in app.icons.values {
            guard (icon.path == nil) != (icon.symbol == nil) else { throw GlobalThemeError.invalid("图标必须明确使用图片或系统符号。") }
            if let symbol = icon.symbol { guard UIImage(systemName: symbol) != nil else { throw GlobalThemeError.invalid("系统不支持图标：\(symbol)") } }
            for path in [icon.path, icon.selected, icon.disabled, icon.pressed, icon.focused, icon.loading].compactMap({ $0 }) { try validateImage(path, in: bundle) }
        }
        for background in app.backgrounds.values {
            try validateBackground(background, in: bundle)
        }
        for (path, data) in bundle.resources {
            guard safePath(path), !data.isEmpty, ["png", "jpg", "jpeg", "css", "svg", "ttf", "otf", "txt"].contains((path as NSString).pathExtension.lowercased()) else { throw GlobalThemeError.invalid("主题包含不支持的资源文件。") }
            switch (path as NSString).pathExtension.lowercased() {
            case "png", "jpg", "jpeg": try validateImage(path, in: bundle)
            case "css": _ = try ReaderTitleStyle.parse(css: text(path, in: bundle), accent: 0x354F40)
            case "svg": guard ThemeAssetValidator.isValid(try text(path, in: bundle), kind: .bubble) else { throw GlobalThemeError.invalid("主题 SVG 无效。") }
            case "txt": guard data.count <= 128_000, String(data: data, encoding: .utf8) != nil else { throw GlobalThemeError.invalid("主题说明文件无效。") }
            default: guard bundle.document.fontBindings.values.contains(where: { $0.path == path }) else { throw GlobalThemeError.invalid("字体缺少绑定和许可。") }
            }
        }
        for (key, value) in bundle.document.fontBindings {
            guard key == "reader.body", let bytes = bundle.resources[value.path], bytes.count <= 10 * 1024 * 1024,
                  ["ttf", "otf"].contains((value.path as NSString).pathExtension.lowercased()),
                  let license = bundle.resources[value.licensePath], !license.isEmpty, license.count <= 128_000,
                  let descriptors = CTFontManagerCreateFontDescriptorsFromData(bytes as CFData) as? [CTFontDescriptor],
                  descriptors.contains(where: { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == value.postScriptName }) else { throw GlobalThemeError.invalid("字体、字形或分发许可缺失。") }
        }
        if let reader = bundle.document.reader {
            guard reader.systemFont == nil || ["default", "serif"].contains(reader.systemFont!) else { throw GlobalThemeError.invalid("不支持的系统字体角色。") }
            if let background = reader.background { try validateBackground(background, in: bundle) }
            guard reader.appearance.fontSize.isFinite, (14...30).contains(reader.appearance.fontSize), reader.appearance.lineSpacing.isFinite, (0...24).contains(reader.appearance.lineSpacing) else { throw GlobalThemeError.invalid("正文字号或行距超出范围。") }
            guard reader.appearance.preferences.colors != nil else { throw GlobalThemeError.invalid("阅读主题必须携带实际纸色。") }
            guard ["胶囊", "描边", "圆角方形", "自定义"].contains(reader.appearance.preferences.bubbleStyle),
                  ["纯色", "液态玻璃", "画框", "自定义"].contains(reader.appearance.preferences.godStyle) else { throw GlobalThemeError.invalid("阅读气泡或段评基础样式不受支持。") }
            for rule in reader.appearance.preferences.rules {
                try rule.validate()
                guard rule.scope == "全部书籍", rule.bookID == nil, rule.sourceID == nil else { throw GlobalThemeError.invalid("主题不能携带个人书籍或书源引用。") }
            }
            if let title = reader.resources["title"] {
                let css = try text(title.path, in: bundle)
                _ = try ReaderTitleStyle.parse(css: css, accent: reader.appearance.preferences.colors?.accent ?? 0x354F40)
            }
            if let bubble = reader.resources["bubble"] {
                guard ThemeAssetValidator.isValid(try text(bubble.path, in: bundle), kind: .bubble) else { throw GlobalThemeError.invalid("气泡 SVG 无效。") }
            }
        }
    }
    static func validateBackground(_ background: ThemeBackgroundResource, in bundle: GlobalThemeBundle) throws {
        guard ["fill", "fit", "tile"].contains(background.mode), background.opacity.isFinite, (0...1).contains(background.opacity), background.overlayOpacity.isFinite, (0...1).contains(background.overlayOpacity) else { throw GlobalThemeError.invalid("背景铺放参数无效。") }
        try validateImage(background.path, in: bundle)
    }
    static func validateImage(_ path: String, in bundle: GlobalThemeBundle) throws {
        guard safePath(path), let data = bundle.resources[path], data.count <= 4 * 1024 * 1024,
              ["png", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased()),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2048, height <= 2048 else { throw GlobalThemeError.invalid("主题图片缺失、损坏或超过 2048×2048：\(path)") }
    }
    static func text(_ path: String, in bundle: GlobalThemeBundle) throws -> String {
        guard safePath(path), let data = bundle.resources[path], data.count <= 60_000, let text = String(data: data, encoding: .utf8) else { throw GlobalThemeError.invalid("主题样式缺失或过大：\(path)") }
        return text
    }
    static func encode(_ value: GlobalThemeBundle) throws -> Data {
        try validate(value)
        var files = value.resources
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        files["theme.json"] = try encoder.encode(value.document)
        guard files.count < 512, files.keys.allSatisfy(safePath), files["manifest.json"] == nil else { throw GlobalThemeError.invalid("主题资源清单无效。") }
        var bundle = value
        bundle.manifest.files = files.keys.sorted().map { path in
            let bytes = files[path]!
            let ext = (path as NSString).pathExtension.lowercased()
            let types = ["json":"application/json", "css":"text/css", "svg":"image/svg+xml", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "ttf":"font/ttf", "otf":"font/otf", "txt":"text/plain"]
            let icon = bundle.document.app.icons.values.contains { [$0.path, $0.selected, $0.disabled, $0.pressed, $0.focused, $0.loading].contains(path) }
            let role = path == "theme.json" ? "configuration" : ext == "css" ? "title-css" : ext == "svg" ? "bubble-svg" : ["ttf", "otf"].contains(ext) ? "font" : path.hasPrefix("licenses/") ? "license" : path.hasPrefix("preview/") ? "preview" : icon ? "icon" : "background"
            return .init(path: path, bytes: bytes.count, sha256: FileResourceStore.digest(bytes), mediaType: types[ext] ?? "application/octet-stream", role: role)
        }
        files["manifest.json"] = try encoder.encode(bundle.manifest)
        let archive = try Archive(accessMode: .create)
        for path in files.keys.sorted() {
            let bytes = files[path]!
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { offset, size in bytes.subdata(in: Int(offset)..<Int(offset) + size) }
        }
        guard let data = archive.data, data.count <= maximumBytes else { throw GlobalThemeError.invalid("主题包超过 20 MB。") }
        _ = try decode(data)
        return data
    }

    static func authoringKit(theme: Data) throws -> Data {
        let archive = try Archive(accessMode: .create)
        var files = ["竹影-基础模板.zhuyingtheme": theme]
        for name in ["theme-contract.json", "theme.schema.json", "manifest.schema.json"] {
            guard let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "json") else { throw GlobalThemeError.invalid("制作规范资源缺失，请重新安装完整的竹影版本。") }
            files[name] = try Data(contentsOf: url)
        }
        files["给AI的制作要求.md"] = Data("""
        # 竹影主题制作要求
        请在附带的有效基础模板上制作主题。软件名称统一为竹影（Zhuying）；不改页面布局、导航、功能和点击区域。
        解压基础模板，先读取 theme-contract.json、theme.schema.json 与 manifest.schema.json；按同一版本修改配色、图标、背景及阅读外观，不猜测字段。
        图标可按 navigation.*、symbol.原系统图标名替换；位图为PNG/JPEG，气泡为被动SVG，标题为原生白名单CSS。
        阅读排版、页眉页脚、显示开关、有效CSS/气泡和段评样式都要保留；不携带书籍、进度、账户或真实评论。段评分享的是外观。
        阅读背景位于 reader.background，页面背景在 app.backgrounds。每个主题包提供一个浅色或深色变体。
        不把接收者旧的个人覆盖当作依赖；所有资源必须在包内或由合同明确提供，不引用网络、另一主题或制作者本地路径。
        自定义字体要有真实字体文件与分发许可；否则使用系统字体并明确版式差异。尊重无障碍、动态字体和减少动态效果。
        CSS仅支持单个.chapter-title；属性及范围见合同。SVG不能含脚本、事件、外链或foreignObject。
        当前原生标题解析把px/pt同数值处理，制作时统一使用pt；border-bottom仅映射文字下划线。
        完成所有文件后重新计算manifest.files中的真实字节数和SHA-256，包含theme.json、预览和许可，排除manifest自身。
        根目录直接包含manifest.json、theme.json与资源，不要套外层文件夹。ZIP用Store/Deflate，无密码、无分卷，后缀.zhuyingtheme。
        先验证两份Schema，再在竹影导入并预览。测试完整应用、混搭、断网、重启、旧个人CSS/气泡、字体和背景，做导出/导入往返。
        未实际运行竹影时写“待原生验证”，不宣称网页截图等于原生效果，不虚构文件或哈希。
        请交付：设计说明、完整主题包、源资源、实际执行的验证报告。没有生成文件能力时，给出完整文件文本和可复现打包步骤。
        我的设计要求：（由用户补充主题名、作者、配色和喜欢的风格。）
        """.utf8)
        for path in files.keys.sorted() {
            let bytes = files[path]!
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { offset, count in bytes.subdata(in: Int(offset)..<Int(offset) + count) }
        }
        guard let data = archive.data else { throw ContentFailure.storageFailure }
        return data
    }

    static func backupResources(directory: URL) throws -> [LibraryBackup.File] {
        let index = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        let data = try Data(contentsOf: index)
        let digests = try JSONDecoder().decode([String].self, from: data)
        var result = [LibraryBackup.File(path: "global-themes/catalog.json", data: data)]
        for digest in digests {
            guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ContentFailure.storageFailure }
            let path = directory.appendingPathComponent(digest + ".zhuyingtheme")
            let metadata = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isSymbolicLink != true, (metadata.fileSize ?? Int.max) <= maximumBytes else { throw ContentFailure.storageFailure }
            let bytes = try Data(contentsOf: path)
            guard FileResourceStore.digest(bytes) == digest else { throw ContentFailure.storageFailure }
            _ = try decode(bytes)
            result.append(.init(path: "global-themes/" + digest + ".zhuyingtheme", data: bytes))
        }
        return result
    }
}
