import SwiftUI
import WebKit

struct LegadoBrowserInteractionView: View {
    let request: LegadoBrowserRequest
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var coordinator = LegadoInteractionCoordinator.shared
    @StateObject private var browser = NativeSourceBrowser()
    @State private var opening: Task<Void, Never>?
    @State private var injection: Task<Void, Never>?
    @State private var visited: [String: URL] = [:]
    @State private var loadedInitialHTML = false
    @State private var injectedView: ObjectIdentifier?
    @State private var finishing = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(browser.webView?.url?.host ?? request.url.host ?? "")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).padding(.horizontal, 18)
                HStack {
                    Button("后退") { browser.back() }.frame(minHeight: 44).disabled(!browser.canBack)
                    Button("前进") { browser.forward() }.frame(minHeight: 44).disabled(!browser.canForward)
                    Spacer(); Button(browser.loading ? "停止" : "刷新") { if browser.loading { browser.stop() } else { browser.reload() } }.frame(minHeight: 44)
                }.font(.system(size: 12)).padding(.horizontal, 18)
                if browser.loading { ProgressView("正在加载网页") }
                if let webView = browser.webView { LegadoWebContent(view: webView).id(ObjectIdentifier(webView)).accessibilityIdentifier("legadoInteractionBrowser") }
                if let text = message ?? browser.message { Text(text).font(.system(size: 12)).foregroundStyle(Palette.accent).padding(.horizontal, 18).accessibilityIdentifier("legadoInteractionMessage") }
                if let external = browser.external {
                    Text("已阻止未声明的网页登录地址：\(external.host ?? "")").font(.system(size: 12)).foregroundStyle(Palette.accent).padding(.horizontal, 18)
                }
                Text("完成网页操作后点击“完成并返回”。此操作不会自动确认登录成功。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 18).padding(.bottom, 10)
            }.appPageStyle().navigationTitle(request.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { coordinator.complete(id: request.id, result: .failure(LegadoInteractionError.cancelled)) }.accessibilityIdentifier("legadoInteractionCancel") }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成并返回") { finish() }.disabled(browser.loading || browser.webView?.url == nil || finishing || message != nil || browser.message != nil)
                            .accessibilityIdentifier("legadoInteractionComplete")
                    }
                }
        }.task { open(request.url) }
            .onChange(of: browser.requestedOriginURL) { _, url in if let url { open(url) } }
            .onChange(of: browser.loading) { _, loading in if !loading { injectScript() } }
            .onDisappear { opening?.cancel(); injection?.cancel(); browser.close(); coordinator.dismiss(id: request.id) }
    }
    private func open(_ url: URL) {
        opening?.cancel(); message = nil
        opening = Task { @MainActor in
            do {
                guard var source = library.sources.first(where: { $0.id == request.sourceID }) else { throw ContentFailure.sourceDisabled }
                let state = try library.legadoLoginState(for: source)
                guard state.scope.accountID == request.accountID, state.scope.libraryProfile == request.libraryProfile else { throw LegadoInteractionError.invalidRequest }
                if request.isOffline, url.absoluteString == "about:blank", let html = request.html {
                    browser.configure(sourceID: request.browserScopeID, origin: nil, sessions: library.browserSessions, javascript: true, allowedOrigins: request.allowedOrigins, restrictToDeclaredOrigins: true)
                    loadedInitialHTML = true; try browser.openHTML(html, baseURL: url)
                    return
                }
                let origin = try LegadoBrowserRequest.origin(url)
                let permitted = [request.url] + request.allowedOrigins
                guard permitted.contains(where: { SourceBrowserSessions.sameOrigin(url, $0) }) else { throw LegadoInteractionError.invalidRequest }
                browser.configure(sourceID: request.browserScopeID, origin: origin, sessions: library.browserSessions, javascript: true, allowedOrigins: permitted)
                try await library.seedLegadoBrowserCookies(source: source, state: state, url: url)
                source.url = origin.absoluteString
                try await browser.applyNetwork(library.networkTransport(for: source))
                try Task.checkCancellation()
                visited[origin.absoluteString] = origin
                if !loadedInitialHTML, let html = request.html {
                    loadedInitialHTML = true; try browser.openHTML(html, baseURL: url)
                } else { browser.open(url.absoluteString) }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func injectScript() {
        guard let script = request.javaScript, !script.isEmpty, let view = browser.webView, injectedView != ObjectIdentifier(view) else { return }
        injectedView = ObjectIdentifier(view)
        injection?.cancel()
        injection = Task { @MainActor in
            do { _ = try await view.evaluateJavaScript(script) }
            catch { if !Task.isCancelled { message = "网页脚本未完成：\(error.localizedDescription)" } }
        }
    }
    private func finish() {
        guard !finishing, let webView = browser.webView else { return }
        finishing = true
        opening = Task { @MainActor in
            defer { finishing = false }
            do {
                let finalURL = webView.url?.scheme == "https" ? webView.url : (request.html != nil ? request.url : nil)
                guard let finalURL else { throw LegadoInteractionError.navigationFailed("尚未加载可返回的网页") }
                let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML.slice(0,2097153)") as? String ?? ""
                guard html.utf8.count <= 2 * 1024 * 1024 else { throw LegadoRequestError.limit }
                var cookies: [String: [HTTPCookie]] = [:]
                for (key, origin) in visited {
                    let all = await library.browserSessions.store(sourceID: request.browserScopeID, origin: origin).httpCookieStore.allCookies()
                    cookies[key] = all.filter { cookie in
                        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return false }
                        parts.path = cookie.path
                        return parts.url.map { !SourceBrowserSessions.matching([cookie], url: $0).isEmpty } ?? false
                    }
                }
                try Task.checkCancellation()
                coordinator.complete(id: request.id, result: .success(.init(finalURL: finalURL, html: html, title: webView.title ?? request.title, cookiesByOrigin: cookies)))
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

private struct LegadoWebContent: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
