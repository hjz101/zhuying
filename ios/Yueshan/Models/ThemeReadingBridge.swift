import Foundation
import SwiftUI
import WebKit
import UIKit

struct ThemeLibrarySnapshot: Codable, Equatable {
    let themes: [DemoTheme]
    let assets: [ThemeAsset]
    let themeID: String
    let titleID: String?
    let bubbleID: String?
}

enum ThemeReaderBridge {
    @MainActor static func renderedPreview(_ settings: ReadingSettings, theme: DemoTheme) async throws -> ReadingSettings {
        var result = settings
        let custom = !settings.preferences.bubbleFollowsTheme
        let svg = custom ? settings.preferences.customBubbleSVG : settings.preferences.bubbleSVG
        if settings.preferences.showCommentBubbles, let svg {
            let data = try await ThemeBubbleRasterizer.render(svg, theme: theme)
            if custom { result.preferences.customBubbleImageData = data }
            else { result.preferences.bubbleImageData = data }
        }
        return result
    }
    static func nativeTitle(_ raw: String, accent: UInt32) -> (css: String, simplified: Bool) {
        if (try? ReaderTitleStyle.parse(css: raw, accent: accent)) != nil { return (raw, false) }
        let commentPattern = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
        let clean = commentPattern?.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "") ?? raw
        guard let expression = try? NSRegularExpression(pattern: "\\.chapter-title\\s*\\{([^}]*)\\}", options: .dotMatchesLineSeparators),
              let match = expression.firstMatch(in: clean, range: NSRange(location: 0, length: (clean as NSString).length)) else { return (".chapter-title {}", true) }
        let body = (clean as NSString).substring(with: match.range(at: 1))
        var supported: [String] = []
        for part in body.split(separator: ";") {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? ReaderTitleStyle.parse(css: ".chapter-title {\(value);}", accent: accent)) != nil { supported.append(value) }
        }
        return (".chapter-title {" + supported.joined(separator: ";") + "}", true)
    }
    static func apply(theme: DemoTheme, title: ThemeAsset?, bubble: ThemeAsset?, to settings: ReadingSettings, colorsOnly: Bool = false, resetMissingComponents: Bool = false) -> ReadingSettings {
        var result = settings
        result.preferences.colors = .init(background: theme.background, ink: theme.ink, accent: theme.accent, name: theme.name, dark: theme.mode == .dark)
        result.theme = theme.mode == .dark ? .dark : .paper
        if !colorsOnly {
            if resetMissingComponents && title == nil { result.preferences.themeTitleCSS = nil }
            if resetMissingComponents && bubble == nil { result.preferences.bubbleSVG = nil; result.preferences.bubbleImageData = nil }
            if let title, ThemeAssetValidator.isValid(title.content, kind: .title) { result.preferences.themeTitleCSS = nativeTitle(title.content, accent: theme.accent).css }
            if let bubble, ThemeAssetValidator.isValid(bubble.content, kind: .bubble), result.preferences.bubbleSVG != bubble.content { result.preferences.bubbleSVG = bubble.content; result.preferences.bubbleImageData = nil }
            if let style = theme.godStyle { result.preferences.themeGodStyle = style }
        }
        return result
    }
}

