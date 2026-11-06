import SwiftUI
import WebKit

struct ProductionBrowserView: View {
    var initialSourceID: String? = nil
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var browser = NativeSourceBrowser()
    @State private var sourceID = ""
    @State private var address = ""
    @State private var javascript = true
    @State private var cookies = false
    @State private var opening: Task<Void,Never>?
    @State private var loadedInitialSource = false
    private var source: DemoSource? { library.sources.first{$0.id == sourceID} }
    private var isLegado: Bool { source.map { (try? SourcePackages.legadoDefinition($0)) != nil } ?? false }
    private var allowedOrigins: [URL] {
        guard let source else { return [] }
        if isLegado, let state = try? library.legadoLoginState(for: source) { return (try? LegadoNetworkOrigins.all(source: source, state: state)) ?? [] }
        return SourceBrowserStart.urls(source).compactMap { try? LegadoSourcePolicy.canonicalOrigin($0) }
    }
    private var origin: URL? {
        guard let url = URL(string: address), allowedOrigins.contains(where: { SourceBrowserSessions.sameOrigin(url, $0) }) else { return nil }
        return try? LegadoSourcePolicy.canonicalOrigin(url)
    }
    private var browserScope: String {
        if isLegado, let source, let state = try? library.legadoLoginState(for: source) {
            return SourceBrowserSessions.legadoScope(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile)
        }
        return sourceID
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"内置浏览器",subtitle:"每源会话 · 网页登录 · 调试与下载预览",icon:"globe")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("书源",selection:Binding(get:{sourceID},set:selectSource)) { Text("临时浏览（独立会话）").tag(""); ForEach(library.sources) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("browserSource")
                    TextField("https://…",text:$address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("browserAddress")
                    if allowedOrigins.count > 1 {
                        Menu("选择书源服务器") { ForEach(allowedOrigins, id: \.absoluteString) { url in
                            Button(url.absoluteString) { address = url.absoluteString; open() }
                        } }
                    }
                    Toggle("允许网页脚本",isOn:$javascript)
                    if let origin,sourceID != "shushan", !isLegado {
                        Toggle("在此书源请求中复用网页登录",isOn:Binding(get:{cookies},set:{cookies = $0; library.browserSessions.setNativeCookies($0,sourceID:sourceID,origin:origin)}))
                    }
                    Button("打开网页") { open() }.accessibilityIdentifier("browserOpen")
                }
                HStack {
                    Button("后退") { browser.back() }.disabled(!browser.canBack)
                    Button("前进") { browser.forward() }.disabled(!browser.canForward)
                    Spacer(); Button(browser.loading ? "停止" : "刷新") { if browser.loading { browser.stop() } else { browser.reload() } }
                }.font(.system(size:12))
                if browser.loading { ProgressView("正在加载网页") }
                if let webView = browser.webView { BrowserWebContent(view:webView).id(ObjectIdentifier(webView)).frame(height:440).clipShape(.rect(cornerRadius:12)).accessibilityIdentifier("sourceWebBrowser") }
                Text(browser.title).font(.system(size:12)).lineLimit(2)
                HStack { Button("查看页面结构") { browser.inspect() }; Spacer(); Button("下载当前链接") { browser.downloadCurrent() }.disabled(browser.downloading) }.font(.system(size:12))
                if browser.downloading { ProgressView("正在下载"); Button("取消下载") { browser.cancelDownload() } }
                Button("清除此书源浏览器数据",role:.destructive) { Task { await browser.clearSession() } }.font(.system(size:12))
                if sourceID == "shushan" { NavigationLink("书山应用内登录") { ShushanLoginView() }; Text("书山原生请求使用应用内登录；浏览器会话独立。") .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted) }
                if isLegado { NavigationLink("打开书源登录表单") { LegadoSourceLoginRoute(sourceID: sourceID) } }
                Text("书源间和主机间独立会话；外站需切换临时会话。仅复用当前书源的匹配 Cookie，不转发给其他来源。下载最多 20 MB，支持 TXT／EPUB／PDF 和 ZIP／RAR／7z 图片归档，完成后仍需预览确认；不自动执行导入规则。")
                    .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("内置浏览器").navigationBarTitleDisplayMode(.inline)
            .sourceFloatingFeedback(browser.message, identifier: "browserMessage")
            .onAppear {
                guard !loadedInitialSource else { return }; loadedInitialSource = true
                if let initialSourceID { selectSource(initialSourceID); if !address.isEmpty { open() } }
            }
            .onChange(of: browser.requestedOriginURL) { _, url in if let url { address = url.absoluteString; open() } }
            .onChange(of:javascript) { _,_ in if browser.webView != nil { open() } }
            .onDisappear { opening?.cancel(); browser.close() }
            .confirmationDialog("在临时会话打开外站？",isPresented:Binding(get:{browser.external != nil},set:{if !$0 { browser.external = nil }}),titleVisibility:.visible) {
                Button("使用独立临时会话") { guard let url = browser.external else { return }; browser.external = nil; selectSource(""); address = url.absoluteString; open() }
                Button("取消",role:.cancel) { browser.external = nil }
            }
            .sheet(item:$browser.imported,onDismiss:{browser.discardImport()}) { file in NavigationStack {
                Group { if ["zip","rar","7z","cbz","cbr"].contains(file.url.pathExtension.lowercased()) { ProductionArchiveView(initialURL:file.url) } else { SmartImportView(initialInput:.file(file.url),originalPDFMode:file.url.pathExtension.lowercased() == "pdf") } }
                    .toolbar { Button("完成") { browser.discardImport() } }
            } }
            .sheet(isPresented:Binding(get:{browser.debugHTML != nil},set:{if !$0 { browser.debugHTML = nil }})) { NavigationStack { ScrollView { Text(browser.debugHTML ?? "").font(.system(size:11,design:.monospaced)).textSelection(.enabled).padding(22) }.appPageStyle().navigationTitle("网页调试").toolbar { Button("完成") { browser.debugHTML = nil } } } }
    }
    private func configure() { browser.configure(sourceID:browserScope,origin:origin,sessions:library.browserSessions,javascript:javascript,allowedOrigins:allowedOrigins,restrictToDeclaredOrigins:source != nil) }
    private func selectSource(_ id: String) {
        opening?.cancel(); browser.close(); sourceID = id
        address = source.flatMap { SourceBrowserStart.urls($0).first?.absoluteString } ?? allowedOrigins.first?.absoluteString ?? ""
        cookies = origin.map{library.browserSessions.usesNativeCookies(sourceID:id,origin:$0)} ?? false
    }
    private func open() {
        guard let url = try? BrowserInput.url(address, allowHTTP: isLegado && origin?.scheme == "http") else { browser.networkFailed(ContentFailure.invalidResponse); return }
        if source != nil, origin == nil { browser.networkFailed(LegadoInteractionError.invalidRequest); return }
        configure()
        opening?.cancel(); let selected = source
        opening = Task { do {
            if var selected, let origin {
                if isLegado { try await library.seedLegadoBrowserCookies(source: selected, state: library.legadoLoginState(for: selected), url: url) }
                selected.url = origin.absoluteString
                try await browser.applyNetwork(library.networkTransport(for:selected))
            }
            try Task.checkCancellation(); browser.open(url.absoluteString)
        } catch { if !Task.isCancelled { browser.networkFailed(error) } } }
    }
}
private struct BrowserWebContent: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView,context: Context) { }
}
