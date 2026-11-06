import Foundation

enum LegadoCompatibilityError: LocalizedError, Equatable {
    case invalid(String), unsupported(String), limit
    var errorDescription: String? {
        switch self {
        case .invalid(let field): "阅读 3.0 规则无效：\(field)"
        case .unsupported(let feature): "当前阅读 3.0 兼容层尚不支持：\(feature)"
        case .limit: "阅读 3.0 规则输入、递归或输出超过限制。"
        }
    }
}

/// Independently implemented against the fd026e0 rule semantics. The original
/// package remains available for export; this model describes executable fields.
struct LegadoSourceDefinition {
    let name: String
    let sourceURL: String
    let baseURL: URL
    let searchURL: String
    let header: String
    let jsLib: String
    let loginURL: String
    let exploreURL: String
    let search: [String: String]
    let bookInfo: [String: String]
    let toc: [String: String]
    let content: [String: String]
    let explore: [String: String]
    let raw: [String: Any]

    static func decode(_ source: DemoSource) throws -> Self {
        guard let bytes = source.configuration, bytes.count <= 5 * 1024 * 1024,
              let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              raw["adapter"] == nil || raw["adapter"] as? String == "legado-3" else {
            throw LegadoCompatibilityError.invalid("书源配置")
        }
        for key in ["bookSourceUrl", "searchUrl", "header", "jsLib", "loginUrl", "exploreUrl"] {
            if let value = raw[key], !(value is NSNull), !(value is String) { throw LegadoCompatibilityError.invalid(key) }
        }
        func string(_ key: String) -> String { raw[key] as? String ?? "" }
        func rules(_ key: String) throws -> [String: String] {
            guard let value = raw[key] else { return [:] }
            guard let row = value as? [String: Any] else { throw LegadoCompatibilityError.invalid(key) }
            var result: [String: String] = [:]
            for (field, value) in row {
                if value is NSNull { continue }
                if let text = value as? String { result[field] = text }
                else if key == "ruleBookInfo", field == "canReName", let number = value as? NSNumber { result[field] = number.stringValue }
                else { throw LegadoCompatibilityError.invalid(key + "." + field) }
            }
            return result
        }
        let search = try rules("ruleSearch"), bookInfo = try rules("ruleBookInfo"), toc = try rules("ruleToc"), content = try rules("ruleContent")
        let required: [(String, String)] = [("searchUrl", string("searchUrl")), ("ruleSearch.bookList", search["bookList"] ?? ""),
            ("ruleSearch.name", search["name"] ?? ""), ("ruleSearch.bookUrl", search["bookUrl"] ?? ""),
            ("ruleToc.chapterList", toc["chapterList"] ?? ""), ("ruleToc.chapterName", toc["chapterName"] ?? ""),
            ("ruleToc.chapterUrl", toc["chapterUrl"] ?? ""), ("ruleContent.content", content["content"] ?? "")]
        for (key, value) in required where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw LegadoCompatibilityError.invalid(key) }
        let address = string("bookSourceUrl").isEmpty ? source.url : string("bookSourceUrl")
        func origin(_ value: String) -> URL? {
            guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
            parts.scheme = "https"; parts.host = host.lowercased(); parts.path = "/"; parts.query = nil; parts.fragment = nil
            return parts.url
        }
        // Opaque legacy identities need a static request origin. Script-only
        // origins cannot be inferred or invented while labelling a source ready.
        let searchPrefix = string("searchUrl").prefix { $0 != "," && $0 != "{" && !$0.isWhitespace }
        guard let base = origin(address) ?? origin(String(searchPrefix)) else { throw LegadoCompatibilityError.unsupported("缺少明确的 HTTPS 请求主机") }
        guard string("jsLib").utf8.count <= 256 * 1024 else { throw LegadoCompatibilityError.limit }
        return .init(name: source.name, sourceURL: address, baseURL: base, searchURL: string("searchUrl"), header: string("header"), jsLib: string("jsLib"),
                     loginURL: string("loginUrl"), exploreURL: string("exploreUrl"), search: search, bookInfo: bookInfo, toc: toc, content: content,
                     explore: try rules("ruleExplore"), raw: raw)
    }
}