@MainActor extension FeatureDemoStore {
    func connectReader(_ library: LibraryStore) {
        if readingLibrary !== library {
            for task in bubbleRenderTasks.values { task.cancel() }
            bubbleRenderTasks = [:]; bubbleRenderKeys = [:]; completedBubbleKeys = [:]; bubbleRenderRevisions = [:]
        }
        readingLibrary = library
        if !library.isDemo, library.loadState == .ready {
            restoringSources = true; sources = library.sources; restoringSources = false
            sourcePersistence = { [weak library] in library?.updateSources($0) }
        }
        if !library.isDemo, library.loadState == .ready, let snapshot = library.themeLibrary {
            restoringThemeLibrary = true
            themes = snapshot.themes; themeAssets = snapshot.assets
            activeThemeID = snapshot.themeID; activeTitleStyleID = snapshot.titleID; activeBubbleStyleID = snapshot.bubbleID
            restoringThemeLibrary = false
            themePersistence = { [weak library] in library?.updateThemeLibrary($0) }
        }
        if let colors = library.settings.preferences.colors {
            let matches: (DemoTheme) -> Bool = { $0.name == colors.name && $0.background == colors.background && $0.ink == colors.ink && $0.accent == colors.accent }
            if !themes.contains(where: { $0.id == activeThemeID && matches($0) }), let theme = themes.first(where: matches) { activeThemeID = theme.id }
        }
        if library.loadState == .ready { refreshReaderBubbles() }
    }
    func readerPreview(theme: DemoTheme, titleID: String?, bubbleID: String?) -> ReadingSettings {
        ThemeReaderBridge.apply(theme: theme, title: themeAssets.first { $0.id == titleID }, bubble: themeAssets.first { $0.id == bubbleID }, to: readingLibrary?.settings ?? .init())
    }
    func updateReaderTheme(colorsOnly: Bool = false, resetMissingComponents: Bool = false) {
        guard let library = readingLibrary, let theme = themes.first(where: { $0.id == activeThemeID }) else { return }
        let title = themeAssets.first { $0.id == activeTitleStyleID }
        let bubble = themeAssets.first { $0.id == activeBubbleStyleID }
        library.settings = ThemeReaderBridge.apply(theme: theme, title: title, bubble: bubble, to: library.settings, colorsOnly: colorsOnly, resetMissingComponents: resetMissingComponents)
        readerThemeMessage = title.map { ThemeReaderBridge.nativeTitle($0.content, accent: theme.accent).simplified } == true
            ? "已应用阅读配色与兼容标题。原生标题不支持的伪元素、边框或背景装饰未应用；实际效果见下方阅读预览。"
            : "已应用到正文阅读器，个人自定义样式保留。"
        refreshReaderBubbles()
    }
    func updateReaderAsset(_ asset: ThemeAsset) {
        guard let library = readingLibrary, let theme = themes.first(where: { $0.id == activeThemeID }) else { return }
        guard ThemeAssetValidator.isValid(asset.content, kind: asset.kind) else { readerThemeMessage = "该资源暂时不可用，已保留当前阅读样式，请重新导入或重试加载。"; return }
        if asset.kind == .title {
            let parsed = ThemeReaderBridge.nativeTitle(asset.content, accent: theme.accent)
            library.settings.preferences.titleCSS = parsed.css
            readerThemeMessage = parsed.simplified ? "已应用兼容的标题样式，部分网页 CSS 装饰不受原生阅读器支持。" : "标题已应用到正文。"
        } else {
            library.settings.preferences.customBubbleSVG = asset.content
            library.settings.preferences.customBubbleImageData = nil
            library.settings.preferences.bubbleFollowsTheme = false
            readerThemeMessage = "已应用个人 SVG 气泡，切换主题时保留。"
            refreshReaderBubbles()
        }
    }
    func refreshReaderBubbles() {
        guard let library = readingLibrary else { return }
        let palette = ReaderPalette(settings: library.settings)
        func hex(_ color: UIColor) -> UInt32 {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255)
        }
        var theme = themes.first { $0.id == activeThemeID } ?? themes[0]
        theme.background = hex(palette.background); theme.ink = hex(palette.ink); theme.accent = hex(palette.accent)
        if let svg = library.settings.preferences.bubbleSVG {
            rasterize(svg, theme: theme, library: library, custom: false)
        } else { cancelBubbleRender(custom: false) }
        if let svg = library.settings.preferences.customBubbleSVG {
            rasterize(svg, theme: theme, library: library, custom: true)
        } else { cancelBubbleRender(custom: true) }
    }
    private func cancelBubbleRender(custom: Bool) {
        bubbleRenderTasks[custom]?.cancel(); bubbleRenderTasks[custom] = nil
        bubbleRenderKeys[custom] = nil; completedBubbleKeys[custom] = nil
        bubbleRenderRevisions[custom] = UUID()
    }
    private func rasterize(_ svg: String, theme: DemoTheme, library: LibraryStore, custom: Bool) {
        let key = ThemeBubbleRasterizer.key(svg, theme: theme)
        let existing = custom ? library.settings.preferences.customBubbleImageData : library.settings.preferences.bubbleImageData
        if completedBubbleKeys[custom] == key && existing != nil { return }
        if bubbleRenderKeys[custom] == key && bubbleRenderTasks[custom] != nil { return }
        bubbleRenderTasks[custom]?.cancel()
        let revision = UUID(); bubbleRenderRevisions[custom] = revision
        bubbleRenderKeys[custom] = key
        let requestedPalette = ReaderPalette(settings: library.settings)
        let renderer = bubbleRenderer
        bubbleRenderTasks[custom] = Task { @MainActor [weak library, weak self] in
            defer {
                if self?.bubbleRenderRevisions[custom] == revision {
                    self?.bubbleRenderTasks[custom] = nil; self?.bubbleRenderKeys[custom] = nil
                }
            }
            do {
                let data = try await renderer(svg, theme)
                try Task.checkCancellation()
                guard let library, self?.readingLibrary === library,
                      (custom ? library.settings.preferences.customBubbleSVG : library.settings.preferences.bubbleSVG) == svg else { return }
                let palette = ReaderPalette(settings: library.settings)
                guard palette.background.isEqual(requestedPalette.background), palette.ink.isEqual(requestedPalette.ink),
                      palette.accent.isEqual(requestedPalette.accent) else { return }
                self?.completedBubbleKeys[custom] = key
                if self?.readerThemeMessage == "配色已应用；该气泡无法生成原生预览，暂用默认气泡。" { self?.readerThemeMessage = nil }
                if custom { library.settings.preferences.customBubbleImageData = data }
                else { library.settings.preferences.bubbleImageData = data }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self?.readerThemeMessage = "配色已应用；该气泡无法生成原生预览，暂用默认气泡。" } }
        }
    }
    func persistThemeLibrary() {
        guard !restoringThemeLibrary else { return }
        if let themePersistence { themePersistence(themeSnapshot); return }
        guard isDemo, let defaults = themeLibraryDefaults, let data = try? JSONEncoder().encode(themeSnapshot) else { return }
        defaults.set(data, forKey: "yueshan.reader.theme-library.v1")
    }
    var themeSnapshot: ThemeLibrarySnapshot {
        .init(themes: themes, assets: themeAssets, themeID: activeThemeID, titleID: activeTitleStyleID, bubbleID: activeBubbleStyleID)
    }
    func restoreThemeLibrary() {
        guard let defaults = themeLibraryDefaults, let data = defaults.data(forKey: "yueshan.reader.theme-library.v1"),
              let snapshot = try? JSONDecoder().decode(ThemeLibrarySnapshot.self, from: data), !snapshot.themes.isEmpty else { return }
        restoringThemeLibrary = true
        defer { restoringThemeLibrary = false }
        var themeIDs = Set<String>(), assetIDs = Set<String>()
        themes = snapshot.themes.filter { themeIDs.insert($0.id).inserted }
        themeAssets = snapshot.assets.filter { assetIDs.insert($0.id).inserted && ThemeAssetValidator.isValid($0.content, kind: $0.kind) }
        activeThemeID = themes.contains { $0.id == snapshot.themeID } ? snapshot.themeID : themes[0].id
        activeTitleStyleID = themeAssets.contains { $0.id == snapshot.titleID && $0.kind == .title } ? snapshot.titleID : nil
        activeBubbleStyleID = themeAssets.contains { $0.id == snapshot.bubbleID && $0.kind == .bubble } ? snapshot.bubbleID : nil
    }
}

