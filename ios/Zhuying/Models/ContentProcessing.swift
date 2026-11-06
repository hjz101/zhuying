import Foundation

struct ContentProcessingRule: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String,Codable,CaseIterable,Sendable { case regex = "正则",javascript = "JavaScript" }
    enum Scope: String,Codable,CaseIterable,Sendable { case all = "全部书籍",book = "当前书籍",source = "当前书源" }
    var id = UUID().uuidString
    var name: String
    var kind: Kind = .regex
    var pattern: String
    var replacement = ""
    var enabled = false
    var scope: Scope = .all
    var bookID: String? = nil
    var sourceID: String? = nil
    func validate() throws {
        guard !id.isEmpty,id.utf8.count <= 128,!name.isEmpty,name.count <= 100,!pattern.isEmpty,pattern.utf8.count <= (kind == .javascript ? 64 * 1024 : 2048),replacement.utf8.count <= 16000 else { throw RuleExtractionError.invalid("规则名称、表达式或替换文本超出限制。") }
        if scope == .book { guard let bookID,!bookID.isEmpty else { throw RuleExtractionError.invalid("请绑定目标书籍。") } }
        if scope == .source { guard let sourceID,!sourceID.isEmpty else { throw RuleExtractionError.invalid("请绑定目标书源。") } }
        if kind == .regex { _ = try NSRegularExpression(pattern:pattern) }
    }
    func applies(book: String,source: String?) -> Bool { enabled && (scope == .all || scope == .book && bookID == book || scope == .source && sourceID == source) }
}
struct ProcessedChapter: Sendable {
    let raw: ChapterDocument
    let document: ChapterDocument
    let origins: [String:String]
    let rulesVersion: String
}
extension Notification.Name {
    static let contentProcessingChanged = Notification.Name("contentProcessingChanged")
    static let contentProcessingFailed = Notification.Name("contentProcessingFailed")
}

