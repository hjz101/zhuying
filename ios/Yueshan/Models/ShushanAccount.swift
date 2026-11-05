import Foundation
import Security
import Combine

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class SourceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let redirected = request.url
        let sameOrigin = original?.scheme == redirected?.scheme && original?.host == redirected?.host && original?.port == redirected?.port
        completionHandler(sameOrigin ? request : nil)
    }
}

struct SourceHTTPTransport: HTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: SourceRedirectPolicy(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ContentFailure.invalidResponse }
        return (data, response)
    }
}

struct ShushanCredential: Codable, Equatable, Sendable {
    let host: URL
    let apiKey: String
    let nickname: String
    var deviceID: String? = nil
    var authenticationHeader: String { Data(apiKey.utf8).base64EncodedString() }
}

enum ShushanAccountError: Error, LocalizedError, Equatable {
    case invalidHost, emptyFields, rejected, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidHost: "请输入完整的 HTTPS 书源地址，例如 https://v1.vossc.com。"
        case .emptyFields: "请填写邮箱和密码。"
        case .rejected: "登录未成功，请检查账号、密码或书源服务状态。"
        case .keychain: "无法保存或读取登录状态，请稍后重试。"
        }
    }
}

struct ShushanClient: Sendable {
    static let defaultHost = "https://v1.vossc.com"
    let transport: any HTTPTransport
    init(transport: any HTTPTransport = SourceHTTPTransport()) { self.transport = transport }

    static func host(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw ShushanAccountError.invalidHost }
        components.scheme = "https"; components.host = host.lowercased(); components.path = ""
        guard let url = components.url else { throw ShushanAccountError.invalidHost }
        return url
    }

    func login(host: URL, email: String, password: String, deviceID: String? = nil) async throws -> ShushanCredential {
        let host = try Self.host(host.absoluteString)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw ShushanAccountError.emptyFields }
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "email", value: email), URLQueryItem(name: "password", value: password)]
        // '+' must be escaped in application/x-www-form-urlencoded bodies.
        let body = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: host.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.httpBody = body?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("SHUSAN_READ_2025", forHTTPHeaderField: "X-Novel-Token")
        request.setValue("ios", forHTTPHeaderField: "X-Device-Type")
        if let deviceID { request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id") }
        request.timeoutInterval = 15
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode), data.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 200, object["error"] == nil,
              let result = object["data"] as? [String: Any], let user = result["user"] as? [String: Any],
              let key = user["api_key"] as? String, !key.isEmpty else { throw ShushanAccountError.rejected }
        return .init(host: host, apiKey: key, nickname: user["nickname"] as? String ?? "已登录用户", deviceID: deviceID)
    }
}

protocol ShushanCredentialStorage: Sendable {
    func load(host: URL) throws -> ShushanCredential?
    func save(_ credential: ShushanCredential) throws
    func remove(host: URL) throws
}

struct ShushanKeychain: ShushanCredentialStorage {
    let service: String
    init(service: String = "com.yueshan.source.shushan.production") { self.service = service }
    private func query(host: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: host.absoluteString]
    }
    func load(host: URL) throws -> ShushanCredential? {
        var query = query(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ShushanAccountError.keychain(status) }
        let credential = try JSONDecoder().decode(ShushanCredential.self, from: data)
        guard credential.host == host else { throw ShushanAccountError.rejected }
        return credential
    }
    func save(_ credential: ShushanCredential) throws {
        let query = query(host: credential.host)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var record = query.merging(attributes) { _, new in new }
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(record as CFDictionary, nil)
            guard added == errSecSuccess else { throw ShushanAccountError.keychain(added) }
        } else if status != errSecSuccess { throw ShushanAccountError.keychain(status) }
    }
    func remove(host: URL) throws {
        let status = SecItemDelete(query(host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ShushanAccountError.keychain(status) }
    }
}

@MainActor
final class ShushanAccountStore: ObservableObject {
    @Published var hostText: String
    @Published private(set) var credential: ShushanCredential?
    @Published private(set) var busy = false
    @Published var message: String?
    private let client: ShushanClient
    private let vault: any ShushanCredentialStorage
    private let defaults: UserDefaults
    let deviceID: String
    private var operation = 0

    init(defaults: UserDefaults = .standard, client: ShushanClient = .init(), vault: any ShushanCredentialStorage = ShushanKeychain()) {
        self.defaults = defaults; self.client = client; self.vault = vault
        let savedID = defaults.string(forKey: "yueshan.shushan.installation-id")
        deviceID = savedID.flatMap { UUID(uuidString: $0) }?.uuidString ?? UUID().uuidString
        defaults.set(deviceID, forKey: "yueshan.shushan.installation-id")
        hostText = defaults.string(forKey: "yueshan.shushan.host") ?? ShushanClient.defaultHost
        do { credential = try vault.load(host: ShushanClient.host(hostText)) }
        catch { message = error.localizedDescription }
    }

    var credentialForRequests: ShushanCredential? {
        guard var value = credential else { return nil }
        if value.deviceID == nil { value.deviceID = deviceID }
        return value
    }

    func login(email: String, password: String) async {
        operation += 1
        let attempt = operation
        busy = true; message = nil
        defer { if operation == attempt { busy = false } }
        do {
            let host = try ShushanClient.host(hostText)
            let result = try await client.login(host: host, email: email, password: password, deviceID: deviceID)
            try Task.checkCancellation()
            guard attempt == operation else { return }
            try vault.save(result)
            credential = result
            hostText = host.absoluteString
            defaults.set(hostText, forKey: "yueshan.shushan.host")
            message = "登录成功，登录状态已保存在此设备。"
        } catch is CancellationError { }
        catch { if attempt == operation { message = error.localizedDescription } }
    }
    func logout() {
        operation += 1; busy = false
        do {
            if let credential { try vault.remove(host: credential.host) }
            credential = nil
            message = "已退出书源登录，书架与阅读记录保留。"
        } catch { message = error.localizedDescription }
    }
}
