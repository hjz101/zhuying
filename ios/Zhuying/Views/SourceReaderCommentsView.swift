import SwiftUI
import WebKit

/// Comments use the importing source's protected browser session, without a
/// separate native-service login or evaluating inline source click handlers.
struct SourceReaderCommentsView: View {
    let sourceID: String
    let paragraph: String
    let annotation: SourceReaderComment
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.themeAppearance) private var appearance
    @StateObject private var browser = NativeSourceBrowser()
    @State private var message: String?
    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(paragraph).font(.system(size: 14)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                    if let hot = annotation.hotComment {
                        Text(hot.text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16).background(appearance.palette.card, in: .rect(cornerRadius: 12)).padding(.horizontal, 22)
                            .accessibilityIdentifier("sourceHotComment")
                    }
                    if annotation.url == nil && annotation.hotComment == nil {
                        Text("该书源返回了评论数，未提供评论页地址。").font(.system(size: 12)).padding(.horizontal, 22)
                    }
                }
            }.frame(maxHeight: annotation.url == nil ? .infinity : 180)
            if browser.loading { ProgressView("正在读取评论") }
            if let view = browser.webView {
                SourceCommentWebContent(view: view).id(ObjectIdentifier(view)).accessibilityIdentifier("sourceParagraphComments")
            } else { Spacer(minLength: 0) }
            if let message = message ?? browser.message { Text(message).font(.system(size: 12)).padding(.horizontal, 22) }
        }.padding(.top, 12).appPageStyle().navigationTitle("本段评论").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("刷新") { browser.reload() }.disabled(browser.webView == nil) } }
            .task { if let url = annotation.url { await open(url) } }
            .onChange(of: browser.requestedOriginURL) { _, url in if let url { Task { await open(url) } } }
            .onDisappear { browser.close() }
    }
    @MainActor private func open(_ url: URL) async {
        do {
            guard var source = library.sources.first(where: { $0.id == sourceID && $0.enabled }) else { throw ContentFailure.sourceDisabled }
            let state = try library.legadoLoginState(for: source), origins = try LegadoNetworkOrigins.all(source: source, state: state)
            guard origins.contains(where: { SourceBrowserSessions.sameOrigin(url, $0) }) else { throw ContentFailure.sourceDisabled }
            let origin = try LegadoSourcePolicy.canonicalOrigin(url)
            let scope = SourceBrowserSessions.legadoScope(sourceID: sourceID, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile)
            browser.configure(sourceID: scope, origin: origin, sessions: library.browserSessions, javascript: true, allowedOrigins: origins, restrictToDeclaredOrigins: true)
            try await library.seedLegadoBrowserCookies(source: source, state: state, url: url)
            source.url = origin.absoluteString
            try await browser.applyNetwork(library.networkTransport(for: source))
            try Task.checkCancellation()
            browser.open(url.absoluteString)
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}
private struct SourceCommentWebContent: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
