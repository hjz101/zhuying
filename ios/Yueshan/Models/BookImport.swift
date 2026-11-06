import Foundation
import CryptoKit

enum ImportEncoding: String, CaseIterable, Sendable {
    case automatic = "自动识别", utf8 = "UTF-8", gb18030 = "GB18030", utf16 = "UTF-16"
}

enum BookImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

struct PreparedBookImport: Sendable {
    let book: Book
    let bytes: Int
    let encoding: String
    var resources: [ResourceFileReference:Data] = [:]
}

enum BookImportInput: Sendable {
    case file(URL), remote(URL), text(String)
    indirect case originalPDF(BookImportInput)
    var name: String {
        switch self {
        case .file(let url), .remote(let url): return url.lastPathComponent.isEmpty ? "链接文件" : url.lastPathComponent
        case .text: return "剪贴板文本.txt"
        case .originalPDF(let input): return input.name
        }
    }
}

enum BookImporter {
    static let maximumBytes = 20 * 1024 * 1024

    static func remoteURL(_ input: String) throws -> URL {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw BookImportError.message("请输入完整的 https 文件链接；书源和主题链接请使用对应的导入入口。")
        }
        return url
    }

    static func load(_ input: BookImportInput, encoding: ImportEncoding, downloader: any BookImportDownloading = BoundedBookDownloader()) async throws -> PreparedBookImport {
        switch input {
        case .originalPDF(let original):
            switch original {
            case .file(let url):
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try validateSize(try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
                return try MediaBookImporter.originalPDF(Data(contentsOf:url),name:url.lastPathComponent)
            case .remote(let url): let file = try await downloader.fetch(url); return try MediaBookImporter.originalPDF(file.data,name:file.suggestedName ?? url.lastPathComponent)
            default: throw BookImportError.message("原版式 PDF 需要本地文件或 HTTPS 文件链接。")
            }
        case .text(let text): return try prepare(data: Data(text.utf8), name: input.name, encoding: .utf8)
        case .file(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw BookImportError.message("请选择文件，文件夹暂不支持导入。") }
            try validateSize(values.fileSize ?? 0)
            return try prepare(data: Data(contentsOf: url), name: url.lastPathComponent, encoding: encoding)
        case .remote(let url):
            let downloaded = try await downloader.fetch(url)
            let suggested = downloaded.suggestedName ?? url.lastPathComponent
            let name = (suggested as NSString).pathExtension.isEmpty ? url.lastPathComponent : suggested
            return try prepare(data: downloaded.data, name: name, encoding: encoding)
        }
    }

    static func validateSize(_ size: Int) throws {
        guard size > 0 else { throw BookImportError.message("文件为空，请选择有正文的文件。") }
        guard size <= maximumBytes else { throw BookImportError.message("单个文件暂支持 20 MB 以内。") }
    }

    static func prepare(data: Data, name: String, encoding: ImportEncoding = .automatic) throws -> PreparedBookImport {
        try Task.checkCancellation()
        try validateSize(data.count)
        let format = (name as NSString).pathExtension.lowercased()
        if format == "epub" {
            let parsed: EPUBBookParser.Result
            do { parsed = try EPUBBookParser.parse(data) }
            catch is CancellationError { throw CancellationError() }
            catch let error as BookImportError { throw error }
            catch { throw BookImportError.message("EPUB 文件无法解包，请检查文件是否完整。") }
            let book = Book(id: "local-" + StableContentID.list(parsed.chapters.flatMap { $0 }), title: parsed.title, author: parsed.author,
                            genre: "本地书籍", category: "其他", status: "已完结", words: "\(parsed.chapters.flatMap { $0 }.filter { !$0.hasPrefix(ReaderInlineImage.prefix) }.joined().count) 字",
                            color: "sage", subtitle: "EPUB", intro: parsed.chapters.flatMap { $0 }.first { !$0.hasPrefix(ReaderInlineImage.prefix) } ?? "EPUB 作品",
                            tags: ["本地", "EPUB"], chapters: parsed.titles, content: parsed.chapters)
            return .init(book: book, bytes: data.count, encoding: "EPUB 可重排文字／插图")
        }
        let parsed = try BookFormatParsers.parse(data: data, extension: format, encoding: encoding)
        let text = parsed.text, encodingName = parsed.encoding
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw BookImportError.message("没有可读取的正文；扫描版 PDF 暂不支持文字识别。") }
        guard !normalized.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13].contains($0.value)) }) else {
            throw BookImportError.message("内容不是可读文本，请检查文件或尝试其他编码。")
        }
        let digest = StableContentID.hex(SHA256.hash(data: Data(normalized.utf8)))
        let title = (name as NSString).deletingPathExtension
        var titles: [String] = [], chapters: [[String]] = [], paragraphs: [String] = []
        var currentTitle = "正文"
        let heading = try NSRegularExpression(pattern: "^(第[零〇一二三四五六七八九十百千万两0-9]+[章回卷节部篇].{0,60}|chapter\\s+[0-9ivxlcdm]+.{0,60})$", options: .caseInsensitive)
        for raw in normalized.components(separatedBy: "\n") {
            try Task.checkCancellation()
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                if !paragraphs.isEmpty { titles.append(currentTitle); chapters.append(paragraphs); paragraphs = [] }
                currentTitle = line
            } else {
                var start = line.startIndex
                while start < line.endIndex {
                    let end = line.index(start, offsetBy: 1200, limitedBy: line.endIndex) ?? line.endIndex
                    paragraphs.append(String(line[start..<end])); start = end
                }
            }
        }
        if !paragraphs.isEmpty { titles.append(currentTitle); chapters.append(paragraphs) }
        guard !chapters.isEmpty else { throw BookImportError.message("只有章节标题，没有正文。") }
        let book = Book(id: "local-\(digest)", title: title.isEmpty ? "未命名作品" : title, author: "本地导入", genre: "本地书籍",
                        category: "其他", status: "已完结", words: "\(normalized.count) 字", color: "sage", subtitle: format.uppercased(),
                        intro: String(normalized.prefix(160)), tags: ["本地", format.uppercased()], chapters: titles, content: chapters)
        return .init(book: book, bytes: data.count, encoding: encodingName)
    }


}