@MainActor final class ThemeBubbleRasterizer: NSObject, WKNavigationDelegate {
    private static let cache: NSCache<NSString, NSData> = {
        let value = NSCache<NSString, NSData>(); value.countLimit = 32; value.totalCostLimit = 2 * 1024 * 1024; return value
    }()
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private(set) static var activeRenders = 0
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    static func render(_ svg: String, theme: DemoTheme) async throws -> Data {
        try Task.checkCancellation()
        let key = key(svg, theme: theme) as NSString
        if let data = cache.object(forKey: key) { return data as Data }
        let renderer = ThemeBubbleRasterizer()
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await renderer.image(svg, theme: theme)
        } onCancel: {
            Task { @MainActor in renderer.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
    static func key(_ svg: String, theme: DemoTheme) -> String {
        StableContentID.make(svg, String(theme.background), String(theme.ink), String(theme.accent))
    }
    private func image(_ svg: String, theme: DemoTheme) async throws -> Data {
        guard ThemeAssetValidator.isValid(svg, kind: .bubble) else { throw ThemePackageError.invalid("无效气泡 SVG。") }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Self.activeRenders += 1
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = Self.dataStore
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 72, height: 44), configuration: configuration)
            view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear; view.navigationDelegate = self
            webView = view
            let content = svg.replacingOccurrences(of: "{{accent}}", with: String(format: "#%06X", theme.accent))
                .replacingOccurrences(of: "{{background}}", with: String(format: "#%06X", theme.background))
                .replacingOccurrences(of: "{{ink}}", with: String(format: "#%06X", theme.ink)).replacingOccurrences(of: "{{count}}", with: "12")
            view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none';style-src 'unsafe-inline'\"><style>html,body{margin:0;background:transparent;width:72px;height:44px}svg{width:72px;height:44px;display:block}</style></head><body>\(content)</body></html>", baseURL: nil)
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ThemePackageError.invalid("气泡预览超时。")))
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration(); config.rect = CGRect(x: 0, y: 0, width: 72, height: 44)
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let data = image?.pngData() else { self?.finish(.failure(error ?? ThemePackageError.invalid("气泡预览失败。"))); return }
            self?.finish(.success(data))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        webView?.navigationDelegate = nil; webView?.stopLoading(); webView = nil
        Self.activeRenders -= 1
        continuation.resume(with: result)
    }
}
