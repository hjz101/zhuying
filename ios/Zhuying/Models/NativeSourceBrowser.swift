import Foundation
import WebKit
import Combine

struct BrowserImportFile: Identifiable { let id = UUID(); let url: URL }
enum BrowserDownloadFiles {
    static var directory: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("BrowserDownloads") }
    /// Call once at App startup, before any new download or preview can exist.
    static func discardAbandoned(directory: URL = BrowserDownloadFiles.directory) throws {
        do { try FileManager.default.removeItem(at:directory) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) { }
    }
}
enum BrowserInput {
    static func url(_ text: String) throws -> URL {
        guard text.utf8.count <= 8192,let url = URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),url.scheme == "https",url.host != nil,url.user == nil,url.password == nil else { throw ContentFailure.invalidResponse }; return url
    }
    static func downloadFilename(response: URLResponse,suggested: String) throws -> String {
        guard let response = response as? HTTPURLResponse,(200...299).contains(response.statusCode),response.expectedContentLength <= BookImporter.maximumBytes else { throw BookImportError.message("下载响应失败或超过20 MB，请检查网页链接。") }
        return try filename(suggested)
    }
    static func filename(_ name: String) throws -> String {
        let safe = (name as NSString).lastPathComponent
        guard !safe.isEmpty,safe.utf8.count <= 240,!safe.contains("\\"),!safe.contains(":"),!safe.unicodeScalars.contains(where:{$0.value < 32}),["txt","epub","pdf","zip","rar","7z","cbz","cbr"].contains((safe as NSString).pathExtension.lowercased()) else { throw BookImportError.message("此文件暂不支持直接导入；请从对应管理入口选择文件。") }; return safe
    }
}
@MainActor final class NativeSourceBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var title = "尚未打开网页"
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    @Published private(set) var loading = false
    @Published private(set) var downloading = false
    @Published private(set) var message: String?
    @Published var external: URL?
    @Published var imported: BrowserImportFile?
    @Published var debugHTML: String?
    private var sourceID = ""
    private var origin: URL?
    private var sessions: SourceBrowserSessions?
    private var javascript = true
    private var routing: SourceNetworkTransport?
    private var download: WKDownload?
    private var destination: URL?
    private var progress: NSKeyValueObservation?
    private var deadline: Task<Void,Never>?
    private var observations: [NSKeyValueObservation] = []
    func configure(sourceID: String,origin: URL?,sessions: SourceBrowserSessions,javascript: Bool) {
        if webView != nil,self.sourceID == sourceID,self.origin == origin,self.javascript == javascript { return }
        close(); self.sourceID = sourceID; self.origin = origin; self.sessions = sessions; self.javascript = javascript
        let config = WKWebViewConfiguration(); config.websiteDataStore = origin.map{sessions.store(sourceID:sourceID,origin:$0)} ?? .nonPersistent(); config.defaultWebpagePreferences.allowsContentJavaScript = javascript
        let view = WKWebView(frame:.zero,configuration:config); view.navigationDelegate = self; view.uiDelegate = self; webView = view
        for key in [\WKWebView.isLoading,\WKWebView.canGoBack,\WKWebView.canGoForward] {
            observations.append(view.observe(key,options:[.initial,.new]) { [weak self] _,_ in Task { @MainActor in self?.refresh() } })
        }
    }
    func open(_ value: String) {
        do { let url = try BrowserInput.url(value); guard allowed(url) else { external = url; return }; message = nil; webView?.load(URLRequest(url:url)) }
        catch { message = "请输入完整 HTTPS 网页地址；不接受账号或密码内嵌的链接。" }
    }
    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
    func inspect() {
        webView?.evaluateJavaScript("(() => { const page=document.documentElement.cloneNode(true); page.querySelectorAll('script,iframe,input,meta').forEach(n=>n.remove()); return page.outerHTML.slice(0,200000); })()") { [weak self] result,error in
            guard let value = result as? String,error == nil else { self?.message = "此页面无法读取结构。"; return }; self?.debugHTML = value
        }
    }
    func downloadCurrent() {
        guard !downloading,let view = webView,let url = view.url,allowed(url) else { return }
        view.startDownload(using:URLRequest(url:url)) { [weak self] download in self?.install(download) }
    }
    func cancelDownload() {
        deadline?.cancel(); deadline = nil; progress = nil; download?.cancel { _ in }; download = nil; downloading = false
        if let destination { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()) }; destination = nil
    }
    func close() { cancelDownload(); observations = []; webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil; webView = nil; routing = nil; canBack = false; canForward = false; loading = false }
    func applyNetwork(_ network: SourceNetworkTransport) async throws {
        if let routing,routing.origin == network.origin,routing.profile == network.profile { return }
        let configurations = try await network.proxyConfigurations(); try Task.checkCancellation()
        webView?.configuration.websiteDataStore.proxyConfigurations = configurations; routing = network
    }
    func networkFailed(_ error: Error) { message = error.localizedDescription }
    func discardImport() { if let imported { try? FileManager.default.removeItem(at:imported.url.deletingLastPathComponent()) }; imported = nil }
    func clearSession() async { close(); if let origin,let sessions { await sessions.clear(sourceID:sourceID,origin:origin) }; message = "此书源的本地浏览器会话已清除。" }
    private func allowed(_ url: URL) -> Bool { (try? BrowserInput.url(url.absoluteString)) != nil && (origin.map{SourceBrowserSessions.sameOrigin(url,$0)} ?? true) }
    private func refresh() { canBack = webView?.canGoBack ?? false; canForward = webView?.canGoForward ?? false; loading = webView?.isLoading ?? false; title = webView?.title ?? "网页浏览" }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { refresh(); if (error as NSError).code != NSURLErrorCancelled { message = "网页加载失败，可检查地址后重试。" } }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { self.webView(webView,didFail:navigation,withError:error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { message = "网页进程已退出，可重新加载。"; refresh() }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame == false,(try? BrowserInput.url(url.absoluteString)) != nil { decisionHandler(.allow); return }
        guard allowed(url) else { if url.scheme == "https" { external = url }; decisionHandler(.cancel); return }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationResponse: WKNavigationResponse,decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url,allowed(url) || !navigationResponse.isForMainFrame && (try? BrowserInput.url(url.absoluteString)) != nil else { decisionHandler(.cancel); return }
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Disposition")?.lowercased().contains("attachment") == true
        if attachment || !navigationResponse.canShowMIMEType {
            guard !downloading,navigationResponse.response.expectedContentLength <= BookImporter.maximumBytes else { message = "下载超过 20 MB 或已有任务正在处理。"; decisionHandler(.cancel); return }; decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView,createWebViewWith configuration: WKWebViewConfiguration,for navigationAction: WKNavigationAction,windowFeatures: WKWindowFeatures) -> WKWebView? { if let url = navigationAction.request.url { open(url.absoluteString) }; return nil }
    func webView(_ webView: WKWebView,navigationAction: WKNavigationAction,didBecome download: WKDownload) { install(download) }
    func webView(_ webView: WKWebView,navigationResponse: WKNavigationResponse,didBecome download: WKDownload) { install(download) }
    private func install(_ value: WKDownload) {
        guard download == nil else { value.cancel { _ in }; return }
        download = value; downloading = true; value.delegate = self
        progress = value.progress.observe(\.completedUnitCount,options:.new) { [weak self] progress,_ in
            if progress.completedUnitCount > BookImporter.maximumBytes { Task { @MainActor in self?.cancelDownload(); self?.message = "下载超过 20 MB，已停止并回收临时文件。" } }
        }
        deadline = Task { try? await Task.sleep(for:.seconds(45)); if !Task.isCancelled { cancelDownload(); message = "下载超时，临时文件已回收。" } }
    }
    func download(_ download: WKDownload,decideDestinationUsing response: URLResponse,suggestedFilename: String,completionHandler: @escaping (URL?) -> Void) {
        do {
            guard self.download === download,response.expectedContentLength <= BookImporter.maximumBytes else { throw RuleExtractionError.limit }
            let name = try BrowserInput.downloadFilename(response:response,suggested:suggestedFilename),folder = BrowserDownloadFiles.directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); let file = folder.appendingPathComponent(name); destination = file; completionHandler(file)
        } catch { message = error.localizedDescription; completionHandler(nil); cancelDownload() }
    }
    func download(_ download: WKDownload,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) { decisionHandler(request.url.map{allowed($0)} == true ? .allow : .cancel) }
    func download(_ download: WKDownload,didReceive challenge: URLAuthenticationChallenge,completionHandler: @escaping (URLSession.AuthChallengeDisposition,URLCredential?) -> Void) { completionHandler(.performDefaultHandling,nil) }
    func downloadDidFinish(_ download: WKDownload) {
        guard self.download === download,let destination else { return }
        deadline?.cancel(); deadline = nil; progress = nil; self.download = nil; downloading = false; self.destination = nil
        do { try BookImporter.validateSize(try destination.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0); imported = .init(url:destination); message = "文件已下载，确认预览后再入库。" }
        catch { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()); message = error.localizedDescription }
    }
    func download(_ download: WKDownload,didFailWithError error: Error,resumeData: Data?) { if self.download === download { cancelDownload(); message = "下载未完成，临时文件已回收。" } }
}