enum ImportItemStatus: Equatable { case ready, duplicate, imported, cancelled, failed(String) }
struct BookImportItem: Identifiable {
    let id = UUID()
    let input: BookImportInput
    var prepared: PreparedBookImport?
    var status: ImportItemStatus
}

@MainActor
final class BookImportSession: ObservableObject {
    @Published var items: [BookImportItem] = []
    @Published var selection = Set<UUID>()
    @Published var busy = false
    @Published var progressText = ""
    @Published var message: String?
    @Published var finished = false
    private let loader: any BookImportLoading
    private var activeLoad: Task<PreparedBookImport, Error>?
    private var cancelRequested = false
    init(loader: any BookImportLoading = NativeBookImportLoader()) { self.loader = loader }
    var cancelledCount: Int { items.filter { $0.status == .cancelled }.count }
    var retryableCount: Int { failedCount + cancelledCount }
    var readyCount: Int { items.filter { $0.status == .ready && selection.contains($0.id) }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var summary: String {
        "成功 \(items.filter { $0.status == .imported }.count) 项 · 重复 \(items.filter { $0.status == .duplicate }.count) 项 · 失败 \(failedCount) 项" + (cancelledCount > 0 ? " · 取消 \(cancelledCount) 项" : "")
    }

    func add(_ inputs: [BookImportInput], encoding: ImportEncoding, library: LibraryStore) async {
        guard !busy else { return }
        busy = true; cancelRequested = false; finished = items.contains { $0.status == .imported }; message = nil
        defer { activeLoad = nil; busy = false; progressText = "" }
        for (index, input) in inputs.enumerated() {
            if cancelRequested || Task.isCancelled { appendCancelled(Array(inputs.dropFirst(index))); break }
            progressText = "正在识别 \(index + 1) / \(inputs.count)"
            do {
                let loader = loader
                let task = Task.detached { try await loader.load(input, encoding: encoding) }
                activeLoad = task
                let prepared = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                guard !cancelRequested, !Task.isCancelled else { throw CancellationError() }
                let duplicate = library.books.contains { $0.id == prepared.book.id } || items.contains { $0.prepared?.book.id == prepared.book.id && ($0.status == .ready || $0.status == .imported) }
                let item = BookImportItem(input: input, prepared: prepared, status: duplicate ? .duplicate : .ready)
                items.append(item)
                if !duplicate { selection.insert(item.id) }
            } catch {
                if cancelRequested || Task.isCancelled || error is CancellationError {
                    appendCancelled(Array(inputs.dropFirst(index))); break
                }
                items.append(.init(input: input, status: .failed(error.localizedDescription)))
            }
        }
    }
    private func appendCancelled(_ inputs: [BookImportInput]) {
        items.append(contentsOf: inputs.map { .init(input: $0, status: .cancelled) })
        message = "已停止后续处理，已完成项目保留，可重试取消项。"
    }
    func cancel() {
        guard busy else { return }
        cancelRequested = true; activeLoad?.cancel()
        progressText = "正在停止，保留已完成项目"
        message = "已停止后续处理，已完成项目保留。"
    }

    func remove(_ id: UUID, library: LibraryStore) {
        guard !busy else { return }
        items.removeAll { $0.id == id }; selection.remove(id)
        // A second copy becomes available when its queued original is removed.
        for index in items.indices where items[index].status == .duplicate {
            guard let book = items[index].prepared?.book else { continue }
            if !library.books.contains(where: { $0.id == book.id }) && !items.contains(where: { $0.id != items[index].id && $0.prepared?.book.id == book.id && ($0.status == .ready || $0.status == .imported) }) {
                items[index].status = .ready; selection.insert(items[index].id)
            }
        }
    }

    func retry(encoding: ImportEncoding, library: LibraryStore) async {
        guard !busy else { return }
        var inputs: [BookImportInput] = [], removeIDs = Set<UUID>()
        var known = Set(library.books.map(\.id) + items.filter { $0.status == .ready || $0.status == .imported }.compactMap { $0.prepared?.book.id })
        for index in items.indices {
            guard items[index].status == .cancelled || { if case .failed = items[index].status { return true }; return false }() else { continue }
            if let prepared = items[index].prepared {
                let duplicate = !known.insert(prepared.book.id).inserted
                items[index].status = duplicate ? .duplicate : .ready
                if !duplicate { selection.insert(items[index].id) }
            } else { inputs.append(items[index].input); removeIDs.insert(items[index].id) }
        }
        items.removeAll { removeIDs.contains($0.id) }; finished = false; message = nil
        if !inputs.isEmpty { await add(inputs, encoding: encoding, library: library) }
    }

    func commit(library: LibraryStore, group: String) async {
        guard !busy, readyCount > 0 else { return }
        busy = true; cancelRequested = false; message = nil
        defer { busy = false; progressText = "" }
        for index in items.indices where items[index].status == .ready && selection.contains(items[index].id) {
            if cancelRequested || Task.isCancelled { break }
            progressText = "正在保存 \(items[index].input.name)"
            await Task.yield()
            if cancelRequested || Task.isCancelled { break }
            guard let prepared = items[index].prepared else { continue }
            do { items[index].status = try await library.importBookDurably(prepared.book, group: group,resources:prepared.resources) ? .imported : .duplicate }
            catch { items[index].status = .failed("保存失败：\(error.localizedDescription)") }
        }
        selection = selection.filter { id in items.contains { $0.id == id && $0.status == .ready } }
        finished = true
    }
}
