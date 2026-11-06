import Foundation
import Security
import Combine

enum ServiceCredentialError: LocalizedError {
    case unavailable, missing
    var errorDescription: String? { self == .missing ? "尚未保存此服务的访问密钥，请在应用内配置。" : "设备钥匙串暂时不可用，原配置已保留，请重试。" }
}
protocol ServiceKeyVault {
    func save(_ key: String,id: String) throws
    func read(id: String) throws -> String?
    func remove(id: String) throws
    func ids() throws -> [String]
}
struct ServiceKeychain: ServiceKeyVault {
    let service: String
    private func query(_ id: String? = nil) -> [String:Any] {
        var value: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrSynchronizable as String:false]
        if let id { value[kSecAttrAccount as String] = id }; return value
    }
    func save(_ key: String,id: String) throws {
        guard !key.isEmpty, key.utf8.count <= 8192 else { throw ServiceCredentialError.missing }
        let values = [kSecValueData as String:Data(key.utf8)]
        let result = SecItemUpdate(query(id) as CFDictionary,values as CFDictionary)
        if result == errSecItemNotFound {
            var value = query(id); value[kSecValueData as String] = Data(key.utf8); value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(value as CFDictionary,nil) == errSecSuccess else { throw ServiceCredentialError.unavailable }
        } else if result != errSecSuccess { throw ServiceCredentialError.unavailable }
    }
    func read(id: String) throws -> String? {
        var value = query(id); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(value as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data:data,encoding:.utf8) else { throw ServiceCredentialError.unavailable }; return key
    }
    func remove(id: String) throws { let status = SecItemDelete(query(id) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceCredentialError.unavailable } }
    func ids() throws -> [String] {
        var value = query(); value[kSecReturnAttributes as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?; let status = SecItemCopyMatching(value as CFDictionary,&result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String:Any]] else { throw ServiceCredentialError.unavailable }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

struct AudioServiceProfile: Codable, Equatable, Identifiable, Sendable {
    enum Transport: String, CaseIterable, Codable, Sendable { case http = "HTTP TTS", webSocket = "WebSocket" }
    var id = UUID().uuidString
    var name = ""
    var baseURL = ""
    var ttsModel = ""
    var analysisModel = ""
    var voice = ""
    var usesKey = true
    var transport = Transport.http
    var webSocketURL = ""
    var secretID: String? = nil
    var credentialOrigin: String { StableContentID.make(baseURL.trimmingCharacters(in:.whitespacesAndNewlines),webSocketURL.trimmingCharacters(in:.whitespacesAndNewlines)) }
    func validatedBaseURL() throws -> URL {
        guard let parts = URLComponents(string:baseURL.trimmingCharacters(in:.whitespacesAndNewlines)),parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false,parts.user == nil,parts.password == nil,parts.query == nil,parts.fragment == nil,
              !parts.path.split(separator:"/").contains(".."), let url = parts.url else { throw BookImportError.message("请输入不带账号、密钥或查询参数的 HTTPS Base URL。") }
        return url
    }
    func validate() throws {
        _ = try validatedBaseURL()
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count <= 100,
              !ttsModel.isEmpty || !analysisModel.isEmpty, ttsModel.count <= 200,analysisModel.count <= 200,voice.count <= 200 else { throw BookImportError.message("请填写服务名称和至少一种模型。") }
        if transport == .webSocket {
            guard let value = URLComponents(string:webSocketURL),value.scheme == "wss",value.host?.isEmpty == false,value.user == nil,value.password == nil,value.query == nil,value.fragment == nil else { throw BookImportError.message("WebSocket 需要不含凭据的完整 wss 地址。") }
        }
    }
}

/// Only metadata enters the atomic file. Fresh key slots make a failed metadata
/// commit reversible; orphan keys are retried after a successful load/save.
@MainActor final class AudioServiceStore: ObservableObject {
    private struct Manifest: Codable { var version = 1; var profiles: [AudioServiceProfile] }
    @Published private(set) var profiles: [AudioServiceProfile]
    @Published private(set) var cleanupPending = false
    private let url: URL?
    private let vault: any ServiceKeyVault
    private let writer: any AtomicFileWriting
    init(directory: URL? = nil,vault: any ServiceKeyVault,writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        self.url = directory?.appendingPathComponent("services.json"); self.vault = vault; self.writer = writer
        if let directory { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
        if let url, FileManager.default.fileExists(atPath:url.path) {
            let data = try Data(contentsOf:url); guard data.count <= 1024 * 1024 else { throw ContentFailure.storageFailure }
            let manifest = try JSONDecoder().decode(Manifest.self,from:data)
            guard manifest.version == 1,manifest.profiles.count <= 30,Set(manifest.profiles.map(\.id)).count == manifest.profiles.count else { throw ContentFailure.storageFailure }
            for profile in manifest.profiles { try profile.validate() }; profiles = manifest.profiles
        } else { profiles = [] }
        cleanupOrphans()
    }
    func save(_ input: AudioServiceProfile,key: String?) throws {
        try input.validate(); var profile = input
        let previous = profiles.first { $0.id == profile.id }
        let newKey = profile.usesKey ? key.flatMap { $0.isEmpty ? nil : $0 } : nil
        if let newKey { guard newKey.utf8.count <= 8192,!newKey.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw ServiceCredentialError.unavailable } }
        if let newKey { profile.secretID = UUID().uuidString; try vault.save(newKey,id:profile.secretID!) }
        else { profile.secretID = profile.usesKey && previous?.credentialOrigin == profile.credentialOrigin ? previous?.secretID : nil }
        var next = profiles.filter { $0.id != profile.id }; next.append(profile)
        guard next.count <= 30 else { if let newKey, let id = profile.secretID { _ = newKey; try? vault.remove(id:id) }; throw ContentFailure.storageFailure }
        do { if let url { try writer.write(JSONEncoder().encode(Manifest(profiles:next)),to:url) } }
        catch { if newKey != nil,let id = profile.secretID { try? vault.remove(id:id) }; throw error }
        profiles = next; cleanupOrphans()
    }
    func remove(_ id: String) throws {
        let next = profiles.filter { $0.id != id }
        if let url { try writer.write(JSONEncoder().encode(Manifest(profiles:next)),to:url) }
        profiles = next; cleanupOrphans()
    }
    func key(for profile: AudioServiceProfile) throws -> String? {
        guard profile.usesKey else { return nil }
        guard let current = profiles.first(where: { $0.id == profile.id }),current.credentialOrigin == profile.credentialOrigin,
              let id = current.secretID,let key = try vault.read(id:id) else { throw ServiceCredentialError.missing }
        return key
    }
    func retryCleanup() { cleanupOrphans() }
    private func cleanupOrphans() {
        do { let live = Set(profiles.compactMap(\.secretID)); for id in try vault.ids() where !live.contains(id) { try vault.remove(id:id) }; cleanupPending = false }
        catch { cleanupPending = true }
    }
}
