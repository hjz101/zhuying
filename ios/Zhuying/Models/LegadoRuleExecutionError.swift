import Foundation

/// Only schema locations may accompany a failure; imported rule text stays out.
struct LegadoRuleExecutionError: Error, LocalizedError {
    enum Field: String, CaseIterable, Codable, Sendable {
        case unknown = "rule.unknown", searchURL = "searchUrl", header = "header", jsLib = "jsLib", loginURL = "loginUrl"
        case bookInfoInit = "ruleBookInfo.init", bookInfoName = "ruleBookInfo.name", bookInfoAuthor = "ruleBookInfo.author"
        case bookInfoIntro = "ruleBookInfo.intro", bookInfoCoverURL = "ruleBookInfo.coverUrl", bookInfoTOCURL = "ruleBookInfo.tocUrl"
        case bookInfoLastChapter = "ruleBookInfo.lastChapter", bookInfoKind = "ruleBookInfo.kind", bookInfoWordCount = "ruleBookInfo.wordCount"
        case searchBookList = "ruleSearch.bookList", searchName = "ruleSearch.name", searchAuthor = "ruleSearch.author"
        case searchIntro = "ruleSearch.intro", searchCoverURL = "ruleSearch.coverUrl", searchBookURL = "ruleSearch.bookUrl"
        case searchTOCURL = "ruleSearch.tocUrl", searchLastChapter = "ruleSearch.lastChapter", searchKind = "ruleSearch.kind"
        case searchWordCount = "ruleSearch.wordCount", searchNextPageURL = "ruleSearch.nextPageUrl"
        case tocChapterList = "ruleToc.chapterList", tocChapterName = "ruleToc.chapterName", tocChapterURL = "ruleToc.chapterUrl"
        case tocNextURL = "ruleToc.nextTocUrl", tocIsVolume = "ruleToc.isVolume", tocIsVIP = "ruleToc.isVip", tocIsPay = "ruleToc.isPay"
        case content = "ruleContent.content", contentTitle = "ruleContent.title", contentNextURL = "ruleContent.nextContentUrl"
        case exploreBookList = "ruleExplore.bookList", exploreName = "ruleExplore.name", exploreBookURL = "ruleExplore.bookUrl"
    }
    let field: Field
    let cause: any Error
    init(field: Field, cause: any Error) { self.field = field; self.cause = cause }
    var errorDescription: String? { "书源规则执行失败（\(field.rawValue)）。" }
    static func unwrapped(_ error: any Error) -> any Error {
        var current = error
        for _ in 0..<16 {
            guard let wrapped = current as? Self else { break }
            current = wrapped.cause
        }
        return current
    }
}

/// Exportable values never retain the original exception message or stack.
struct SourceDiagnosticJavaScriptSummary: Encodable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case typeError = "TypeError", referenceError = "ReferenceError", syntaxError = "SyntaxError"
        case rangeError = "RangeError", evalError = "EvalError", uriError = "URIError", error = "Error"
    }
    enum Reason: String, Codable, Sendable { case notFunction, missingGlobal, invalidJSON, undefinedProperty, other }
    let kind: Kind
    let reason: Reason
    let missingGlobal: String?
    private init(kind: Kind, reason: Reason, missingGlobal: String?) { self.kind = kind; self.reason = reason; self.missingGlobal = missingGlobal }
    private static let publicGlobals: Set<String> = [
        "URL", "URLSearchParams", "DOMParser", "TextDecoder", "TextEncoder", "atob", "btoa", "CryptoJS", "Jsoup",
        "document", "window", "Packages", "JavaImporter", "java", "source", "book", "chapter", "cache", "cookie", "result", "baseUrl", "key", "page"
    ]
    static func from(_ error: any Error) -> Self? {
        guard let script = LegadoRuleExecutionError.unwrapped(error) as? QuickJSScriptError,
              case .javascript(let original) = script else { return nil }
        let line = String(original.prefix(4096).split(separator: "\n", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kinds: [Kind] = [.typeError, .referenceError, .syntaxError, .rangeError, .evalError, .uriError, .error]
        let kind = kinds.first { line.hasPrefix($0.rawValue + ":") } ?? .error
        let detail = String(line.dropFirst(line.hasPrefix(kind.rawValue + ":") ? kind.rawValue.count + 1 : 0)).trimmingCharacters(in: .whitespaces)
        let lower = detail.lowercased()
        var reason = Reason.other
        var global: String?
        if kind == .typeError {
            if lower.contains("not a function") || lower.contains("not callable") { reason = .notFunction }
            else if (lower.contains("cannot read") || lower.contains("cannot get")) && (lower.contains("undefined") || lower.contains("null")) { reason = .undefinedProperty }
        } else if kind == .referenceError,
                  let regex = try? NSRegularExpression(pattern: #"^[\"']?([A-Za-z_$][A-Za-z0-9_$]*)[\"']? is not defined(?:[. ]|$)"#),
                  let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
                  let range = Range(match.range(at: 1), in: detail) {
            let candidate = String(detail[range])
            if publicGlobals.contains(candidate) { reason = .missingGlobal; global = candidate }
        } else if kind == .syntaxError && (lower.contains("json.parse") || lower.contains("invalid json") || lower.contains("json parse")) {
            reason = .invalidJSON
        }
        return .init(kind: kind, reason: reason, missingGlobal: global)
    }
}
