import SwiftUI
import WebKit

enum ThemePreviewDocument {
    static func html(theme: DemoTheme, title: ThemeAsset?, bubble: ThemeAsset?, compact: Bool = false,
                     longTitle: Bool = false, count: Int = 12, assetOnly: ThemeAssetKind? = nil) -> String {
        let css = title.flatMap { ThemeAssetValidator.isValid($0.content, kind: .title) ? $0.content : nil } ?? ""
        let svg = bubble.flatMap { ThemeAssetValidator.isValid($0.content, kind: .bubble) ? $0.content : nil }
        let titleText = longTitle ? "第三章 穿过漫长山路之后终于等到的一封来信" : "第三章 山雨欲来"
        func replace(_ raw: String, count: Int) -> String {
            raw.replacingOccurrences(of: "{{accent}}", with: color(theme.accent)).replacingOccurrences(of: "{{ink}}", with: color(theme.ink))
                .replacingOccurrences(of: "{{background}}", with: color(theme.background)).replacingOccurrences(of: "{{count}}", with: String(max(0, count)))
        }
        func badge(_ count: Int) -> String {
            if let svg {
                let rendered = replace(svg, count: count)
                return svg.contains("{{count}}") ? rendered : "\(rendered)<span class='bubble-count'>\(count)</span>"
            }
            return "<span class='default-bubble'>\(count)</span>"
        }
        let content: String
        if assetOnly == .bubble {
            content = "<div class='bubble-samples'>" + [3, 28, 128].map { "<div class='bubble'>\(badge($0))</div>" }.joined() + "</div>"
        } else if assetOnly == .title {
            content = "<h2 class='chapter-title'>\(titleText)</h2>"
        } else {
            content = "<div class='eyebrow'>阅山 · 整套效果</div><h2 class='chapter-title'>\(titleText)</h2><div class='paragraph'><p>雨是在午后停的。山路上还留着潮湿的气息，风从远处吹来，把书页轻轻翻过一页。</p><div class='bubble'>\(badge(count))</div></div>" + (compact ? "" : "<div class='paragraph'><p>她收起信，沿着林间的小径向前走去。故事的下一页，就在山海之间。</p><div class='bubble'>\(badge(128))</div></div><div class='page-number'>— 03 —</div>")
        }
        return """
        <!doctype html><html lang='zh'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'><meta http-equiv='Content-Security-Policy' content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'none'; connect-src 'none'; frame-src 'none'"><style>
        :root{--background:\(color(theme.background));--ink:\(color(theme.ink));--accent:\(color(theme.accent));color-scheme:\(theme.mode.rawValue)}
        *{box-sizing:border-box}html,body{margin:0;width:100%;min-height:100%;background:var(--background);color:var(--ink)}
        body{padding:\(compact ? 10 : 22)px;font-family:Georgia,'Songti SC',serif;overflow:hidden;font-size:\(compact ? 10 : 15)px}
        .eyebrow{font:9px -apple-system,sans-serif;opacity:.6;margin-bottom:12px}.chapter-title{font-size:\(compact ? 14 : 22)px;line-height:1.6;margin:8px 0 16px;overflow-wrap:anywhere;font-weight:500}
        .paragraph{display:flex;align-items:center;gap:8px;margin:12px 0}p{flex:1;margin:0;line-height:1.95;min-width:0;\(compact ? "display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden" : "")}
        .bubble{position:relative;flex:0 0 \(compact ? 31 : 48)px;width:\(compact ? 31 : 48)px;line-height:0}.bubble svg{width:100%;height:auto;display:block}.bubble-count{position:absolute;left:50%;top:44%;transform:translate(-50%,-50%);font:11px -apple-system;color:var(--ink);text-shadow:0 0 2px var(--background)}.default-bubble{display:inline-block;border:1px solid var(--accent);color:var(--accent);font:11px -apple-system;padding:5px 7px;border-radius:8px;line-height:1}
        .bubble-samples{display:flex;align-items:center;justify-content:space-around;min-height:\(compact ? 70 : 150)px;gap:8px}.bubble-samples .bubble{flex:0 1 64px;width:64px}.page-number{text-align:center;opacity:.5;font-size:11px;margin-top:20px}
        \(replace(css, count: count))
        </style></head><body>\(content)</body></html>
        """
    }
    private static func color(_ value: UInt32) -> String { String(format: "#%06X", value) }
}

struct ThemeStylePreview: View {
    let theme: DemoTheme
    var title: ThemeAsset?
    var bubble: ThemeAsset?
    var compact = false
    var longTitle = false
    var count = 12
    var assetOnly: ThemeAssetKind?
    var readiness: ((Bool?) -> Void)?
    @State private var status = "正在预览"
    private var document: String { ThemePreviewDocument.html(theme: theme, title: title, bubble: bubble, compact: compact, longTitle: longTitle, count: count, assetOnly: assetOnly) }
    var body: some View {
        PassiveThemeWebView(html: document) { ready in status = ready ? "预览就绪" : "无法预览"; readiness?(ready) }
            .overlay {
                if status == "正在预览" { ProgressView().scaleEffect(compact ? 0.7 : 1) }
                if status == "无法预览" { Label("无法预览此样式", systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            }
            .frame(height: assetOnly == .bubble ? (compact ? 100 : 200) : assetOnly == .title ? (compact ? 120 : 230) : (compact ? 210 : 390))
            .background(Color(hex: theme.background)).clipShape(.rect(cornerRadius: 10))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel("阅读样式预览").accessibilityValue(status)
            .onChange(of: document) { _, _ in status = "正在预览"; readiness?(nil) }
    }
}

private struct PassiveThemeWebView: UIViewRepresentable {
    let html: String
    var completion: (Bool) -> Void
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false; view.accessibilityElementsHidden = true
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.completion = completion
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html; view.loadHTMLString(html, baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { completion(false) } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { completion(false) } }
    }
}
