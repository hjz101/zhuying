import Foundation
import Fuzi

/// Source annotations remain separate from prose and never execute a source's
/// inline click script. The only retained action is a declared HTTP(S) page.
struct SourceReaderComment: Codable, Equatable, Sendable {
    var count: Int = 0
    var hotComment: SourceComment?
    var url: URL?
}

struct LegadoReaderContent {
    var paragraphs: [String] = []
    var comments: [Int: SourceReaderComment] = [:]

    static func parse(_ html: String, baseURL: URL, allowedOrigins: [URL], loadSVG: ((URL) throws -> String)? = nil) throws -> Self {
        guard html.utf8.count <= 2 * 1024 * 1024 else { throw LegadoRequestError.limit }
        let sanitized = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        let expression = try NSRegularExpression(pattern: #"(?is)<(?:comment|note|img)\b[^>]*>"#)
        let marker = "ZHUYING" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var annotated = sanitized, items: [Int: SourceReaderComment] = [:]
        var remainingImages = 12
        let matches = expression.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized))
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: annotated) else { continue }
            let tag = String(annotated[range])
            if let comment = annotation(tag, baseURL: baseURL, allowedOrigins: allowedOrigins, loadSVG: { url in
                guard remainingImages > 0, let loadSVG else { return "" }
                remainingImages -= 1
                return try loadSVG(url)
            }) {
                items[index] = comment
                let token = "\(marker)\(index)END"
                annotated.replaceSubrange(range, with: comment.hotComment != nil ? "\n" + token + "\n" : token)
            } else { annotated.replaceSubrange(range, with: "") }
        }
        annotated = annotated.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
        let plain = try text(annotated)
        let tokens = try NSRegularExpression(pattern: marker + #"([0-9]+)END"#)
        var result = Self()
        for line in plain.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let found = tokens.matches(in: line, range: NSRange(line.startIndex..., in: line))
            let prose = tokens.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty { result.paragraphs.append(prose) }
            guard !result.paragraphs.isEmpty else { continue }
            let index = result.paragraphs.count - 1
            for token in found {
                guard let range = Range(token.range(at: 1), in: line), let id = Int(line[range]), let item = items[id] else { continue }
                var merged = result.comments[index] ?? SourceReaderComment()
                merged.count = max(merged.count, item.count)
                merged.hotComment = item.hotComment ?? merged.hotComment
                merged.url = item.url ?? merged.url
                result.comments[index] = merged
            }
        }
        return result
    }

    private static func annotation(_ tag: String, baseURL: URL, allowedOrigins: [URL], loadSVG: (URL) throws -> String) -> SourceReaderComment? {
        func attribute(_ name: String) -> String? {
            let pattern = #"(?is)\b"# + name + #"\s*=\s*(["'])(.*?)\1"#
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let range = Range(match.range(at: 2), in: tag) else { return nil }
            return try? text(String(tag[range]).replacingOccurrences(of: "<", with: "&lt;"))
        }
        func permitted(_ value: String?) -> URL? {
            guard let value, value.utf8.count <= 16 * 1024, let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  url.user == nil, url.password == nil, allowedOrigins.contains(where: { SourceBrowserSessions.sameOrigin(url, $0) }) else { return nil }
            return url
        }
        var value = SourceReaderComment()
        value.count = min(1_000_000, max(0, Int(attribute("count") ?? "") ?? 0))
        value.url = permitted(attribute("ident")) ?? permitted(actionURL(attribute("onPress") ?? ""))
        var hot = attribute("text")
        if tag.lowercased().hasPrefix("<img") {
            // Reading sources append JSON metadata inside the src quotes. It
            // is intentionally parsed as data rather than as an HTML handler.
            guard let regex = try? NSRegularExpression(pattern: #"(?is)\bsrc\s*=\s*(["'])(.*)\1\s*/?>$"#),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let range = Range(match.range(at: 2), in: tag) else { return nil }
            let src = String(tag[range]), split = src.range(of: ",{", options: .backwards)
            let image = split.map { String(src[..<$0.lowerBound]) } ?? src
            let metadata = split.flatMap { String(src[$0.lowerBound...].dropFirst()).data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let action = metadata?["click"] as? String ?? metadata?["js"] as? String ?? ""
            // Chapter discussions have their own identity; don't attach them
            // to the last paragraph merely because their image follows it.
            if action.contains("本章说") { return nil }
            value.url = value.url ?? permitted(actionURL(action))
            let isBubble = (metadata?["style"] as? String)?.lowercased() == "text"
            var labels: [String] = []
            var svg: String?
            if image.hasPrefix("data:image/svg+xml;base64,"), let bytes = Data(base64Encoded: String(image.dropFirst(26))), bytes.count <= 256 * 1024 { svg = String(data: bytes, encoding: .utf8) }
            else if !isBubble, value.url != nil, let imageURL = permitted(image) { svg = try? loadSVG(imageURL) }
            if let svg, svg.utf8.count <= 256 * 1024,
               !svg.localizedCaseInsensitiveContains("<!DOCTYPE"), !svg.localizedCaseInsensitiveContains("<!ENTITY"), let parsed = try? HTMLDocument(string: svg) {
                labels = parsed.xpath("//text").map(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            let query = URLComponents(string: image)?.queryItems ?? []
            if isBubble {
                let count = labels.last ?? query.first(where: { $0.name == "count" })?.value ?? ""
                value.count = min(1_000_000, max(0, Int(count.replacingOccurrences(of: "+", with: "")) ?? 0))
            } else {
                hot = labels.filter { !["神评论", "神人评论", "热评"].contains($0) }.joined(separator: " ")
                if hot?.isEmpty != false { hot = query.first(where: { $0.name == "text" })?.value }
            }
        }
        if let hot, !hot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let literal = String(hot.prefix(2000))
            value.hotComment = SourceComment(id: StableContentID.make(literal), author: "书源神评", text: literal, likes: 0, createdAt: nil)
        }
        return value.count > 0 || value.hotComment != nil ? value : nil
    }

    /// Accept a single, known browser call with string arguments. Never eval.
    static func actionURL(_ action: String) -> String? {
        let pattern = #"^\s*(?:java\.)?(?:showCmt|showFanqieComment|showReadingBrowser|startBrowser)\s*\(\s*(["'])((?:\\.|(?!\1).)*)\1\s*[,)]"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: action, range: NSRange(action.startIndex..., in: action)), let range = Range(match.range(at: 2), in: action) else { return nil }
        return String(action[range]).replacingOccurrences(of: #"\'"#, with: "'").replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\/"#, with: "/").replacingOccurrences(of: #"\\"#, with: #"\"#).replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func text(_ value: String) throws -> String {
        guard value.contains("<") || value.contains("&") else { return value }
        let document = try HTMLDocument(string: "<div>" + value + "</div>")
        return withExtendedLifetime(document) { document.root?.stringValue ?? value }
    }
}
