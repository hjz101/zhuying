import Foundation
import CryptoKit

enum ThemeAssetKind: String, Codable, CaseIterable { case title, bubble }
struct ThemeAsset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let kind: ThemeAssetKind
    let content: String
    let sourceThemeID: String?
    let sourceName: String
    var favorite = false
}

struct ThemePackageBatch {
    let themes: [DemoTheme]
    let assets: [ThemeAsset]
    let duplicates: Int
    let invalid: Int
    let issues: [String]
}

enum ThemePackageError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

enum ThemePackageParser {
    static func parse(_ data: Data, existingThemes: [DemoTheme], existingAssets: [ThemeAsset]) throws -> ThemePackageBatch {
        guard data.count <= 3 * 1024 * 1024 else { throw ThemePackageError.invalid("套装文件超过 3 MB，请拆分后导入。") }
        let object = try JSONSerialization.jsonObject(with: data)
        let root = object as? [String: Any]
        let entries: [Any]
        if let array = object as? [Any] { entries = array }
        else if let root, let themes = root["themes"] as? [Any] { entries = themes }
        else if let root, root["name"] != nil { entries = [root] }
        else if let root, root["chapterTitles"] != nil || root["commentBubbles"] != nil { entries = [] }
        else { throw ThemePackageError.invalid("请选择主题套装 JSON，或包含章节标题／段评气泡的资源文件。") }
        var themeIDs = Set(existingThemes.map(\.id)), assetIDs = Set(existingAssets.map(\.id))
        var knownAssets = Dictionary(uniqueKeysWithValues: existingAssets.map { ($0.id, $0) })
        var themes: [DemoTheme] = [], assets: [ThemeAsset] = [], duplicates = 0, invalid = 0
        var issues: [String] = []
        func readAssets(_ container: [String: Any], owner: String?, source: String) -> ([String], [String]) {
            var titleIDs: [String] = [], bubbleIDs: [String] = []
            for (key, kind, field) in [("chapterTitles", ThemeAssetKind.title, "css"), ("commentBubbles", .bubble, "svg")] {
                guard let raw = container[key] else { continue }
                guard let values = raw as? [Any] else { invalid += 1; issues.append("\(source)·\(key == "chapterTitles" ? "章节标题" : "段评气泡")格式有误"); continue }
                for value in values {
                    guard let value = value as? [String: Any], let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let content = value[field] as? String, ThemeAssetValidator.isValid(content, kind: kind) else {
                        invalid += 1; issues.append((value as? [String: Any])?["name"] as? String ?? "\(source)·未命名样式"); continue
                    }
                    let localID = (value["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? digest(content)
                    let id = "\(owner ?? "standalone"):\(kind.rawValue):\(localID)"
                    if assetIDs.insert(id).inserted {
                        let asset = ThemeAsset(id: id, name: name, kind: kind, content: content, sourceThemeID: owner, sourceName: source)
                        assets.append(asset); knownAssets[id] = asset
                    } else { duplicates += 1 }
                    guard knownAssets[id]?.kind == kind else { continue }
                    if kind == .title { if !titleIDs.contains(id) { titleIDs.append(id) } }
                    else if !bubbleIDs.contains(id) { bubbleIDs.append(id) }
                }
            }
            return (titleIDs, bubbleIDs)
        }
        for entry in entries {
            guard let row = entry as? [String: Any], let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let background = color(row["background"]), let ink = color(row["ink"]), let accent = color(row["accent"]),
                  let mode = DemoThemeMode(rawValue: row["mode"] as? String ?? "light") else { invalid += 1; continue }
            let id = (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "theme-" + digest("\(name):\(background):\(ink):\(accent)")
            guard themeIDs.insert(id).inserted else { duplicates += 1; continue }
            let issueStart = issues.count
            let attachments = readAssets(row, owner: id, source: name)
            themes.append(.init(id: id, name: name, mode: mode, background: background, ink: ink, accent: accent,
                                summary: row["summary"] as? String ?? "导入的阅读套装", source: "文件导入", version: row["version"] as? String ?? "1.0",
                                titleStyleIDs: attachments.0, bubbleStyleIDs: attachments.1, assetIssues: Array(issues.dropFirst(issueStart)), godStyle: row["godStyle"] as? String))
        }
        if let root, root["name"] == nil { _ = readAssets(root, owner: nil, source: root["source"] as? String ?? "独立导入") }
        return .init(themes: themes, assets: assets, duplicates: duplicates, invalid: invalid, issues: issues)
    }
    private static func color(_ value: Any?) -> UInt32? {
        guard let value = value as? String else { return nil }
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }
    private static func digest(_ text: String) -> String { StableContentID.hex(SHA256.hash(data: Data(text.utf8))) }
}

enum ThemeAssetValidator {
    static func localReferences(_ value: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "url\\s*\\(([^)]*)\\)", options: .caseInsensitive) else { return [] }
        let source = value as NSString
        return Set(regex.matches(in: value, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let target = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return target.hasPrefix("#") ? String(target.dropFirst()) : nil
        })
    }
    static func hasExternalURL(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "url\\s*\\(([^)]*)\\)", options: .caseInsensitive) else { return true }
        let source = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: source.length)).contains { match in
            let target = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return !target.hasPrefix("#")
        }
    }
    static func isValid(_ content: String, kind: ThemeAssetKind) -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf8.count <= 60_000 else { return false }
        if kind == .title {
            return !content.contains("<") && content.contains("{") && content.contains("}") &&
                !content.localizedCaseInsensitiveContains("@import") && content.range(of: "url\\s*\\(", options: [.regularExpression, .caseInsensitive]) == nil
        }
        let delegate = PassiveSVGValidator()
        let parser = XMLParser(data: Data(content.utf8)); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() && delegate.valid && delegate.sawSVG && delegate.hasDrawable && delegate.references.isSubset(of: delegate.identifiers)
    }
}

