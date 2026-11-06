import Foundation
import Fuzi

/// One request chain owns a context. Callers serialize access on their worker;
/// contexts are never shared between accounts or concurrent source requests.
final class LegadoRuleContext {
    var variables: [String: String]
    var bindings: [String: Any]
    var evaluateJS: ((String, [String: Any]) throws -> Any)?
    /// Rows selected by an elements rule represent JSON objects or HTML nodes;
    /// complete HTTP response bodies remain strings for JSON.parse(result).
    var structuredInput = false
    fileprivate var depth = 0
    fileprivate var scalarJS = false
    init(variables: [String: String] = [:], bindings: [String: Any] = [:], evaluateJS: ((String, [String: Any]) throws -> Any)? = nil) {
        self.variables = variables; self.bindings = bindings; self.evaluateJS = evaluateJS
    }
}

/// A lexical scanner keeps rule operators out of selectors, quoted attributes,
/// templates and JavaScript. In particular @js consumes the remaining program;
/// its &&/|| operators are JavaScript, not rule combinators.
enum LegadoRuleScanner {
    static func split(_ input: String, on delimiter: String) throws -> [String] {
        let chars = Array(input), token = Array(delimiter)
        var result: [String] = [], start = 0, index = 0, stack: [Character] = [], quote: Character?, escaped = false
        while index < chars.count {
            if let active = quote {
                if escaped { escaped = false }
                else if chars[index] == "\\" { escaped = true }
                else if chars[index] == active { quote = nil }
                index += 1; continue
            }
            if chars[index] == "\\" { index += min(2, chars.count - index); continue }
            if stack.isEmpty, matches(chars, index, "<js>") {
                guard let end = scriptEnd(chars, from: index + 4) else { throw LegadoCompatibilityError.invalid("<js> 缺少 </js>") }
                index = end + 5; continue
            }
            if stack.isEmpty, matches(chars, index, "@js:") { break }
            if stack.isEmpty, matches(chars, index, "##") {
                if delimiter == "##" {
                    result.append(String(chars[start..<index]))
                    // Regex quotes are literal; escaping protects a delimiter.
                    var tail = "", cursor = index + 2
                    while cursor < chars.count {
                        if chars[cursor] == "\\", cursor + 1 < chars.count {
                            tail.append(chars[cursor]); tail.append(chars[cursor + 1]); cursor += 2
                        } else if matches(chars, cursor, "##") { result.append(tail); tail = ""; cursor += 2 }
                        else { tail.append(chars[cursor]); cursor += 1 }
                    }
                    result.append(tail); return result
                }
                // Rule combinators inside a replacement regex/template belong
                // to the replacement, not the selector expression.
                break
            }
            let char = chars[index]
            if char == "\"" || char == "'" || char == "`" { quote = char; index += 1; continue }
            if stack.isEmpty, index + token.count <= chars.count, Array(chars[index..<(index + token.count)]) == token {
                result.append(String(chars[start..<index])); index += token.count; start = index; continue
            }
            if char == "(" || char == "[" || char == "{" { stack.append(char) }
            else if char == ")" || char == "]" || char == "}" {
                let opening: Character = char == ")" ? "(" : char == "]" ? "[" : "{"
                guard stack.last == opening else { throw LegadoCompatibilityError.invalid("规则括号不匹配") }
                stack.removeLast()
            }
            index += 1
        }
        // The remaining JS program/regex is parsed by its own evaluator.
        if index == chars.count, quote != nil || !stack.isEmpty { throw LegadoCompatibilityError.invalid("规则引号或括号未闭合") }
        result.append(String(chars[start...])); return result
    }
    static func matches(_ chars: [Character], _ offset: Int, _ token: String) -> Bool {
        let token = Array(token)
        return offset + token.count <= chars.count && Array(chars[offset..<(offset + token.count)]) == token
    }
    static func balancedEnd(_ chars: [Character], from start: Int) throws -> Int {
        var stack: [Character] = [], quote: Character?, escaped = false, index = start
        while index < chars.count {
            let char = chars[index]
            if let active = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == active { quote = nil }
            } else if char == "\"" || char == "'" || char == "`" { quote = char }
            else if char == "{" || char == "[" || char == "(" { stack.append(char) }
            else if char == "}" || char == "]" || char == ")" {
                let opening: Character = char == "}" ? "{" : char == "]" ? "[" : "("
                guard stack.last == opening else { throw LegadoCompatibilityError.invalid("模板括号不匹配") }
                stack.removeLast(); if stack.isEmpty { return index }
            }
            index += 1
        }
        throw LegadoCompatibilityError.invalid("模板未闭合")
    }
    /// A closing marker in a JS string/comment is not the end of its program.
    static func scriptEnd(_ chars: [Character], from start: Int) -> Int? {
        var quote: Character?, escaped = false, lineComment = false, blockComment = false, index = start
        var regex = false, regexClass = false, expressionStart = true
        while index < chars.count {
            let char = chars[index]
            if lineComment { if char == "\n" { lineComment = false }; index += 1; continue }
            if blockComment { if matches(chars, index, "*/") { blockComment = false; index += 2 } else { index += 1 }; continue }
            if regex {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "[" { regexClass = true }
                else if char == "]" { regexClass = false }
                else if char == "/", !regexClass { regex = false; expressionStart = false }
                index += 1; continue
            }
            if let active = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == active { quote = nil; expressionStart = false }
            } else if matches(chars, index, "//") { lineComment = true; index += 2; continue }
            else if matches(chars, index, "/*") { blockComment = true; index += 2; continue }
            else if matches(chars, index, "</js>") { return index }
            else if char == "/", expressionStart { regex = true; regexClass = false }
            else if char == "'" || char == "\"" || char == "`" { quote = char }
            else if char.isLetter || char == "_" || char == "$" {
                let begin = index
                while index + 1 < chars.count, chars[index + 1].isLetter || chars[index + 1].isNumber || chars[index + 1] == "_" || chars[index + 1] == "$" { index += 1 }
                expressionStart = ["return", "throw", "case", "delete", "typeof", "void", "in", "of", "yield", "await"].contains(String(chars[begin...index]))
            } else if !char.isWhitespace { expressionStart = "([{:;,=!?&|+-*%~^<>/".contains(char) }
            index += 1
        }
        return nil
    }
}

