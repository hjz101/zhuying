import Foundation
import Fuzi

enum RuleExtractionError: LocalizedError, Equatable {
    case invalid(String), limit, cancelled
    var errorDescription: String? { switch self {
    case .invalid(let reason): "规则不可执行：\(reason)"
    case .limit: "解析输入、执行时间或结果超过当前限制。"
    case .cancelled: "解析已取消。"
    } }
}
struct ExtractionRule: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case css, xpath, jsonPath, regex }
    enum Projection: String, Codable, CaseIterable, Sendable { case text, html, attribute }
    var version = 1
    var kind: Kind
    var expression: String
    var projection: Projection = .text
    var attribute: String? = nil
    var capture = 0
    func validate() throws {
        guard version == 1,!expression.isEmpty,expression.utf8.count <= 512,(0...20).contains(capture) else { throw RuleExtractionError.invalid("仅支持 v1，表达式最多 512 字节。") }
        if projection == .attribute { guard let attribute,!attribute.isEmpty,attribute.range(of:"^[A-Za-z_:][A-Za-z0-9_:.-]*$",options:.regularExpression) != nil else { throw RuleExtractionError.invalid("属性名无效。") } }
        switch kind {
        case .css:
            guard !expression.contains(":"),expression.range(of:"[{};\\\\]",options:.regularExpression) == nil else { throw RuleExtractionError.invalid("CSS v1 支持元素、class、id、属性及组合器，不支持伪类或转义。") }
        case .xpath:
            guard expression.hasPrefix("/"),!expression.contains("|"),!expression.contains("::"),expression.range(of:"[()]",options:.regularExpression) == nil,expression.components(separatedBy:"//").count <= 3 else { throw RuleExtractionError.invalid("XPath v1 仅支持元素路径、属性／位置谓词，不支持函数、轴、联合。") }
        case .jsonPath: _ = try JSONPathV1.parse(expression)
        case .regex:
            guard projection == .text else { throw RuleExtractionError.invalid("正则使用文本捕获组。") }
            _ = try NSRegularExpression(pattern:expression)
        }
    }
}
extension ExtractionRule {
    private enum Keys: String,CodingKey { case version,kind,expression,projection,attribute,capture }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy:Keys.self)
        version = try box.decodeIfPresent(Int.self,forKey:.version) ?? 1
        kind = try box.decode(Kind.self,forKey:.kind); expression = try box.decode(String.self,forKey:.expression)
        projection = try box.decodeIfPresent(Projection.self,forKey:.projection) ?? .text
        attribute = try box.decodeIfPresent(String.self,forKey:.attribute); capture = try box.decodeIfPresent(Int.self,forKey:.capture) ?? 0
    }
}
enum RuleExtraction {
    /// Preserve JSON value types for rule pipelines before projecting them to
    /// strings. A JSON string containing "[1,2]" is not an array selection.
    static func jsonValues(_ expression: String, from input: String) throws -> [Any] {
        try Task.checkCancellation()
        guard input.utf8.count <= 2 * 1024 * 1024 else { throw RuleExtractionError.limit }
        try ExtractionRule(kind: .jsonPath, expression: expression).validate()
        let json = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])
        let values = try JSONPathV1.select(json, tokens: JSONPathV1.parse(expression))
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed])
        guard bytes.count <= 2 * 1024 * 1024 else { throw RuleExtractionError.limit }
        return values
    }
    static let support = [
        "CSS v1：元素、class、id、属性选择、后代／子代／相邻／兄弟组合；输出文字、HTML 或属性。",
        "XPath v1：元素路径、属性与位置谓词；不支持函数、轴、联合或外部文档。",
        "JSONPath v1：$、.key、[数字]、[*]、[\"键名\"]；不支持递归、切片和过滤脚本。",
        "正则 v1：ICU 表达式与 0–20 捕获组；UTF-16 范围；限时并可取消。",
        "UTF-8 输入 ≤ 2 MiB，标记节点 ≤ 8000，最多 2000 项／合计 2 MiB 输出；解析不执行脚本、网络或外部实体。"
    ]
    static func extract(_ rule: ExtractionRule,from input: String) throws -> [String] {
        try rule.validate(); try Task.checkCancellation()
        guard input.utf8.count <= 2 * 1024 * 1024 else { throw RuleExtractionError.limit }
        var result: [String]
        switch rule.kind {
        case .css,.xpath:
            let lower = input.lowercased()
            guard !lower.contains("<!entity"),!lower.contains("<!doctype") || (!lower.contains("system") && !lower.contains("public") && !lower.contains("[")),input.filter({$0 == "<"}).count <= 8000 else { throw RuleExtractionError.invalid("拒绝外部实体或过大的标记树。") }
            let document = try HTMLDocument(string:input)
            let nodes = rule.kind == .css ? document.css(rule.expression) : document.xpath(rule.expression)
            result = []
            for node in nodes {
                try Task.checkCancellation(); guard result.count < 2000 else { throw RuleExtractionError.limit }
                switch rule.projection { case .text: result.append(node.stringValue); case .html: result.append(node.rawXML); case .attribute: if let value = node[rule.attribute!] { result.append(value) } }
            }
        case .jsonPath:
            let json = try JSONSerialization.jsonObject(with:Data(input.utf8),options:[.fragmentsAllowed])
            let values = try JSONPathV1.select(json,tokens:JSONPathV1.parse(rule.expression))
            result = try values.map { item in
                if let value = item as? String { return value }
                if item is NSNull { return "null" }
                let data = try JSONSerialization.data(withJSONObject:item,options:[.fragmentsAllowed,.sortedKeys]); return String(decoding:data,as:UTF8.self)
            }
        case .regex:
            let regex = try NSRegularExpression(pattern:rule.expression)
            guard rule.capture <= regex.numberOfCaptureGroups else { throw RuleExtractionError.invalid("捕获组不存在。") }
            let start = ProcessInfo.processInfo.systemUptime; var stopped = false,cancelled = false,values: [String] = []
            regex.enumerateMatches(in:input,options:[.reportProgress,.reportCompletion],range:NSRange(input.startIndex...,in:input)) { match,flags,stop in
                if Task.isCancelled { cancelled = true; stop.pointee = true; return }
                if ProcessInfo.processInfo.systemUptime - start > 0.2 || flags.contains(.internalError) { stopped = true; stop.pointee = true; return }
                guard let match else { return }; guard values.count < 2000 else { stopped = true; stop.pointee = true; return }
                let range = match.range(at:rule.capture); if range.location != NSNotFound { values.append((input as NSString).substring(with:range)) }
            }
            if cancelled { throw CancellationError() }; if stopped { throw RuleExtractionError.limit }; result = values
        }
        guard result.reduce(0,{$0 + $1.utf8.count}) <= 2 * 1024 * 1024 else { throw RuleExtractionError.limit }
        try Task.checkCancellation(); return result
    }
}
private enum JSONPathV1 {
    enum Token { case key(String), index(Int), wildcard }
    static func parse(_ expression: String) throws -> [Token] {
        let source = expression as NSString
        guard source.length > 0,source.substring(to:1) == "$" else { throw RuleExtractionError.invalid("JSONPath 必须从 $ 开始。") }
        let pattern = try NSRegularExpression(pattern:#"\G(?:\.([A-Za-z_][A-Za-z0-9_-]*)|\[(\d+)\]|\[(\*)\]|\[("(?:[^"\\]|\\.)*")\])"#)
        var tokens: [Token] = [],offset = 1
        while offset < source.length {
            guard tokens.count < 32,let match = pattern.firstMatch(in:expression,range:NSRange(location:offset,length:source.length - offset)),match.range.location == offset else { throw RuleExtractionError.invalid("JSONPath v1 不支持此语法。") }
            if match.range(at:1).location != NSNotFound { tokens.append(.key(source.substring(with:match.range(at:1)))) }
            else if match.range(at:2).location != NSNotFound { guard let index = Int(source.substring(with:match.range(at:2))),index <= 100000 else { throw RuleExtractionError.limit }; tokens.append(.index(index)) }
            else if match.range(at:3).location != NSNotFound { tokens.append(.wildcard) }
            else { let bytes = Data(source.substring(with:match.range(at:4)).utf8); guard let key = try JSONSerialization.jsonObject(with:bytes,options:.fragmentsAllowed) as? String else { throw RuleExtractionError.invalid("JSONPath 键名无效。") }; tokens.append(.key(key)) }
            offset = NSMaxRange(match.range)
        }
        return tokens
    }
    static func select(_ json: Any,tokens: [Token]) throws -> [Any] {
        var values: [Any] = [json]
        for token in tokens {
            try Task.checkCancellation(); var next: [Any] = []
            for value in values {
                switch token {
                case .key(let key): if let object = value as? [String:Any],let item = object[key] { next.append(item) }
                case .index(let index): if let list = value as? [Any],list.indices.contains(index) { next.append(list[index]) }
                case .wildcard: if let list = value as? [Any] { next += list } else if let object = value as? [String:Any] { next += object.keys.sorted().compactMap{object[$0]} }
                }
                guard next.count <= 2000 else { throw RuleExtractionError.limit }
            }
            values = next
        }
        return values
    }
}
