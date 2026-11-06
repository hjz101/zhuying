import Foundation
import CryptoKit
import Security

enum LegadoAuthStatus: String, Codable, Sendable { case signedOut, unverified, verified, expired }
struct LegadoStateScope: Codable, Equatable, Sendable {
    let sourceID: String
    var accountID = "default"
    var libraryProfile = "production"
    var id: String { StableContentID.make("legado-state-v2", libraryProfile, sourceID, accountID) }
}
enum LegadoStateError: LocalizedError, Equatable {
    case corrupt, vaultUnavailable, limit, referenceMissing, referenceNeedsRefresh, migrationConflict
    var errorDescription: String? {
        switch self {
        case .corrupt: "书源会话数据无法验证，原数据已保留，请重试或重置此账号。"
        case .vaultUnavailable: "设备钥匙串暂不可用，书源会话未修改。"
        case .limit: "书源会话、缓存或内部引用超过存储额度。"
        case .referenceMissing: "内部引用暂不可用，请刷新这本书的详情与目录。"
        case .referenceNeedsRefresh: "登录会话已改变，请刷新书籍详情与目录以获取新的请求凭据；阅读位置已保留。"
        case .migrationConflict: "目标资料库已有独立书源会话，未覆盖任何登录数据。"
        }
    }
}
protocol LegadoSecretVault {
    func read(id: String) throws -> Data?
    func save(_ data: Data, id: String) throws
    func remove(id: String) throws
}
struct LegadoKeychainVault: LegadoSecretVault {
    var service = "com.zhuying.legado-state.v2"
    private func query(_ id: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false] }
    func read(id: String) throws -> Data? {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LegadoStateError.vaultUnavailable }; return data
    }
    func save(_ data: Data, id: String) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw LegadoStateError.limit }
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var value = query(id); value[kSecValueData as String] = data; value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw LegadoStateError.vaultUnavailable }
        } else if status != errSecSuccess { throw LegadoStateError.vaultUnavailable }
    }
    func remove(id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LegadoStateError.vaultUnavailable }
    }
}

