import Foundation

enum RemoteBackendError: LocalizedError, Equatable {
    case invalid, missingKey, rejected, unavailable, response, conflictingRoute
    var errorDescription: String? { switch self {
    case .invalid: "后端配置无效，请填写完整 HTTPS 服务地址及有效密钥。"
    case .missingKey: "此后端尚无访问密钥，请在应用内填写后保存。"
    case .rejected: "后端拒绝请求，请检查访问密钥、书源 ID 与路径白名单。"
    case .unavailable: "自建后端暂时不可用；未启用回退时不会直接连接书源。"
    case .response: "后端响应超出限制或不符合 v1 转发协议。"
    case .conflictingRoute: "自建后端与书源代理／DNS／IP 需择一使用，请先恢复此书源的系统网络。"
    } }
}
struct RemoteBackendProfile: Codable, Equatable, Sendable {
    var version = 1
    var enabled = false
    var endpoint = ""
    var directFallback = false
    func validatedURL() throws -> URL {
        guard version == 1,endpoint.utf8.count <= 2048,let url = try? ShushanClient.host(endpoint) else { throw RemoteBackendError.invalid }; return url
    }
}
@MainActor final class RemoteBackendProfiles {
    private let defaults: UserDefaults
    private let vault: any ServiceKeyVault
    init(defaults: UserDefaults,vault: any ServiceKeyVault) { self.defaults = defaults; self.vault = vault }
    private func scope(_ sourceID: String,_ origin: URL) -> String { "source.backend.v1." + StableContentID.make(sourceID,origin.absoluteString) }
    private func keyID(_ sourceID: String,_ origin: URL,_ endpoint: URL) -> String { StableContentID.make("backend-key-v1",sourceID,origin.absoluteString,endpoint.absoluteString) }
    func profile(sourceID: String,origin: URL) throws -> RemoteBackendProfile {
        guard let data = defaults.data(forKey:scope(sourceID,origin)) else { return .init() }
        let profile = try JSONDecoder().decode(RemoteBackendProfile.self,from:data)
        if profile.enabled { _ = try profile.validatedURL() }; return profile
    }
    func key(sourceID: String,origin: URL,profile: RemoteBackendProfile) throws -> String {
        let endpoint = try profile.validatedURL()
        guard let key = try vault.read(id:keyID(sourceID,origin,endpoint)),!key.isEmpty else { throw RemoteBackendError.missingKey }; return key
    }
    func save(_ profile: RemoteBackendProfile,key: String,sourceID: String,origin: URL) throws {
        let data = try JSONEncoder().encode(profile)
        if profile.enabled || !key.isEmpty {
            let endpoint = try profile.validatedURL()
            if !key.isEmpty {
                guard (16...8192).contains(key.utf8.count),!key.contains("\r"),!key.contains("\n") else { throw RemoteBackendError.invalid }
                try vault.save(key,id:keyID(sourceID,origin,endpoint))
            } else { _ = try self.key(sourceID:sourceID,origin:origin,profile:profile) }
        }
        defaults.set(data,forKey:scope(sourceID,origin)); NotificationCenter.default.post(name:.remoteBackendChanged,object:nil)
    }
    func reset(sourceID: String,origin: URL) throws {
        let old = try profile(sourceID:sourceID,origin:origin)
        if let endpoint = try? old.validatedURL() { try vault.remove(id:keyID(sourceID,origin,endpoint)) }
        defaults.removeObject(forKey:scope(sourceID,origin)); NotificationCenter.default.post(name:.remoteBackendChanged,object:nil)
    }
}
extension Notification.Name { static let remoteBackendChanged = Notification.Name("remoteBackendChanged") }
struct RemoteBackendTransport: HTTPTransport {
    let sourceID: String
    let origin: URL
    let profile: RemoteBackendProfile
    let key: String
    var transport: any HTTPTransport = SourceHTTPTransport(maximumResponseBytes:6 * 1024 * 1024)
    var direct: any HTTPTransport = SourceHTTPTransport(maximumResponseBytes:4 * 1024 * 1024)
    private static let headers: Set<String> = ["accept","content-type","authorization","cookie","x-api-key","x-device-id","x-novel-token","x-device-type","user-agent"]
    private struct Forward: Encodable { let sourceID: String; let sourceOrigin: String; let path: String; let method: String; let headers: [String:String]; let bodyBase64: String? }
    private struct Response: Decodable { let version: Int; let status: Int; let headers: [String:String]; let bodyBase64: String }
    func checkConnection() async throws {
        var request = URLRequest(url:try profile.validatedURL().appendingPathComponent("v1/status")); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject:["sourceID":sourceID,"sourceOrigin":origin.absoluteString])
        let (data,response) = try await transport.send(request); try Task.checkCancellation()
        guard response.statusCode == 200 else { throw [401,403].contains(response.statusCode) ? RemoteBackendError.rejected : RemoteBackendError.unavailable }
        guard data.count <= 4096,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],object["version"] as? Int == 1,object["ready"] as? Bool == true,object["sourceID"] as? String == sourceID,let text = object["sourceOrigin"] as? String,let returned = URL(string:text),SourceBrowserSessions.sameOrigin(returned,origin) else { throw RemoteBackendError.response }
    }
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard let url = request.url,SourceBrowserSessions.sameOrigin(url,origin),request.httpBodyStream == nil,["GET","POST"].contains(request.httpMethod ?? "GET"),(request.httpBody?.count ?? 0) <= 512 * 1024 else { throw RemoteBackendError.invalid }
        let endpoint = try profile.validatedURL().appendingPathComponent("v1/forward")
        var headers: [String:String] = [:]
        for (name,value) in request.allHTTPHeaderFields ?? [:] {
            guard Self.headers.contains(name.lowercased()),value.utf8.count <= 16384,!value.contains("\r"),!value.contains("\n") else { throw RemoteBackendError.invalid }; headers[name.lowercased()] = value
        }
        var parts = URLComponents(url:url,resolvingAgainstBaseURL:false)!
        parts.scheme = nil; parts.host = nil; parts.port = nil; parts.user = nil; parts.password = nil; parts.fragment = nil
        let path = parts.string.flatMap{$0.isEmpty ? nil : $0} ?? "/"
        let payload = Forward(sourceID:sourceID,sourceOrigin:origin.absoluteString,path:path,method:request.httpMethod ?? "GET",headers:headers,bodyBase64:request.httpBody?.base64EncodedString())
        var forwarded = URLRequest(url:endpoint); forwarded.httpMethod = "POST"; forwarded.timeoutInterval = 20; forwarded.httpBody = try JSONEncoder().encode(payload)
        guard forwarded.httpBody!.count <= 1024 * 1024 else { throw RemoteBackendError.invalid }
        forwarded.setValue("application/json",forHTTPHeaderField:"Content-Type"); forwarded.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        let bytes: Data,response: HTTPURLResponse
        do { (bytes,response) = try await transport.send(forwarded) }
        catch {
            try Task.checkCancellation()
            let code = (error as? URLError)?.code
            if profile.directFallback,[URLError.timedOut,.cannotConnectToHost,.cannotFindHost,.networkConnectionLost,.notConnectedToInternet].contains(code) { return try await direct.send(request) }
            throw RemoteBackendError.unavailable
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw [401,403].contains(response.statusCode) ? RemoteBackendError.rejected : RemoteBackendError.unavailable }
        guard bytes.count <= 6 * 1024 * 1024,let result = try? JSONDecoder().decode(Response.self,from:bytes),result.version == 1,(200...599).contains(result.status),!(300..<400).contains(result.status),result.headers.count <= 2,result.headers.allSatisfy({["content-type","retry-after"].contains($0.key.lowercased()) && $0.value.utf8.count <= 8192 && !$0.value.contains("\r") && !$0.value.contains("\n")}),let data = Data(base64Encoded:result.bodyBase64),data.count <= 4 * 1024 * 1024,let originalResponse = HTTPURLResponse(url:url,statusCode:result.status,httpVersion:nil,headerFields:result.headers) else { throw RemoteBackendError.response }
        return (data,originalResponse)
    }
}