struct LegadoRuleEngine {
    let context: LegadoRuleContext
    init(context: LegadoRuleContext = LegadoRuleContext()) { self.context = context }

    func text(_ rule: String, in content: String, baseURL: URL? = nil) throws -> String {
        let previous = context.scalarJS; context.scalarJS = true; defer { context.scalarJS = previous }
        return try list(rule, in: content, baseURL: baseURL).joined(separator: "\n")
    }
    func list(_ rule: String, in content: String, baseURL: URL? = nil) throws -> [String] {
        try evaluate(rule, content: content, baseURL: baseURL, elements: false)
    }
    func elements(_ rule: String, in content: String, baseURL: URL? = nil) throws -> [String] {
        try evaluate(rule, content: content, baseURL: baseURL, elements: true)
    }
    func template(_ value: String, content: String = "", baseURL: URL? = nil) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") { return try string(js(String(trimmed.dropFirst(4)), result: content, original: content, baseURL: baseURL)) }
        if trimmed.hasPrefix("<js>") {
            let chars = Array(trimmed)
            guard let end = LegadoRuleScanner.scriptEnd(chars, from: 4), end + 5 == chars.count else { throw LegadoCompatibilityError.invalid("URL 脚本必须完整包在 <js> 中") }
            return try string(js(String(chars[4..<end]), result: content, original: content, baseURL: baseURL))
        }
        return try interpolate(value, content: content, baseURL: baseURL)
    }

    private func evaluate(_ rule: String, content: String, baseURL: URL?, elements: Bool) throws -> [String] {
        try Task.checkCancellation()
        guard rule.utf8.count <= 64 * 1024, content.utf8.count <= 2 * 1024 * 1024, context.depth < 32 else { throw LegadoCompatibilityError.limit }
        context.depth += 1; defer { context.depth -= 1 }
        let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.isEmpty { return [] }
        for delimiter in ["||", "&&", "%%"] {
            let parts = try LegadoRuleScanner.split(rule, on: delimiter)
            if parts.count > 1 {
                if delimiter == "||" {
                    for part in parts { let values = try evaluate(part, content: content, baseURL: baseURL, elements: elements); if values.contains(where: { !$0.isEmpty }) { return values } }
                    return []
                }
                let lists = try parts.map { try evaluate($0, content: content, baseURL: baseURL, elements: elements) }
                if delimiter == "&&" { return try bounded(lists.flatMap { $0 }) }
                var result: [String] = []
                for index in 0..<(lists.map(\.count).max() ?? 0) { for list in lists where list.indices.contains(index) { result.append(list[index]) } }
                return try bounded(result)
            }
        }
        let replacements = try replacementParts(rule)
        var values = try pipeline(replacements[0], content: content, baseURL: baseURL, elements: elements)
        if replacements.count > 1 {
            guard replacements.count <= 4 else { throw LegadoCompatibilityError.unsupported("多重正则替换分隔符") }
            let pattern = try interpolate(replacements[1], content: content, baseURL: baseURL)
            guard pattern.utf8.count <= 512 else { throw LegadoCompatibilityError.limit }
            let replacement = replacements.count > 2 ? try interpolate(replacements[2], content: content, baseURL: baseURL) : ""
            let regex = try NSRegularExpression(pattern: pattern)
            let start = ProcessInfo.processInfo.systemUptime
            values = try values.map { value in
                var matches: [NSTextCheckingResult] = [], stopped = false
                regex.enumerateMatches(in: value, options: [.reportProgress, .reportCompletion], range: NSRange(value.startIndex..., in: value)) { match, flags, stop in
                    if Task.isCancelled || ProcessInfo.processInfo.systemUptime - start > 0.2 || flags.contains(.internalError) || matches.count >= 2000 { stopped = true; stop.pointee = true; return }
                    if let match { matches.append(match) }
                }
                if stopped { try Task.checkCancellation(); throw LegadoCompatibilityError.limit }
                if replacements.count == 4 {
                    guard let match = matches.first else { return "" }
                    return regex.replacementString(for: match, in: value, offset: 0, template: replacement)
                }
                let source = value as NSString
                var output = "", offset = 0, bytes = 0
                for match in matches {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - start <= 0.2 else { throw LegadoCompatibilityError.limit }
                    let prefix = source.substring(with: NSRange(location: offset, length: match.range.location - offset))
                    let substituted = regex.replacementString(for: match, in: value, offset: 0, template: replacement)
                    bytes += prefix.utf8.count + substituted.utf8.count
                    guard bytes <= 2 * 1024 * 1024 else { throw LegadoCompatibilityError.limit }
                    output += prefix; output += substituted; offset = NSMaxRange(match.range)
                }
                let suffix = source.substring(from: offset)
                guard bytes + suffix.utf8.count <= 2 * 1024 * 1024 else { throw LegadoCompatibilityError.limit }
                return output + suffix
            }
        }
        return try bounded(values)
    }
    private func replacementParts(_ input: String) throws -> [String] {
        // Only the first separator needs selector/JS lexical analysis. Inside
        // the regex, quote characters are literals rather than JS strings.
        let parts = try LegadoRuleScanner.split(input, on: "##")
        guard parts.count > 1 else { return parts }
        return parts
    }
    private func pipeline(_ input: String, content: String, baseURL: URL?, elements: Bool) throws -> [String] {
        let chars = Array(input)
        var index = 0, start = 0, stack: [Character] = [], quote: Character?, escaped = false
        var result: Any = content
        while index < chars.count {
            let char = chars[index]
            if let active = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == active { quote = nil }
                index += 1; continue
            }
            if char == "\"" || char == "'" || char == "`" { quote = char; index += 1; continue }
            if stack.isEmpty, LegadoRuleScanner.matches(chars, index, "@js:") || LegadoRuleScanner.matches(chars, index, "<js>") {
                let prefix = String(chars[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    let selected = try select(prefix, content: string(result), baseURL: baseURL, elements: elements)
                    result = context.scalarJS ? selected.joined(separator: "\n") : selected
                }
                if LegadoRuleScanner.matches(chars, index, "@js:") {
                    result = try js(String(chars[(index + 4)...]), result: result, original: content, baseURL: baseURL)
                    return try strings(result)
                }
                guard let end = LegadoRuleScanner.scriptEnd(chars, from: index + 4) else { throw LegadoCompatibilityError.invalid("<js> 缺少 </js>") }
                result = try js(String(chars[(index + 4)..<end]), result: result, original: content, baseURL: baseURL)
                index = end + 5; start = index; continue
            }
            if char == "[" || char == "{" || char == "(" { stack.append(char) }
            else if char == "]" || char == "}" || char == ")" { if !stack.isEmpty { stack.removeLast() } }
            index += 1
        }
        let tail = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { return try select(tail, content: string(result), baseURL: baseURL, elements: elements) }
        return try strings(result)
    }
    private func select(_ original: String, content: String, baseURL: URL?, elements: Bool) throws -> [String] {
        var rule = original
        let chars = Array(rule); var index = 0, retained = "", quote: Character?, escaped = false
        while index < chars.count {
            let char = chars[index]
            if let active = quote {
                retained.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == active { quote = nil }
                index += 1; continue
            }
            if char == "\"" || char == "'" || char == "`" { quote = char; retained.append(char); index += 1; continue }
            if LegadoRuleScanner.matches(chars, index, "@put:") {
                let start = index + 5
                guard start < chars.count, chars[start] == "{" else { throw LegadoCompatibilityError.invalid("@put") }
                let end = try LegadoRuleScanner.balancedEnd(chars, from: start)
                guard let map = try JSONSerialization.jsonObject(with: Data(String(chars[start...end]).utf8)) as? [String: String] else { throw LegadoCompatibilityError.invalid("@put 需要规则字典") }
                guard map.count <= 128 else { throw LegadoCompatibilityError.limit }
                for key in map.keys.sorted() {
                    let value = try text(map[key]!, in: content, baseURL: baseURL)
                    guard key.utf8.count <= 512, value.utf8.count <= 128 * 1024,
                          context.variables.count < 512 || context.variables[key] != nil else { throw LegadoCompatibilityError.limit }
                    context.variables[key] = value
                }
                index = end + 1
            } else { retained.append(chars[index]); index += 1 }
        }
        rule = retained.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.isEmpty { return [] }
        if rule.hasPrefix("@get:{"), let end = rule.firstIndex(of: "}"), rule.index(after: end) == rule.endIndex {
            return [context.variables[String(rule[rule.index(rule.startIndex, offsetBy: 6)..<end])] ?? ""]
        }
        if rule.hasPrefix("{{"), (try? LegadoRuleScanner.balancedEnd(Array(rule), from: 0)) == rule.count - 1 {
            return [try interpolate(rule, content: content, baseURL: baseURL)]
        }
        rule = try interpolate(rule, content: content, baseURL: baseURL)
        if rule.lowercased().hasPrefix("@json:") { rule = String(rule.dropFirst(6)) }
        if rule.hasPrefix("$") {
            let values = try RuleExtraction.extract(.init(kind: .jsonPath, expression: rule), from: content)
            return try bounded(values.flatMap { value -> [String] in
                if let array = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [Any] { return try array.map(string) }
                return [value]
            })
        }
        if rule.lowercased().hasPrefix("@xpath:") { rule = String(rule.dropFirst(7)) }
        if rule.hasPrefix("/") { return try RuleExtraction.extract(.init(kind: .xpath, expression: rule, projection: elements ? .html : .text), from: content) }
        return try html(rule, content: content, elements: elements)
    }
    private func interpolate(_ input: String, content: String, baseURL: URL?) throws -> String {
        let chars = Array(input); var result = "", index = 0
        while index < chars.count {
            if LegadoRuleScanner.matches(chars, index, "{{") {
                let end = try LegadoRuleScanner.balancedEnd(chars, from: index)
                let expression = String(chars[(index + 2)..<(end - 1)]).trimmingCharacters(in: .whitespacesAndNewlines)
                if expression.hasPrefix("$") || expression.hasPrefix("@") || expression.hasPrefix("//") { result += try text(expression, in: content, baseURL: baseURL) }
                else if let value = context.variables[expression] { result += value }
                else if let value = context.bindings[expression] { result += try string(value) }
                else { result += try string(js(expression, result: content, original: content, baseURL: baseURL)) }
                index = end + 1
            } else if LegadoRuleScanner.matches(chars, index, "@get:{") {
                let end = try LegadoRuleScanner.balancedEnd(chars, from: index + 5)
                result += context.variables[String(chars[(index + 6)..<end])] ?? ""; index = end + 1
            } else { result.append(chars[index]); index += 1 }
            guard result.utf8.count <= 2 * 1024 * 1024 else { throw LegadoCompatibilityError.limit }
        }
        return result
    }
    private func js(_ script: String, result: Any, original: String, baseURL: URL?) throws -> Any {
        guard let evaluate = context.evaluateJS else { throw LegadoCompatibilityError.unsupported("JavaScript 宿主未连接") }
        var bindings = context.bindings
        if context.structuredInput, let text = result as? String, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) { bindings["result"] = json }
        else { bindings["result"] = result }
        bindings["src"] = original; if let baseURL { bindings["baseUrl"] = baseURL.absoluteString }
        return try evaluate(script, bindings)
    }
    private func html(_ original: String, content: String, elements: Bool) throws -> [String] {
        var rule = original
        if rule.lowercased().hasPrefix("@css:") { rule = String(rule.dropFirst(5)) }
        if rule.hasPrefix("@@") { rule = String(rule.dropFirst(2)) }
        var parts = try LegadoRuleScanner.split(rule, on: "@").filter { !$0.isEmpty }
        let projections = ["text", "ownText", "textNodes", "html", "all"]
        var projection = elements ? "all" : "text"
        if let last = parts.last, projections.contains(last) || (parts.count > 1 && !["class.", "id.", "tag."].contains(where: { last.hasPrefix($0) }) && last.range(of: #"^[A-Za-z_:][A-Za-z0-9_:.-]*$"#, options: .regularExpression) != nil) || (rule.hasPrefix("@") && parts.count == 1) {
            projection = last; parts.removeLast()
        }
        let lower = content.lowercased()
        guard !lower.contains("<!entity"), !(lower.contains("<!doctype") && (lower.contains("system") || lower.contains("public") || lower.contains("["))), content.filter({ $0 == "<" }).count <= 8000 else { throw LegadoCompatibilityError.limit }
        let document = try HTMLDocument(string: content)
        var nodes: [Fuzi.XMLElement]
        if parts.isEmpty {
            let body = Array(document.css("body"))
            nodes = context.structuredInput ? body.flatMap(\.children) : body
        } else { nodes = document.root.map { [$0] } ?? [] }
        for part in parts {
            try Task.checkCancellation()
            if part == "children" { nodes = nodes.flatMap(\.children); continue }
            if part.hasPrefix("text.") || part.hasPrefix("ownText.") { throw LegadoCompatibilityError.unsupported("jsoup 文本选择器 " + part) }
            var selector = part, position: Int?
            let dialects = [("class.", "."), ("id.", "#"), ("tag.", "")]
            if let dialect = dialects.first(where: { selector.hasPrefix($0.0) }) {
                selector = String(selector.dropFirst(dialect.0.count))
                if let dot = selector.lastIndex(of: "."), let number = Int(selector[selector.index(after: dot)...]) { position = number; selector = String(selector[..<dot]) }
                guard !selector.isEmpty, selector.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { throw LegadoCompatibilityError.unsupported("jsoup 选择器 " + part) }
                selector = dialect.1 + selector
            }
            try ExtractionRule(kind: .css, expression: selector).validate()
            nodes = nodes.flatMap { parent -> [Fuzi.XMLElement] in
                let selected = Array(parent.css(selector))
                guard let position else { return selected }
                let index = position < 0 ? selected.count + position : position
                return selected.indices.contains(index) ? [selected[index]] : []
            }
            guard nodes.count <= 2000 else { throw LegadoCompatibilityError.limit }
        }
        return try bounded(nodes.flatMap { node -> [String] in
            switch projection {
            case "all": return [node.rawXML]
            case "html": return [node.childNodes(ofTypes: [.Element, .Text, .CDataSection, .Comment]).map(\.rawXML).joined()]
            case "ownText": return [normalize(node.childNodes(ofTypes: [.Text, .CDataSection]).map(\.stringValue).joined(separator: " "))]
            case "textNodes": return node.childNodes(ofTypes: [.Text, .CDataSection]).map { normalize($0.stringValue) }.filter { !$0.isEmpty }
            case "text": return [normalize(try nodeText(node))]
            default: return node[projection].map { [$0] } ?? []
            }
        })
    }
    private func normalize(_ input: String) -> String { input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    private func nodeText(_ node: Fuzi.XMLElement, depth: Int = 0) throws -> String {
        try Task.checkCancellation(); guard depth <= 128 else { throw LegadoCompatibilityError.limit }
        if ["script", "style"].contains(node.tag?.lowercased() ?? "") { return "" }
        if node.tag?.lowercased() == "br" { return " " }
        let blocks = ["p", "div", "li", "section", "article", "h1", "h2", "h3", "tr", "td"]
        return try node.childNodes(ofTypes: [.Element, .Text, .CDataSection]).map { child in
            if let child = child as? Fuzi.XMLElement { let value = try nodeText(child, depth: depth + 1); return blocks.contains(child.tag?.lowercased() ?? "") ? " " + value + " " : value }
            return child.stringValue
        }.joined()
    }
    private func string(_ value: Any) throws -> String {
        if value is NSNull { return "" }
        if let value = value as? String { return value }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: bytes, as: UTF8.self)
    }
    private func strings(_ value: Any) throws -> [String] { try bounded((value as? [Any] ?? [value]).map(string)) }
    private func bounded(_ values: [String]) throws -> [String] {
        guard values.count <= 2000, values.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw LegadoCompatibilityError.limit }
        return values
    }
}
