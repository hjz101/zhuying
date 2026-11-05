import Foundation
import CryptoKit
import PDFKit
import CoreFoundation

enum ImportEncoding: String, CaseIterable {
    case automatic = "自动识别", utf8 = "UTF-8", gb18030 = "GB18030", utf16 = "UTF-16"
}

enum BookImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

struct PreparedBookImport {
    let book: Book
    let bytes: Int
    let encoding: String
}

enum BookImportInput {
    case file(URL), remote(URL), text(String)
    var name: String {
        switch self {
        case .file(let url), .remote(let url): return url.lastPathComponent.isEmpty ? "链接文件" : url.lastPathComponent
        case .text: return "剪贴板文本.txt"
        }
    }
}

enum BookImporter {
    static let maximumBytes = 20 * 1024 * 1024

    static func remoteURL(_ input: String) throws -> URL {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw BookImportError.message("请输入完整的 https 文件链接；书源和主题链接请使用对应的导入入口。")
        }
        return url
    }

    static func load(_ input: BookImportInput, encoding: ImportEncoding) async throws -> PreparedBookImport {
        switch input {
        case .text(let text): return try prepare(data: Data(text.utf8), name: input.name, encoding: .utf8)
        case .file(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw BookImportError.message("请选择文件，文件夹暂不支持导入。") }
            try validateSize(values.fileSize ?? 0)
            return try prepare(data: Data(contentsOf: url), name: url.lastPathComponent, encoding: encoding)
        case .remote(let url):
            let (file, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw BookImportError.message("下载失败，请检查链接后重试。")
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try validateSize(size)
            let suggested = response.suggestedFilename ?? url.lastPathComponent
            let name = (suggested as NSString).pathExtension.isEmpty ? url.lastPathComponent : suggested
            return try prepare(data: Data(contentsOf: file), name: name, encoding: encoding)
        }
    }

    static func validateSize(_ size: Int) throws {
        guard size > 0 else { throw BookImportError.message("文件为空，请选择有正文的文件。") }
        guard size <= maximumBytes else { throw BookImportError.message("单个文件暂支持 20 MB 以内。") }
    }

    static func prepare(data: Data, name: String, encoding: ImportEncoding = .automatic) throws -> PreparedBookImport {
        try validateSize(data.count)
        let format = (name as NSString).pathExtension.lowercased()
        let text: String
        let encodingName: String
        switch format {
        case "txt": (text, encodingName) = try decode(data, encoding: encoding)
        case "pdf":
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw BookImportError.message("PDF 无法读取或需要密码。") }
            guard pdf.pageCount <= 2000 else { throw BookImportError.message("PDF 页数过多，暂支持 2000 页以内。") }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
            encodingName = "PDF 文字提取"
        default: throw BookImportError.message("暂不支持 \(format.isEmpty ? "此格式" : format.uppercased())，请选择 TXT 或有文字层的 PDF。")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw BookImportError.message("没有可读取的正文；扫描版 PDF 暂不支持文字识别。") }
        guard !normalized.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13].contains($0.value)) }) else {
            throw BookImportError.message("内容不是可读文本，请检查文件或尝试其他编码。")
        }
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        let title = (name as NSString).deletingPathExtension
        var titles: [String] = [], chapters: [[String]] = [], paragraphs: [String] = []
        var currentTitle = "正文"
        let heading = try NSRegularExpression(pattern: "^(第[零〇一二三四五六七八九十百千万两0-9]+[章回卷节部篇].{0,60}|chapter\\s+[0-9ivxlcdm]+.{0,60})$", options: .caseInsensitive)
        for raw in normalized.components(separatedBy: "\n") {
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

    private static func decode(_ data: Data, encoding: ImportEncoding) throws -> (String, String) {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let choices: [(String.Encoding, String)]
        switch encoding {
        case .utf8: choices = [(.utf8, "UTF-8")]
        case .gb18030: choices = [(gb, "GB18030")]
        case .utf16: choices = [(.utf16, "UTF-16")]
        case .automatic:
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { choices = [(.utf16, "UTF-16")] }
            else { choices = [(.utf8, "UTF-8"), (gb, "GB18030")] }
        }
        for (encoding, title) in choices { if let text = String(data: data, encoding: encoding) { return (text.replacingOccurrences(of: "\u{FEFF}", with: ""), title) } }
        throw BookImportError.message("无法识别文本编码，请在更多选项中更换编码后重试。")
    }
}

enum ImportItemStatus: Equatable { case ready, duplicate, imported, failed(String) }
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
    var readyCount: Int { items.filter { $0.status == .ready && selection.contains($0.id) }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var summary: String {
        "成功 \(items.filter { $0.status == .imported }.count) 项 · 重复 \(items.filter { $0.status == .duplicate }.count) 项 · 失败 \(failedCount) 项"
    }

    func add(_ inputs: [BookImportInput], encoding: ImportEncoding, library: LibraryStore) async {
        guard !busy else { return }
        busy = true; finished = items.contains { $0.status == .imported }; message = nil
        defer { busy = false; progressText = "" }
        for (index, input) in inputs.enumerated() {
            progressText = "正在识别 \(index + 1) / \(inputs.count)"
            do {
                let prepared = try await Task.detached { try await BookImporter.load(input, encoding: encoding) }.value
                let duplicate = library.books.contains { $0.id == prepared.book.id } || items.contains { $0.prepared?.book.id == prepared.book.id && ($0.status == .ready || $0.status == .imported) }
                let item = BookImportItem(input: input, prepared: prepared, status: duplicate ? .duplicate : .ready)
                items.append(item)
                if !duplicate { selection.insert(item.id) }
            } catch { items.append(.init(input: input, status: .failed(error.localizedDescription))) }
        }
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
        let failed = items.filter { if case .failed = $0.status { return true }; return false }
        let ids = Set(failed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        await add(failed.map(\.input), encoding: encoding, library: library)
    }

    func commit(library: LibraryStore, group: String) async {
        guard !busy, readyCount > 0 else { return }
        busy = true
        defer { busy = false; progressText = "" }
        for index in items.indices where items[index].status == .ready && selection.contains(items[index].id) {
            progressText = "正在保存 \(items[index].input.name)"
            await Task.yield()
            guard let book = items[index].prepared?.book else { continue }
            do { items[index].status = try library.importBook(book, group: group) ? .imported : .duplicate }
            catch { items[index].status = .failed("保存失败：\(error.localizedDescription)") }
        }
        selection = selection.filter { id in items.contains { $0.id == id && $0.status == .ready } }
        finished = true
    }
}