/// Synchronous storage for the serialized source worker and its login UI. All
/// script-controlled disk values are encrypted: a token hidden in "config" is
/// just as confidential as a value named "token". Login data, cookies and full
/// request descriptors stay in a Keychain snapshot outside ordinary backups.
final class LegadoPersistentState: @unchecked Sendable {
    private struct CacheEntry: Codable { let value: String; let expiresAt: Date?; var touched: Date }
    private struct Manifest: Codable {
        var version = 2
        var scopeID: String
        var scopeIdentity: LegadoStateScope? = nil
        var revision: UInt64 = 0
        var authEpoch: UInt64 = 0
        var status = LegadoAuthStatus.signedOut
        var variables: [String: String] = [:]
        var cache: [String: CacheEntry] = [:]
        var origins: [URL] = []
        var secretID: String?
    }
    private struct Envelope: Codable { var version = 2; let scopeID: String; let sealed: Data }
    private struct ReferenceRecord: Codable {
        let descriptor: String
        let epoch: UInt64
        let requiresAuthentication: Bool
    }
    private struct CookieRecord: Codable, Equatable {
        let origin: String
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let expires: Date?
        var cookie: HTTPCookie? {
            var values: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: secure ? "TRUE" : "FALSE", .init("HttpOnly"): httpOnly ? "TRUE" : "FALSE"]
            if let expires { values[.expires] = expires }
            return HTTPCookie(properties: values)
        }
    }
    private struct Secrets: Codable {
        var scopeID: String
        var scopeIdentity: LegadoStateScope? = nil
        var loginInfo = ""
        var cookies: [CookieRecord] = []
        var references: [String: ReferenceRecord] = [:]
    }
    // A process-wide storage lock prevents stale provider instances from
    // overwriting a more recent UI mutation of the same account's file.
    private static let lock = NSRecursiveLock()
    private static var latest: [String: UInt64] = [:]
    let scope: LegadoStateScope
    private let url: URL
    private let vault: any LegadoSecretVault
    private let writer: any AtomicFileWriting
    private let now: () -> Date
    private let key: SymmetricKey
    private var manifest: Manifest
    private var secrets: Secrets
    private var memory: [String: CacheEntry] = [:]
    private(set) var cleanupPending = false
    var accountID: String { scope.accountID }
    var authStatus: LegadoAuthStatus { Self.lock.lock(); defer { Self.lock.unlock() }; do { try refresh(); return manifest.status } catch { return .expired } }
    var revision: UInt64 { Self.lock.lock(); defer { Self.lock.unlock() }; try? refresh(); return manifest.revision }
    var sessionRevision: UInt64 { Self.lock.lock(); defer { Self.lock.unlock() }; try? refresh(); return manifest.authEpoch }
    /// An operation may intentionally change its own login epoch. Validate its
    /// starting epoch, perform that mutation and capture the resulting epoch
    /// under the same recursive lock, excluding an intervening UI logout.
    func withSessionMutation<Value>(expectedSessionRevision: UInt64?, _ body: () throws -> Value) throws -> (Value, UInt64) {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        if let expectedSessionRevision, expectedSessionRevision != manifest.authEpoch { throw CancellationError() }
        let result = try body()
        return (result, manifest.authEpoch)
    }
    /// An app-generated identifier, not an Android or hardware identifier.
    /// Stored separately so logout/reset do not silently change device identity.
    func deviceIdentifier() throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let id = "installation." + scope.id
        if let data = try vault.read(id: id) {
            guard let value = String(data: data, encoding: .utf8), value.count == 32, value.allSatisfy({ $0.isHexDigit }) else { throw LegadoStateError.corrupt }; return value
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try vault.save(Data(value.utf8), id: id); return value
    }

    init(sourceID: String, accountID: String = "default", libraryProfile: String = "production", directory: URL,
         vault: any LegadoSecretVault = LegadoKeychainVault(), writer: any AtomicFileWriting = AtomicFileWriter(), now: @escaping () -> Date = Date.init) throws {
        let scope = LegadoStateScope(sourceID: sourceID, accountID: accountID, libraryProfile: libraryProfile)
        guard [sourceID, accountID, libraryProfile].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }), directory.isFileURL else { throw LegadoStateError.limit }
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try directory.setResourceValues(flags)
        self.scope = scope; self.vault = vault; self.writer = writer; self.now = now
        url = directory.resolvingSymlinksInPath().appendingPathComponent(scope.id + ".sealed")
        let keyID = "file-key." + scope.id
        let keyData: Data
        if let stored = try vault.read(id: keyID) { guard stored.count == 32 else { throw LegadoStateError.corrupt }; keyData = stored }
        else {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw LegadoStateError.vaultUnavailable }
            let generated = SymmetricKey(size: .bits256); keyData = generated.withUnsafeBytes { Data($0) }; try vault.save(keyData, id: keyID)
        }
        key = SymmetricKey(data: keyData)
        manifest = Manifest(scopeID: scope.id); secrets = Secrets(scopeID: scope.id)
        try reload()
        Self.latest[url.path] = manifest.revision
    }

    /// Only a caller that knows the complete former profile namespace can
    /// authorize this association. The exact tuple must reproduce the old
    /// filename, authenticated envelope and Keychain key; files are never
    /// selected by count, modification time or trying unrelated source IDs.
    /// Stop old source operations before migration and reopen the new session.
    @discardableResult
    static func migrateLegacyScope(from legacy: LegadoStateScope, to target: LegadoStateScope, directory: URL,
                                   vault: any LegadoSecretVault = LegadoKeychainVault(),
                                   writer: any AtomicFileWriting = AtomicFileWriter()) throws -> Bool {
        guard legacy.sourceID == target.sourceID, legacy.accountID == target.accountID, legacy.id != target.id,
              directory.isFileURL else { throw LegadoStateError.migrationConflict }
        guard [legacy.sourceID, legacy.accountID, legacy.libraryProfile, target.libraryProfile].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw LegadoStateError.limit }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let root = directory.resolvingSymlinksInPath(), previousFile = root.appendingPathComponent(legacy.id + ".sealed"), targetFile = root.appendingPathComponent(target.id + ".sealed")
        guard FileManager.default.fileExists(atPath: previousFile.path) else { return false }
        guard !FileManager.default.fileExists(atPath: targetFile.path) else { throw LegadoStateError.migrationConflict }
        let previous = try Self(sourceID: legacy.sourceID, accountID: legacy.accountID, libraryProfile: legacy.libraryProfile, directory: directory, vault: vault, writer: writer)
        let destination = try Self(sourceID: target.sourceID, accountID: target.accountID, libraryProfile: target.libraryProfile, directory: directory, vault: vault, writer: writer)
        var next = previous.manifest, secret = previous.secrets
        next.scopeID = target.id; next.scopeIdentity = target; next.secretID = nil
        secret.scopeID = target.id; secret.scopeIdentity = target
        let oldDeviceID = "installation." + legacy.id, newDeviceID = "installation." + target.id
        let oldDevice = try vault.read(id: oldDeviceID), newDevice = try vault.read(id: newDeviceID)
        if let oldDevice {
            guard let value = String(data: oldDevice, encoding: .utf8), value.count == 32, value.allSatisfy({ $0.isHexDigit }) else { throw LegadoStateError.corrupt }
        }
        if let oldDevice, let newDevice, oldDevice != newDevice { throw LegadoStateError.migrationConflict }
        let copiedDevice = oldDevice != nil && newDevice == nil
        do {
            if let oldDevice, copiedDevice { try vault.save(oldDevice, id: newDeviceID) }
            try destination.commit(next, secret)
        } catch {
            if copiedDevice { try? vault.remove(id: newDeviceID) }
            throw error
        }
        return true
    }
    private func reload() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard (try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])).isSymbolicLink != true,
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 4 * 1024 * 1024 else { throw LegadoStateError.corrupt }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 2, envelope.scopeID == scope.id else { throw LegadoStateError.corrupt }
        let bytes: Data
        do { bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: Data(scope.id.utf8)) }
        catch { throw LegadoStateError.corrupt }
        let loaded = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard loaded.version == 2, loaded.scopeID == scope.id, loaded.scopeIdentity == nil || loaded.scopeIdentity == scope else { throw LegadoStateError.corrupt }
        var secret = Secrets(scopeID: scope.id)
        if let id = loaded.secretID {
            guard id.hasPrefix("snapshot." + scope.id + "."), let bytes = try vault.read(id: id), bytes.count <= 8 * 1024 * 1024 else { throw LegadoStateError.vaultUnavailable }
            secret = try JSONDecoder().decode(Secrets.self, from: bytes)
            guard secret.scopeID == scope.id, secret.scopeIdentity == nil || secret.scopeIdentity == scope else { throw LegadoStateError.corrupt }
        }
        try validate(loaded, secrets: secret)
        if loaded.authEpoch != manifest.authEpoch { memory = [:] }
        manifest = loaded; secrets = secret
    }
    private func refresh() throws {
        if Self.latest[url.path] != manifest.revision { try reload(); Self.latest[url.path] = manifest.revision }
    }
    private func validate(_ value: Manifest, secrets: Secrets) throws {
        guard value.scopeID == scope.id, secrets.scopeID == scope.id,
              value.scopeIdentity == nil || value.scopeIdentity == scope, secrets.scopeIdentity == nil || secrets.scopeIdentity == scope else { throw LegadoStateError.corrupt }
        guard value.variables.count <= 512, value.variables.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 512 * 1024,
              value.variables.allSatisfy({ $0.key.utf8.count <= 1024 && $0.value.utf8.count <= 128 * 1024 }), value.cache.count <= 128,
              value.cache.reduce(0, { $0 + $1.key.utf8.count + $1.value.value.utf8.count }) <= 512 * 1024, value.origins.count <= 128,
              secrets.loginInfo.utf8.count <= 128 * 1024, secrets.cookies.count <= 256, secrets.references.count <= 4096,
              secrets.references.reduce(0, { $0 + $1.key.utf8.count + $1.value.descriptor.utf8.count }) <= 4 * 1024 * 1024 else { throw LegadoStateError.limit }
        for origin in value.origins { guard try LegadoSourcePolicy.canonicalOrigin(origin) == origin else { throw LegadoStateError.corrupt } }
        for item in value.cache.values { guard item.value.utf8.count <= 128 * 1024, item.touched.timeIntervalSince1970.isFinite, item.expiresAt?.timeIntervalSince1970.isFinite ?? true else { throw LegadoStateError.corrupt } }
    }
    private func commit(_ nextManifest: Manifest, _ nextSecrets: Secrets, writeSecrets: Bool = true) throws {
        var value = nextManifest, nextSecrets = nextSecrets
        value.revision = manifest.revision &+ 1; value.scopeIdentity = scope; nextSecrets.scopeIdentity = scope
        try validate(value, secrets: nextSecrets)
        var stagedSecret: String?
        do {
            if writeSecrets {
                let id = "snapshot." + scope.id + "." + UUID().uuidString
                let bytes = try JSONEncoder().encode(nextSecrets)
                guard bytes.count <= 8 * 1024 * 1024 else { throw LegadoStateError.limit }
                try vault.save(bytes, id: id); stagedSecret = id; value.secretID = id
            }
            let bytes = try JSONEncoder().encode(value)
            guard bytes.count <= 2 * 1024 * 1024, let sealed = try AES.GCM.seal(bytes, using: key, authenticating: Data(scope.id.utf8)).combined else { throw LegadoStateError.limit }
            try writer.write(JSONEncoder().encode(Envelope(scopeID: scope.id, sealed: sealed)), to: url)
        } catch { if let stagedSecret { try? vault.remove(id: stagedSecret) }; throw error }
        let previous = manifest.secretID; manifest = value; secrets = nextSecrets
        Self.latest[url.path] = value.revision
        if Self.latest.count > 512 { for entry in Self.latest.keys where entry != url.path { Self.latest[entry] = nil; break } }
        if writeSecrets, let previous, previous != value.secretID { do { try vault.remove(id: previous) } catch { cleanupPending = true } }
        NotificationCenter.default.post(name: .legadoPersistentStateChanged, object: self, userInfo: ["scopeID": scope.id, "revision": value.revision])
    }
    func getVariable(_ key: String) throws -> String { Self.lock.lock(); defer { Self.lock.unlock() }; try refresh(); return manifest.variables[key] ?? "" }
    func setVariable(_ value: String, key: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        guard !key.isEmpty, key.utf8.count <= 1024, value.utf8.count <= 128 * 1024 else { throw LegadoStateError.limit }
        var next = manifest; next.variables[key] = value; try commit(next, secrets, writeSecrets: false)
    }
    func getLoginInfo() throws -> String { Self.lock.lock(); defer { Self.lock.unlock() }; try refresh(); return secrets.loginInfo }
    func getLoginInfoMap() throws -> [String: String] {
        let info = try getLoginInfo(); if info.isEmpty { return [:] }
        guard let values = try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: String] else { throw LegadoStateError.corrupt }; return values
    }
    func setLoginInfo(_ values: [String: String]) throws { try putLoginInfo(String(decoding: JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)) }
    /// An explicit retry starts a new unverified session even when its saved
    /// credentials are unchanged. Script saves retain their existing semantics.
    func beginLoginAttempt(_ values: [String: String]) throws {
        try putLoginInfo(String(decoding: JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self), startingAttempt: true)
    }
    func putLoginInfo(_ json: String) throws { try putLoginInfo(json, startingAttempt: false) }
    private func putLoginInfo(_ json: String, startingAttempt: Bool) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        guard json.utf8.count <= 128 * 1024, let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String], object.count <= 128 else { throw LegadoStateError.limit }
        let canonical = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        var next = manifest; var secret = secrets
        let changed = secret.loginInfo != canonical
        if changed || startingAttempt {
            next.status = .unverified; next.authEpoch &+= 1
        }
        if changed, !secret.loginInfo.isEmpty { secret.cookies = []; next.variables = [:]; next.cache = [:] }
        secret.loginInfo = canonical; try commit(next, secret)
        if changed { memory = [:] }
    }
    func markVerified() throws { Self.lock.lock(); defer { Self.lock.unlock() }; try refresh(); var next = manifest; next.status = .verified; try commit(next, secrets, writeSecrets: false) }
    func expire() throws { try authenticationEnded(status: .expired, keepLogin: true) }
    func logout() throws { try authenticationEnded(status: .signedOut, keepLogin: false) }
    private func authenticationEnded(status: LegadoAuthStatus, keepLogin: Bool) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        var next = manifest; var secret = secrets; next.status = status; next.authEpoch &+= 1
        // Script variables/cache can hide authentication tokens under arbitrary
        // names. Allowed hosts are user preferences and survive logout.
        next.variables = [:]; next.cache = [:]; secret.cookies = []; if !keepLogin { secret.loginInfo = "" }
        try commit(next, secret); memory = [:]
    }
    func reset() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        var next = Manifest(scopeID: scope.id); next.authEpoch = manifest.authEpoch &+ 1
        try commit(next, Secrets(scopeID: scope.id)); memory = [:]
    }
    func cacheGet(_ key: String, memory memoryOnly: Bool = false) throws -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        let entry = memoryOnly ? memory[key] : manifest.cache[key]
        guard let entry, entry.expiresAt.map({ $0 > now() }) ?? true else { return nil }; return entry.value
    }
    func cachePut(_ value: String, key: String, ttl: TimeInterval? = nil, memory memoryOnly: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        guard !key.isEmpty, key.utf8.count <= 1024, value.utf8.count <= 128 * 1024, ttl.map({ $0.isFinite && $0 >= 0 && $0 <= 365 * 86400 }) ?? true else { throw LegadoStateError.limit }
        let date = now(), entry = CacheEntry(value: value, expiresAt: ttl.map { date.addingTimeInterval($0) }, touched: date)
        var values = memoryOnly ? memory : manifest.cache
        values = values.filter { $0.value.expiresAt.map({ $0 > date }) ?? true }; values[key] = entry
        while values.count > 128 || values.reduce(0, { $0 + $1.key.utf8.count + $1.value.value.utf8.count }) > 512 * 1024 {
            guard let oldest = values.min(by: { $0.value.touched < $1.value.touched })?.key else { break }; values[oldest] = nil
        }
        if memoryOnly { memory = values } else { var next = manifest; next.cache = values; try commit(next, secrets, writeSecrets: false) }
    }
    func clearCache() throws { Self.lock.lock(); defer { Self.lock.unlock() }; try refresh(); var next = manifest; next.cache = [:]; try commit(next, secrets, writeSecrets: false); memory = [:] }
    func allowedOrigins() throws -> [URL] { Self.lock.lock(); defer { Self.lock.unlock() }; try refresh(); return manifest.origins }
    func setAllowedOrigins(_ urls: [URL]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        let policy = try LegadoSourcePolicy(sourceID: scope.sourceID, declaredOrigins: [], additionalOrigins: urls)
        var next = manifest; next.origins = policy.allowedOrigins; try commit(next, secrets, writeSecrets: false)
    }
    func cookies(for url: URL) throws -> [HTTPCookie] {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        let origin = try LegadoSourcePolicy.canonicalOrigin(url).absoluteString, date = now()
        return secrets.cookies.filter { $0.origin == origin && ($0.expires.map { $0 > date } ?? true) }.compactMap(\.cookie).filter { Self.matches($0, url: url) }
    }
    func setCookies(_ cookies: [HTTPCookie], for url: URL, expectedSessionRevision: UInt64? = nil) throws {
        try updateCookies(cookies, for: url, replacing: false, expectedSessionRevision: expectedSessionRevision)
    }
    /// Browser results represent the entire origin's jar, including deletions.
    func replaceCookies(_ cookies: [HTTPCookie], for url: URL, expectedSessionRevision: UInt64? = nil) throws {
        try updateCookies(cookies, for: url, replacing: true, expectedSessionRevision: expectedSessionRevision)
    }
    private func updateCookies(_ cookies: [HTTPCookie], for url: URL, replacing: Bool, expectedSessionRevision: UInt64?) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        // The response may have arrived after a UI logout or credential change.
        // Compare and commit under the same lock so an old response cannot
        // restore cookies belonging to an invalidated authentication session.
        if let expectedSessionRevision, expectedSessionRevision != manifest.authEpoch { throw CancellationError() }
        let origin = try LegadoSourcePolicy.canonicalOrigin(url).absoluteString
        var secret = secrets; let date = now()
        secret.cookies = secret.cookies.filter { $0.expires.map { $0 > date } ?? true }
        if replacing { secret.cookies.removeAll { $0.origin == origin } }
        for cookie in cookies {
            guard Self.domainMatches(cookie.domain, host: url.host ?? ""), cookie.name.utf8.count + cookie.value.utf8.count <= 8192,
                  [cookie.name, cookie.value, cookie.domain, cookie.path].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw LegadoStateError.limit }
            secret.cookies.removeAll { $0.origin == origin && $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if cookie.expiresDate.map({ $0 <= date }) ?? false { continue }
            secret.cookies.append(.init(origin: origin, name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, expires: cookie.expiresDate))
        }
        guard secret.cookies.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + $1.domain.utf8.count + $1.path.utf8.count }) <= 256 * 1024 else { throw LegadoStateError.limit }
        guard secret.cookies != secrets.cookies else { return }
        var next = manifest; if next.status == .signedOut, !secret.cookies.isEmpty { next.status = .unverified }; try commit(next, secret)
    }
    func clearCookies(origin: URL? = nil) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh(); var secret = secrets
        if let origin { let value = try LegadoSourcePolicy.canonicalOrigin(origin).absoluteString; secret.cookies.removeAll { $0.origin == value } } else { secret.cookies = [] }
        try commit(manifest, secret)
    }
    func registerReference(_ reference: LegadoReference, role: String, nativeID: String? = nil) throws -> String {
        try registerReferences([reference], role: role, nativeIDs: [nativeID])[0]
    }
    func registerReferences(_ references: [LegadoReference], role: String, nativeIDs: [String?]? = nil) throws -> [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        guard references.count <= 4096, nativeIDs == nil || nativeIDs?.count == references.count else { throw LegadoStateError.limit }
        var secret = secrets; var keys: [String] = []
        for (index, reference) in references.enumerated() {
            let id = try reference.stableID(sourceIdentity: scope.sourceID, role: role, nativeID: nativeIDs?[index] ?? nil)
            let key = "legado-ref-v2-" + id
            secret.references[key] = .init(descriptor: reference.resolvedDescriptor, epoch: manifest.authEpoch, requiresAuthentication: manifest.status == .verified)
            keys.append(key)
        }
        try commit(manifest, secret); return keys
    }
    func resolveReference(_ key: String) throws -> LegadoReference {
        Self.lock.lock(); defer { Self.lock.unlock() }; try refresh()
        guard let record = secrets.references[key] else { throw LegadoStateError.referenceMissing }
        let reference = try LegadoReference.parse(record.descriptor)
        if record.requiresAuthentication, manifest.status == .signedOut || manifest.status == .expired { throw ContentFailure.authenticationRequired }
        if record.epoch != manifest.authEpoch, !reference.isPortableIdentityPayload { throw LegadoStateError.referenceNeedsRefresh }
        return reference
    }
    private static func domainMatches(_ domain: String, host: String) -> Bool {
        let domain = domain.lowercased(), host = host.lowercased(), plain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == plain || domain.hasPrefix(".") && host.hasSuffix("." + plain)
    }
    private static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        let path = url.path.isEmpty ? "/" : url.path
        return domainMatches(cookie.domain, host: url.host ?? "") && (path == cookie.path || path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }
}
extension Notification.Name { static let legadoPersistentStateChanged = Notification.Name("legadoPersistentStateChanged") }