private final class PassiveSVGValidator: NSObject, XMLParserDelegate {
    var valid = true
    var sawSVG = false
    var hasDrawable = false
    var references = Set<String>()
    var identifiers = Set<String>()
    private var depth = 0
    private var inStyle = false
    private var styleText = ""
    private let allowed = Set(["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "defs", "style", "lineargradient", "radialgradient", "stop", "clippath", "mask", "symbol", "use", "title", "desc", "pattern", "filter", "fegaussianblur", "feoffset", "feblend", "fecolormatrix", "femerge", "femergenode", "fecomposite", "feflood", "marker"])
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let tag = elementName.lowercased()
        if depth == 0 { sawSVG = tag == "svg" }
        depth += 1
        if !allowed.contains(tag) { valid = false }
        if ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "use"].contains(tag) { hasDrawable = true }
        if tag == "style" { inStyle = true; styleText = "" }
        for (key, value) in attributes {
            let key = key.lowercased()
            if key == "id" { identifiers.insert(value) }
            if (key == "href" || key == "xlink:href") && value.hasPrefix("#") { references.insert(String(value.dropFirst())) }
            references.formUnion(ThemeAssetValidator.localReferences(value))
            if key.hasPrefix("on") || ((key == "href" || key == "xlink:href") && !value.hasPrefix("#")) { valid = false }
            if key == "style" && (value.contains("<") || value.localizedCaseInsensitiveContains("@import")) { valid = false }
            if ThemeAssetValidator.hasExternalURL(value) { valid = false }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inStyle { styleText += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "style" {
            if styleText.localizedCaseInsensitiveContains("@import") || ThemeAssetValidator.hasExternalURL(styleText) { valid = false }
            references.formUnion(ThemeAssetValidator.localReferences(styleText))
            inStyle = false
        }
        depth -= 1
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if inStyle { styleText += String(data: CDATABlock, encoding: .utf8) ?? "" } }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { valid = false }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { valid = false }
}

enum ThemeStyleSamples {
    static let titleCSS = [
        ".chapter-title{text-align:center;border-block:1px solid var(--accent);padding:10px 2px;letter-spacing:2px}.chapter-title:before{content:'✦';display:block;color:var(--accent);font-size:12px;margin-bottom:6px}",
        ".chapter-title{border-left:4px solid var(--accent);padding:8px 10px;background:color-mix(in srgb,var(--accent) 12%,transparent)}",
        ".chapter-title{text-align:center;padding:12px 2px}.chapter-title:after{content:'— 山海之间 —';display:block;color:var(--accent);font-size:10px;letter-spacing:3px;margin-top:10px}"
    ]
    static let bubbleSVG = [
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 44'><path d='M12 3H60Q69 3 69 12V29Q69 36 60 36H24L14 42V36H12Q3 36 3 27V12Q3 3 12 3Z' fill='{{accent}}'/><text x='36' y='25' text-anchor='middle' font-size='16' fill='{{background}}'>{{count}}</text></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 44'><path d='M8 4H64V35H24L14 41V35H8Z' fill='{{background}}' stroke='{{accent}}' stroke-width='2'/><text x='36' y='25' text-anchor='middle' font-size='16' fill='{{accent}}'>{{count}}</text></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 44'><ellipse cx='36' cy='20' rx='32' ry='17' fill='{{accent}}'/><path d='M19 31L13 41L30 35' fill='{{accent}}'/><text x='36' y='26' text-anchor='middle' font-size='16' fill='{{background}}'>{{count}}</text></svg>"
    ]
    static func assets(for themes: [DemoTheme]) -> [ThemeAsset] {
        themes.enumerated().flatMap { index, theme -> [ThemeAsset] in
            guard theme.id != "white" else { return [] }
            var result = [ThemeAsset(id: "\(theme.id):title:main", name: "\(theme.name)·章首", kind: .title, content: titleCSS[index % 3], sourceThemeID: theme.id, sourceName: theme.name),
                          ThemeAsset(id: "\(theme.id):bubble:main", name: "\(theme.name)·气泡", kind: .bubble, content: bubbleSVG[index % 3], sourceThemeID: theme.id, sourceName: theme.name)]
            if theme.id == "paper" {
                result.append(.init(id: "paper:title:line", name: "山林侧题", kind: .title, content: titleCSS[1], sourceThemeID: "paper", sourceName: theme.name))
                result.append(.init(id: "paper:bubble:outline", name: "山林线框", kind: .bubble, content: bubbleSVG[1], sourceThemeID: "paper", sourceName: theme.name))
            }
            return result
        }
    }
    static var importData: Data {
        let themes: [[String: Any]] = [
            ["id": "mist", "name": "雾蓝来信", "background": "#E6EEF0", "ink": "#2F4B57", "accent": "#6F9AA8"],
            ["id": "cinnamon", "name": "肉桂书页", "background": "#F0DED0", "ink": "#5F4038", "accent": "#B86F55", "chapterTitles": [["id": "main", "name": "肉桂章首", "css": titleCSS[1]]], "commentBubbles": [["id": "main", "name": "肉桂气泡", "svg": bubbleSVG[1]]]],
            ["id": "aurora", "name": "极光夜色", "mode": "dark", "background": "#202B3D", "ink": "#D2E4D9", "accent": "#79BBA0", "chapterTitles": [["id": "main", "name": "极光章首", "css": titleCSS[2]]], "commentBubbles": [["id": "main", "name": "极光气泡", "svg": bubbleSVG[2]]]],
            ["id": "broken", "name": "无效主题", "background": "invalid"]
        ]
        return try! JSONSerialization.data(withJSONObject: ["themes": themes, "source": "独立样式包", "chapterTitles": [["id": "solo", "name": "远山独立标题", "css": titleCSS[0]]], "commentBubbles": [["id": "solo", "name": "远山独立气泡", "svg": bubbleSVG[0]]]])
    }
}

@MainActor extension FeatureDemoStore {
    func themeAssets(_ theme: DemoTheme, kind: ThemeAssetKind) -> [ThemeAsset] {
        let ids = kind == .title ? theme.titleStyleIDs : theme.bubbleStyleIDs
        return ids.compactMap { id in themeAssets.first { $0.id == id && $0.kind == kind } }
    }
    func applyThemeAsset(_ id: String) {
        guard let asset = themeAssets.first(where: { $0.id == id }) else { return }
        if asset.kind == .title { activeTitleStyleID = id } else { activeBubbleStyleID = id }
        updateReaderAsset(asset)
    }
    @discardableResult func applyThemeMix(themeID: String, titleID: String?, bubbleID: String?) -> Bool {
        guard themes.contains(where: { $0.id == themeID }),
              titleID == nil || themeAssets.contains(where: { $0.id == titleID && $0.kind == .title }),
              bubbleID == nil || themeAssets.contains(where: { $0.id == bubbleID && $0.kind == .bubble }) else { return false }
        activeThemeID = themeID; activeTitleStyleID = titleID; activeBubbleStyleID = bubbleID
        updateReaderTheme(resetMissingComponents: true); return true
    }
    func toggleThemeAssetFavorite(_ id: String) {
        guard let index = themeAssets.firstIndex(where: { $0.id == id }) else { return }
        themeAssets[index].favorite.toggle()
    }
    func removeThemeAssets(_ ids: Set<String>) {
        let allowed = ids.subtracting([activeTitleStyleID, activeBubbleStyleID].compactMap { $0 })
        themeAssets.removeAll { allowed.contains($0.id) }
        for index in themes.indices {
            themes[index].titleStyleIDs.removeAll { allowed.contains($0) }
            themes[index].bubbleStyleIDs.removeAll { allowed.contains($0) }
        }
    }
    @discardableResult func importThemeData(_ data: Data) throws -> ThemeImportResult {
        let batch = try ThemePackageParser.parse(data, existingThemes: themes, existingAssets: themeAssets)
        themes.append(contentsOf: batch.themes); themeAssets.append(contentsOf: batch.assets)
        let result = ThemeImportResult(added: batch.themes.count, duplicates: batch.duplicates, invalid: batch.invalid,
                                       titlesAdded: batch.assets.filter { $0.kind == .title }.count, bubblesAdded: batch.assets.filter { $0.kind == .bubble }.count)
        themeImportMessage = "新增 \(result.added) 套主题、\(result.titlesAdded) 款标题、\(result.bubblesAdded) 款气泡 · 重复 \(result.duplicates) 项 · 无效 \(result.invalid) 项"
        if !batch.issues.isEmpty { themeImportMessage! += "\n无法预览：" + batch.issues.prefix(6).joined(separator: "、") }
        return result
    }
}
