import Foundation
import WebKit

enum ScriptHostError: LocalizedError, Equatable {
    case invalid, busy, timedOut, failed, terminated, networkDisabled, quota
    var errorDescription: String? { switch self {
    case .invalid: "脚本、输入或返回值不符合宿主 v1 格式。"
    case .busy: "脚本正在执行，请取消或等待完成。"
    case .timedOut: "脚本执行超时，Worker 已终止。"
    case .failed: "脚本执行失败；原文和已有数据保留。"
    case .terminated: "脚本进程已由系统终止，请缩小输入后重试。"
    case .networkDisabled: "网络访问未开启，或请求超出了所选书源。"
    case .quota: "脚本宿主调用或结果超过限制。"
    } }
}
struct ScriptHostPolicy: Sendable {
    var sourceID: String
    var origin: URL? = nil
    var accountID: String = "public"
    var network = false
    var timeout: TimeInterval = 1.5
    var scope: String { StableContentID.make("script-host-v1",sourceID,origin?.absoluteString ?? "local",accountID) }
}

/// Only the fixed relay runs in the page. User programs execute in a dedicated
/// Web Worker, so public worker.terminate() can stop a synchronous infinite loop.
@MainActor final class NativeScriptHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let support = ["宿主 v1：async function(input, host)，返回可 JSON 序列化值。","host.fetch：显式启用、仅所选 HTTPS 来源、GET／POST，无自动 Cookie 或钥匙串访问。","host.cacheGet／cachePut：来源＋主机＋账号隔离；可清理缓存，不随备份保存。","host.extract：已声明的解析器 v1；sha256、UTF-8 Base64 与 URL 编码。","脚本 ≤ 64 KiB，输入／输出 ≤ 1 MiB，最多 128 次宿主调用；网络最多 8 次、总响应 ≤ 2 MiB。","执行上限 0.1–5 秒，支持取消与终止循环；系统管理 WebContent 内存，没有公开的每个 Worker 硬堆额度。","不兼容 java.ajax 同步语义、jsoup、任意阅读器宿主、跨站 Cookie、后台无限执行。"]
    private let transport: any HTTPTransport
    private let cache: ScriptCache
    private var view: WKWebView?
    private var continuation: CheckedContinuation<Data,Error>?
    private var timeoutTask: Task<Void,Never>?
    private var requests: [String:Task<Void,Never>] = [:]
    private var policy = ScriptHostPolicy(sourceID:"local")
    private var program = ""
    private var input: Any = NSNull()
    private var token = ""
    private var calls = 0,networkCalls = 0,networkBytes = 0,bridgeBytes = 0
    init(transport: any HTTPTransport = BoundedAudioHTTPTransport(maximumBytes:1024 * 1024),cache: ScriptCache = .shared) { self.transport = transport; self.cache = cache }
    func run(_ script: String,input data: Data,policy: ScriptHostPolicy) async throws -> Data {
        guard continuation == nil else { throw ScriptHostError.busy }
        guard !script.isEmpty,script.utf8.count <= 64 * 1024,data.count <= 1024 * 1024,policy.sourceID.utf8.count <= 512,policy.timeout.isFinite,(0.1...5).contains(policy.timeout) else { throw ScriptHostError.invalid }
        try Task.checkCancellation(); let json = try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)
        self.policy = policy; program = script; input = json; token = UUID().uuidString; calls = 0; networkCalls = 0; networkBytes = 0; bridgeBytes = 0
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self,name:"scriptHost")
                let view = WKWebView(frame:.init(x:0,y:0,width:1,height:1),configuration:configuration); self.view = view; view.navigationDelegate = self
                view.loadHTMLString(Self.relay,baseURL:URL(string:"https://script.zhuying.invalid/"))
                timeoutTask = Task { try? await Task.sleep(for:.seconds(8)); if !Task.isCancelled { finish(.failure(ScriptHostError.timedOut)) } }
            }
        },onCancel:{ Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
    }
    func cancel() { finish(.failure(CancellationError())) }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        guard continuation != nil,webView === view else { return }; timeoutTask?.cancel(); let ticket = token
        timeoutTask = Task { try? await Task.sleep(for:.seconds(policy.timeout)); if !Task.isCancelled { finish(.failure(ScriptHostError.timedOut)) } }
        webView.callAsyncJavaScript("window.__start(request)",arguments:["request":["script":program,"input":input,"token":token]],in:nil,in:.page) { [weak self] result in
            if case .failure = result,self?.token == ticket { self?.finish(.failure(ScriptHostError.failed)) }
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === view { finish(.failure(ScriptHostError.terminated)) } }
    func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { if webView === view { finish(.failure(ScriptHostError.failed)) } }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { if webView === view { finish(.failure(ScriptHostError.failed)) } }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard continuation != nil,message.frameInfo.isMainFrame,let object = message.body as? [String:Any],object["token"] as? String == token,let kind = object["kind"] as? String else { return }
        if kind == "result" {
            guard object["ok"] as? Bool == true,let output = object["json"] as? String,output.utf8.count <= 1024 * 1024,let data = output.data(using:.utf8),(try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)) != nil else { finish(.failure(ScriptHostError.failed)); return }
            finish(.success(data)); return
        }
        guard kind == "rpc",let id = object["id"] as? String,id.utf8.count <= 64,requests[id] == nil,let method = object["method"] as? String,let args = object["args"] as? [Any] else { finish(.failure(ScriptHostError.invalid)); return }
        calls += 1
        guard calls <= 128,let bytes = try? JSONSerialization.data(withJSONObject:args),bytes.count <= 2 * 1024 * 1024 - bridgeBytes else { finish(.failure(ScriptHostError.quota)); return }
        bridgeBytes += bytes.count
        let ticket = token
        requests[id] = Task {
            let response: [String:Any]
            do { response = ["id":id,"ok":true,"value":try await bridge(method,args:args)] }
            catch { response = ["id":id,"ok":false,"error":(error as? ScriptHostError)?.localizedDescription ?? "宿主请求失败。"] }
            guard !Task.isCancelled,ticket == token,continuation != nil else { return }
            requests.removeValue(forKey:id)
            view?.callAsyncJavaScript("window.__reply(reply)",arguments:["reply":response],in:nil,in:.page,completionHandler:nil)
        }
    }
    private func bridge(_ method: String,args: [Any]) async throws -> Any {
        switch method {
        case "cacheGet": guard let key = args.first as? String else { throw ScriptHostError.invalid }; return try await cache.get(scope:policy.scope,key:key) as Any? ?? NSNull()
        case "cachePut": guard args.count == 2,let key = args[0] as? String,let value = args[1] as? String else { throw ScriptHostError.invalid }; try await cache.put(scope:policy.scope,key:key,value:value); return true
        case "sha256": guard let value = args.first as? String else { throw ScriptHostError.invalid }; return StableContentID.version(value)
        case "extract":
            guard args.count == 2,let object = args[0] as? [String:Any],let input = args[1] as? String else { throw ScriptHostError.invalid }
            let rule = try JSONDecoder().decode(ExtractionRule.self,from:JSONSerialization.data(withJSONObject:object))
            let worker = Task.detached { try RuleExtraction.extract(rule,from:input) }
            return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        case "fetch":
            guard policy.network,let origin = policy.origin,origin.scheme == "https",let object = args.first as? [String:Any],let address = object["url"] as? String,
                  let url = URL(string:address,relativeTo:origin)?.absoluteURL,url.scheme == origin.scheme,url.host == origin.host,url.port == origin.port,url.user == nil,url.password == nil else { throw ScriptHostError.networkDisabled }
            networkCalls += 1; guard networkCalls <= 8 else { throw ScriptHostError.quota }
            let method = object["method"] as? String ?? "GET"; guard ["GET","POST"].contains(method) else { throw ScriptHostError.invalid }
            var request = URLRequest(url:url); request.httpMethod = method; request.timeoutInterval = min(15,policy.timeout)
            if let body = object["body"] as? String { guard method == "POST",body.utf8.count <= 64 * 1024 else { throw ScriptHostError.invalid }; request.httpBody = Data(body.utf8); request.setValue("application/json; charset=utf-8",forHTTPHeaderField:"Content-Type") }
            let (data,response) = try await transport.send(request); try Task.checkCancellation(); networkBytes += data.count
            guard networkBytes <= 2 * 1024 * 1024,response.url?.host == origin.host,response.url?.scheme == origin.scheme,response.url?.port == origin.port,let body = String(data:data,encoding:.utf8) else { throw ScriptHostError.quota }
            return ["status":response.statusCode,"body":body,"mime":response.mimeType ?? ""]
        default: throw ScriptHostError.invalid
        }
    }
    private func finish(_ result: Result<Data,Error>) {
        guard let continuation else { return }; self.continuation = nil; timeoutTask?.cancel(); timeoutTask = nil
        for request in requests.values { request.cancel() }; requests = [:]
        view?.callAsyncJavaScript("window.__stop()",arguments:[:],in:nil,in:.page,completionHandler:nil)
        view?.stopLoading(); view?.navigationDelegate = nil; view?.configuration.userContentController.removeScriptMessageHandler(forName:"scriptHost"); view = nil; program = ""; input = NSNull(); token = ""
        continuation.resume(with:result)
    }
    private static let relay = #"""
    <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; worker-src blob:; connect-src 'none'; img-src 'none'; frame-src 'none'"><script>
    (() => { let worker, token;
    const code = `(() => {
      const send = self.postMessage.bind(self), stringify = JSON.stringify.bind(JSON), Async = Object.getPrototypeOf(async function(){}).constructor;
      const pending = new Map(); let sequence = 0;
      const rpc = (method,args) => new Promise((resolve,reject) => { const id = String(++sequence); pending.set(id,{resolve,reject}); send({kind:'rpc',id,method,args}); });
      const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8',{fatal:true});
      const host = Object.freeze({
        fetch: value => rpc('fetch',[value]), cacheGet: key => rpc('cacheGet',[key]), cachePut: (key,value) => rpc('cachePut',[key,value]),
        extract: (rule,input) => rpc('extract',[rule,input]), sha256: value => rpc('sha256',[value]),
        base64Encode: value => btoa(Array.from(encoder.encode(value),x=>String.fromCharCode(x)).join('')),
        base64Decode: value => decoder.decode(Uint8Array.from(atob(value),x=>x.charCodeAt(0))), urlEncode: encodeURIComponent, urlDecode: decodeURIComponent
      });
      for (const key of ['fetch','XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker','importScripts']) { try { Object.defineProperty(self,key,{value:undefined,writable:false,configurable:false}); } catch(_) {} }
      self.onmessage = async event => {
        const value = event.data;
        if (value.kind === 'reply') { const item = pending.get(value.id); if(item) { pending.delete(value.id); value.ok ? item.resolve(value.value) : item.reject(new Error(value.error)); } return; }
        if (value.kind !== 'run') return;
        try { const result = await new Async('input','host','"use strict";\\n' + value.script)(value.input,host); const json = stringify(result); if (typeof json !== 'string' || json.length > 1048576) throw new Error('output'); send({kind:'result',ok:true,json}); }
        catch(_) { send({kind:'result',ok:false}); }
      };
    })();`;
    window.__start = request => { token = request.token; worker = new Worker(URL.createObjectURL(new Blob([code],{type:'text/javascript'}))); worker.onmessage = event => window.webkit.messageHandlers.scriptHost.postMessage({...event.data,token}); worker.onerror = () => window.webkit.messageHandlers.scriptHost.postMessage({kind:'result',ok:false,token}); worker.postMessage({kind:'run',script:request.script,input:request.input}); };
    window.__reply = reply => { if(worker) worker.postMessage({...reply,kind:'reply'}); };
    window.__stop = () => { if(worker) worker.terminate(); worker = null; };
    })();</script>
    """#
}