actor ContentProcessingStore {
    private struct Package: Codable { let format: String; let version: Int; let rules: [ContentProcessingRule] }
    private struct Cached { let chapter: ProcessedChapter; let bytes: Int }
    let directory: URL
    private let writer: any AtomicFileWriting
    private var loaded: [ContentProcessingRule]?
    private var cached: [String:Cached] = [:]
    private var order: [String] = []
    private(set) var message: String?
    init(directory: URL,writer: any AtomicFileWriting = AtomicFileWriter(),previewRules: [ContentProcessingRule]? = nil) { self.directory = directory; self.writer = writer; loaded = previewRules }
    static func decode(_ data: Data) throws -> [ContentProcessingRule] {
        guard data.count <= 512 * 1024 else { throw RuleExtractionError.limit }
        let value = try JSONDecoder().decode(Package.self,from:data)
        guard BrandCompatibility.accepts(value.format, current:"zhuying-purification"),value.version == 1,value.rules.count <= 100,Set(value.rules.map(\.id)).count == value.rules.count else { throw RuleExtractionError.invalid("净化包格式或版本无效。") }
        for rule in value.rules { try rule.validate() }; return value.rules
    }
    static func encode(_ rules: [ContentProcessingRule]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let data = try encoder.encode(Package(format:"zhuying-purification",version:1,rules:rules)); _ = try decode(data); return data
    }
    func rules() throws -> [ContentProcessingRule] {
        if let loaded { return loaded }
        let file = directory.appendingPathComponent("rules.json")
        guard FileManager.default.fileExists(atPath:file.path) else { loaded = []; return [] }
        guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 512 * 1024 else { throw RuleExtractionError.limit }
        let rules = try Self.decode(Data(contentsOf:file)); loaded = rules; return rules
    }
    func revision() throws -> String { FileResourceStore.digest(try Self.encode(rules())) }
    func save(_ rules: [ContentProcessingRule]) async throws {
        try Task.checkCancellation()
        let bytes = try Self.encode(rules)
        guard rules.filter(\.enabled).count <= 20,rules.filter({$0.enabled && $0.kind == .javascript}).count <= 2 else { throw RuleExtractionError.invalid("最多启用 20 条规则，其中 JavaScript 最多 2 条。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try writer.write(bytes,to:directory.appendingPathComponent("rules.json")); loaded = rules; message = nil
        await MainActor.run { NotificationCenter.default.post(name:.contentProcessingChanged,object:nil) }
    }
    func context(bookID: String,document: ChapterDocument) -> ProcessedChapter? {
        let key = StableContentID.make(bookID,document.chapterID,document.originVersion ?? document.version)
        guard let value = cached[key],value.chapter.document.version == document.version else { return nil }; return value.chapter
    }
    func process(_ raw: ChapterDocument,bookID: String,sourceID: String?,useReplaceRule: Bool = true) async throws -> ProcessedChapter {
        try Task.checkCancellation()
        let key = StableContentID.make(bookID,raw.chapterID,raw.version),identity = Dictionary(uniqueKeysWithValues:raw.paragraphs.map{($0.id,$0.id)})
        // This gate applies after source extraction. It must not read rules,
        // return an earlier purified cache, or mutate the shared rule manifest.
        guard useReplaceRule else { return .init(raw:raw,document:raw,origins:identity,rulesVersion:"purification-disabled") }
        do {
            let all = try rules(),version = try revision(),active = all.filter{$0.applies(book:bookID,source:sourceID)}
            if active.isEmpty { return .init(raw:raw,document:raw,origins:identity,rulesVersion:version) }
            guard active.count <= 20,active.filter({$0.kind == .javascript}).count <= 2 else { throw RuleExtractionError.limit }
            if let previous = cached[key],previous.chapter.rulesVersion == version { return previous.chapter }
            var pairs = raw.paragraphs.map{($0.id,$0.text)}; let deadline = ProcessInfo.processInfo.systemUptime + 4
            for rule in active {
                try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuleExtractionError.limit }
                if rule.kind == .regex {
                    let regex = try NSRegularExpression(pattern:rule.pattern)
                    pairs = try pairs.compactMap { id,text in
                        if ReaderInlineImage.isToken(text) { return (id,text) }
                        let value = try Self.replace(regex,template:rule.replacement,text:text,deadline:deadline)
                        guard !ReaderInlineImage.isToken(value) else { throw RuleExtractionError.invalid("文字净化不生成图片资源。") }
                        return value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : (id,value)
                    }
                } else {
                    struct Item: Codable { let id: String; let text: String }
                    let prose = pairs.filter{!ReaderInlineImage.isToken($0.1)}.map{Item(id:$0.0,text:$0.1)}
                    let host = await NativeScriptHost()
                    let bytes = try await host.run(rule.pattern,input:JSONEncoder().encode(prose),policy:.init(sourceID:"purification:" + bookID + ":" + rule.id,timeout:min(1.5,max(0.1,deadline - ProcessInfo.processInfo.systemUptime))))
                    let result = try JSONDecoder().decode([Item].self,from:bytes),allowed = Set(prose.map(\.id)),ids = result.map(\.id)
                    guard Set(ids).count == ids.count,Set(ids).isSubset(of:allowed),prose.filter({ids.contains($0.id)}).map(\.id) == ids,
                          result.allSatisfy({!ReaderInlineImage.isToken($0.text) && $0.text.utf8.count <= 1024 * 1024}) else { throw RuleExtractionError.invalid("脚本应返回保留原 id、原顺序的段落数组；可删除段落，不可伪造身份。") }
                    let outputs = Dictionary(uniqueKeysWithValues:result.map{($0.id,$0.text)})
                    pairs = pairs.compactMap { id,text in if ReaderInlineImage.isToken(text) { return (id,text) }; guard let value = outputs[id],!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }; return (id,value) }
                }
                guard pairs.reduce(0,{$0 + $1.1.utf8.count}) <= 2 * 1024 * 1024 else { throw RuleExtractionError.limit }
            }
            guard !pairs.isEmpty else { throw RuleExtractionError.invalid("净化结果为空，保留有效正文。") }
            try Task.checkCancellation(); guard try revision() == version else { throw CancellationError() }
            let document = ChapterDocument(chapterID:raw.chapterID,paragraphs:pairs.map(\.1),originVersion:raw.version),origins = Dictionary(uniqueKeysWithValues:document.paragraphs.enumerated().map{($0.element.id,pairs[$0.offset].0)})
            let result = ProcessedChapter(raw:raw,document:document,origins:origins,rulesVersion:version),bytes = raw.paragraphs.reduce(0,{$0 + $1.text.utf16.count * 2}) + document.paragraphs.reduce(0,{$0 + $1.text.utf16.count * 2})
            cached[key] = .init(chapter:result,bytes:bytes); order.removeAll{$0 == key}; order.append(key)
            while order.count > 1 && (order.count > 3 || cached.values.reduce(0,{$0 + $1.bytes}) > 6 * 1024 * 1024) { cached.removeValue(forKey:order.removeFirst()) }
            message = nil; return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            let text = "净化处理未完成，已保留有效正文。"
            if message != text { message = text; await MainActor.run { NotificationCenter.default.post(name:.contentProcessingFailed,object:nil,userInfo:["bookID":bookID,"message":text]) } }
            return cached[key]?.chapter ?? .init(raw:raw,document:raw,origins:identity,rulesVersion:"raw-fallback")
        }
    }
    private static func replace(_ regex: NSRegularExpression,template: String,text: String,deadline: TimeInterval) throws -> String {
        var matches: [NSTextCheckingResult] = [],failed = false,cancelled = false
        regex.enumerateMatches(in:text,options:[.reportProgress,.reportCompletion],range:NSRange(text.startIndex...,in:text)) { match,flags,stop in
            if Task.isCancelled { cancelled = true; stop.pointee = true; return }
            if ProcessInfo.processInfo.systemUptime >= deadline || flags.contains(.internalError) { failed = true; stop.pointee = true; return }
            if let match { if matches.count >= 5000 { failed = true; stop.pointee = true; return }; matches.append(match) }
        }
        if cancelled { throw CancellationError() }; if failed { throw RuleExtractionError.limit }
        let source = text as NSString; var output = "",offset = 0
        for match in matches {
            output += source.substring(with:NSRange(location:offset,length:match.range.location - offset))
            output += regex.replacementString(for:match,in:text,offset:0,template:template); offset = NSMaxRange(match.range)
            guard output.utf8.count <= 2 * 1024 * 1024 else { throw RuleExtractionError.limit }
        }
        output += source.substring(from:offset); return output
    }
}

struct ProcessedChapterRepository: ChapterDocumentLoading {
    let base: any ChapterDocumentLoading
    let processor: ContentProcessingStore
    let bookID: String
    let sourceID: String?
    var useReplaceRule = true
    func document(chapterID: String) async throws -> ChapterDocument? {
        guard let raw = try await base.document(chapterID:chapterID) else { return nil }
        return try await processor.process(raw,bookID:bookID,sourceID:sourceID,useReplaceRule:useReplaceRule).document
    }
    func refreshedDocument(chapterID: String) async throws -> ChapterDocument? {
        guard let raw = try await base.refreshedDocument(chapterID:chapterID) else { return nil }
        return try await processor.process(raw,bookID:bookID,sourceID:sourceID,useReplaceRule:useReplaceRule).document
    }
}
