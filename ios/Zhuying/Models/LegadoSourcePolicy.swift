import Foundation

/// Source identity is independent of the origins at which its rules make
/// requests. A literal is only a declared candidate, never an invented route.
struct LegadoSourcePolicy: Codable, Equatable, Sendable {
    let sourceID: String
    let declaredOrigins: [URL]
    let additionalOrigins: [URL]
    var allowedOrigins: [URL] { Array(Set(declaredOrigins + additionalOrigins)).sorted { $0.absoluteString < $1.absoluteString } }

    init(sourceID: String, declaredOrigins: [URL], additionalOrigins: [URL] = []) throws {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 512 else { throw LegadoCompatibilityError.invalid("书源身份") }
        self.sourceID = sourceID
        self.declaredOrigins = try Self.origins(declaredOrigins)
        self.additionalOrigins = try Self.origins(additionalOrigins)
        guard allowedOrigins.count <= 128 else { throw LegadoCompatibilityError.limit }
    }
    static func canonicalOrigin(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              !host.contains(where: { $0.isWhitespace || "{}$*%/\\".contains($0) }),
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LegadoCompatibilityError.unsupported("仅支持无内嵌凭据的 HTTPS 主机")
        }
        parts.scheme = "https"; parts.host = host.lowercased(); if parts.port == 443 { parts.port = nil }
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        guard let result = parts.url, result.absoluteString.utf8.count <= 2048 else { throw LegadoCompatibilityError.invalid("HTTPS 主机") }
        return result
    }
    private static func origins(_ urls: [URL]) throws -> [URL] {
        guard urls.count <= 128 else { throw LegadoCompatibilityError.limit }
        return Array(Set(try urls.map(canonicalOrigin))).sorted { $0.absoluteString < $1.absoluteString }
    }
    func allows(_ url: URL) -> Bool { (try? Self.canonicalOrigin(url)).map { allowedOrigins.contains($0) } ?? false }
    @discardableResult func requireOrigin(for url: URL) throws -> URL {
        let origin = try Self.canonicalOrigin(url)
        guard allowedOrigins.contains(origin) else { throw LegadoCompatibilityError.unsupported("尚未允许主机 \(origin.absoluteString)，请在书源网络设置中添加") }
        return origin
    }
    func addingOrigin(_ value: String) throws -> Self {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LegadoCompatibilityError.invalid("HTTPS 主机") }
        return try .init(sourceID: sourceID, declaredOrigins: declaredOrigins, additionalOrigins: additionalOrigins + [url])
    }
    func credentialScope(for url: URL, accountID: String) throws -> String {
        StableContentID.make("legado-host-v2", sourceID, accountID, try requireOrigin(for: url).absoluteString)
    }
    static func declared(sourceID: String, raw: [String: Any]) throws -> Self {
        var values = Set<URL>()
        func collect(_ value: Any, depth: Int = 0) throws {
            guard depth <= 48 else { throw LegadoCompatibilityError.limit }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                for candidate in [trimmed] + (try HTTPSLiterals.scan(text)) {
                    guard candidate.hasPrefix("https://"), let url = URL(string: candidate), let origin = try? canonicalOrigin(url) else { continue }
                    values.insert(origin)
                    guard values.count <= 128 else { throw LegadoCompatibilityError.limit }
                }
            } else if let object = value as? [String: Any] { for item in object.values { try collect(item, depth: depth + 1) } }
            else if let array = value as? [Any] { for item in array { try collect(item, depth: depth + 1) } }
        }
        try collect(raw)
        return try .init(sourceID: sourceID, declaredOrigins: Array(values))
    }
}

/// Tokenize static JS/JSON string literals without executing imported code.
/// Dynamic template strings are deliberately excluded from origin discovery.
private enum HTTPSLiterals {
    static func scan(_ text: String) throws -> [String] {
        guard text.utf8.count <= 5 * 1024 * 1024 else { throw LegadoCompatibilityError.limit }
        let chars = Array(text); var result: [String] = [], index = 0
        while index < chars.count {
            if matches(chars, index, "//") {
                while index < chars.count, chars[index] != "\n" { index += 1 }; continue
            }
            if matches(chars, index, "/*") {
                index += 2; while index < chars.count, !matches(chars, index, "*/") { index += 1 }; index = min(chars.count, index + 2); continue
            }
            let quote = chars[index]
            guard quote == "'" || quote == "\"" || quote == "`" else { index += 1; continue }
            index += 1; var value = "", dynamic = false, valid = true, closed = false
            while index < chars.count {
                let char = chars[index]
                if char == quote { closed = true; index += 1; break }
                if quote == "`", matches(chars, index, "${") { dynamic = true }
                if char == "\\" {
                    index += 1; guard index < chars.count else { valid = false; break }
                    let escaped = chars[index]
                    switch escaped {
                    case "\\", "'", "\"", "`", "/": value.append(escaped)
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\n": break
                    case "u", "x":
                        let count = escaped == "u" ? 4 : 2
                        if index + count < chars.count, let code = UInt32(String(chars[(index + 1)...(index + count)]), radix: 16), let scalar = UnicodeScalar(code) { value.unicodeScalars.append(scalar); index += count }
                        else { valid = false }
                    default: valid = false
                    }
                } else { value.append(char) }
                index += 1
            }
            if valid, closed, !dynamic, value.hasPrefix("https://"), value.utf8.count <= 32_000 { result.append(value) }
            guard result.count <= 1024 else { throw LegadoCompatibilityError.limit }
        }
        return result
    }
    private static func matches(_ chars: [Character], _ offset: Int, _ token: String) -> Bool {
        let token = Array(token); return offset + token.count <= chars.count && Array(chars[offset..<(offset + token.count)]) == token
    }
}
