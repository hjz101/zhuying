import Foundation

/// A request descriptor is not necessarily a URL. The complete original value
/// is retained for execution; only its opaque identity enters book metadata.
struct LegadoReference: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case https, inline }
    let descriptor: String
    let address: String
    let optionsJSON: Data?
    let kind: Kind
    let requestURL: URL?
    let inlineData: Data?
    var options: [String: Any] { optionsJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:] }
    var inlineText: String? { inlineData.flatMap { String(data: $0, encoding: .utf8) } }
    var inlineHex: String? { inlineData.map(StableContentID.hex) }
    var resolvedDescriptor: String {
        let address = requestURL?.absoluteString ?? self.address
        return optionsJSON.map { address + "," + String(decoding: $0, as: UTF8.self) } ?? address
    }

    static func parse(_ descriptor: String, baseURL: URL? = nil) throws -> Self {
        guard !descriptor.isEmpty, descriptor.utf8.count <= 256 * 1024 else { throw LegadoCompatibilityError.limit }
        let value = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(value)
        var address = value, optionsJSON: Data?
        for index in chars.indices where chars[index] == "," {
            var next = index + 1
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            guard next < chars.count, chars[next] == "{" else { continue }
            let bytes = Data(String(chars[next...]).utf8)
            guard bytes.count <= 64 * 1024, (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { continue }
            address = String(chars[..<index]).trimmingCharacters(in: .whitespacesAndNewlines); optionsJSON = bytes; break
        }
        if address.lowercased().hasPrefix("data:") {
            guard let comma = address.firstIndex(of: ","), address[..<comma].lowercased().hasSuffix(";base64"),
                  address[..<comma].utf8.count <= 128,
                  let decoded = Data(base64Encoded: String(address[address.index(after: comma)...])), decoded.count <= 128 * 1024 else { throw LegadoCompatibilityError.invalid("data: 内部引用需要有界 Base64 载荷") }
            return .init(descriptor: descriptor, address: address, optionsJSON: optionsJSON, kind: .inline, requestURL: nil, inlineData: decoded)
        }
        guard let url = URL(string: address, relativeTo: baseURL)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw LegadoCompatibilityError.unsupported("内部引用或完整 HTTP(S) 请求地址") }
        _ = try LegadoSourcePolicy.canonicalOrigin(url)
        return .init(descriptor: descriptor, address: address, optionsJSON: optionsJSON, kind: .https, requestURL: url, inlineData: nil)
    }

    /// qingtian's frozen source explicitly identifies content with these fields.
    /// Unknown query parameters are never guessed to be authentication tokens.
    func stableID(sourceIdentity: String, role: String, nativeID: String? = nil) throws -> String {
        guard !sourceIdentity.isEmpty, !role.isEmpty, sourceIdentity.utf8.count <= 512, role.utf8.count <= 128 else { throw LegadoCompatibilityError.invalid("引用身份") }
        if let nativeID, !nativeID.isEmpty { return StableContentID.make("legado-reference-v2", sourceIdentity, role, "native", nativeID) }
        if let identity = qingtianIdentity(role: role) { return StableContentID.list(["legado-reference-v2", sourceIdentity, role] + identity) }
        var options = self.options
        for key in ["headers", "header"] {
            let value = options[key]
            let object = (value as? [String: Any]) ?? (value as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            if let object {
                // These are credential headers by the HTTP protocol itself.
                options[key] = object.filter { !["authorization", "cookie", "proxy-authorization"].contains($0.key.lowercased()) }
            }
        }
        let identity: [String: Any] = ["address": requestURL?.absoluteString ?? address, "options": options]
        let bytes = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        return StableContentID.make("legado-reference-v2", sourceIdentity, role, String(decoding: bytes, as: UTF8.self))
    }
    private var qingtianPayload: [String: Any]? {
        guard kind == .inline, let type = options["type"] as? String, ["qingtian", "qingtian2", "qingtian3"].contains(type), let inlineData else { return nil }
        return (try? JSONSerialization.jsonObject(with: inlineData)) as? [String: Any]
    }
    private func qingtianIdentity(role: String) -> [String]? {
        guard let payload = qingtianPayload else { return nil }
        func identifier(_ key: String) -> String? {
            if let value = payload[key] as? String, !value.isEmpty { return value }
            if let value = payload[key] as? NSNumber { return value.stringValue }
            return nil
        }
        guard let book = identifier("book_id"), let provider = identifier("sources"), let tab = identifier("tab") else { return nil }
        if role == "chapter" { guard let chapter = identifier("item_id") else { return nil }; return ["qingtian", provider, tab, book, chapter] }
        return ["qingtian", provider, tab, book]
    }
    /// Only a positively recognized, identifier-only payload can cross a login
    /// epoch without refreshing its request tickets. All other descriptors stay
    /// registered but require a refreshed request after authentication changes.
    var isPortableIdentityPayload: Bool {
        guard let payload = qingtianPayload, qingtianIdentity(role: options["type"] as? String == "qingtian3" ? "chapter" : "book") != nil,
              Set(payload.keys).isSubset(of: ["book_id", "item_id", "sources", "tab", "title", "url"]),
              Set(options.keys).isSubset(of: ["type"]) else { return false }
        // An upstream URL can itself contain an opaque ticket, even in its
        // path. Retain it losslessly, but refresh it after a login change.
        return (payload["url"] as? String ?? "").isEmpty
    }
}
