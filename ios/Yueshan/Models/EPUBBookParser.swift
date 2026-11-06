import Foundation
import ZIPFoundation
import UIKit
import ImageIO

/// Embedded raster resources live in immutable, hashed chapter objects, so a
/// restored book never depends on its original ZIP or a temporary extraction path.
enum ReaderInlineImage {
    static let prefix = "yueshan-inline-image-v1:"
    static func token(_ data: Data) throws -> String {
        guard data.count <= 2 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8000, height <= 8000, width * height <= 16_000_000 else {
            throw BookImportError.message("EPUB 插图无法读取或超过图片限制。")
        }
        return prefix + data.base64EncodedString()
    }
    static func data(_ text: String) -> Data? {
        guard text.hasPrefix(prefix), text.utf8.count <= 3 * 1024 * 1024 else { return nil }
        return Data(base64Encoded: String(text.dropFirst(prefix.count)))
    }
    static func plainText(_ text: String) -> String { text.hasPrefix(prefix) ? "［插图］" : text }
    static func image(_ text: String) -> UIImage? {
        guard let data = data(text), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct EPUBBookParser {
    struct Result { let title: String; let author: String; let titles: [String]; let chapters: [[String]] }
    static func parse(_ data: Data) throws -> Result {
        let archive = try Archive(data: data, accessMode: .read)
        var entries: [String: Entry] = [:], total: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type != .symlink, entry.path.utf8.count < 1024, !entry.path.hasPrefix("/"),
                  !entry.path.split(separator: "/").contains(".."), !entry.path.contains("\\"), entries[entry.path] == nil else { throw invalid() }
            total += entry.uncompressedSize
            guard total <= 64 * 1024 * 1024, entries.count < 4000 else { throw BookImportError.message("EPUB 解包后过大，暂支持 64 MB／4000 项以内。") }
            entries[entry.path] = entry
        }
        func read(_ path: String) throws -> Data {
            guard let entry = entries[path], entry.type == .file, entry.uncompressedSize <= 12 * 1024 * 1024 else { throw invalid() }
            var bytes = Data()
            let crc = try archive.extract(entry) { chunk in
                try Task.checkCancellation(); guard bytes.count + chunk.count <= 12 * 1024 * 1024 else { throw invalid() }; bytes.append(chunk)
            }
            guard crc == entry.checksum else { throw invalid() }
            return bytes
        }
        guard try String(data: read("mimetype"), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip",
              entries["META-INF/encryption.xml"] == nil else { throw BookImportError.message("仅支持未加密、可重排的 EPUB；加密或固定版式请使用原阅读软件。") }
        let container = EPUBXML(); try container.parse(read("META-INF/container.xml"))
        guard let root = container.rootfile else { throw invalid() }
        let packagePath = try resolve(root, relativeTo: "")
        let package = EPUBXML(); try package.parse(read(packagePath))
        guard !package.fixedLayout, !package.spine.isEmpty else { throw BookImportError.message("此 EPUB 是固定版式或没有可阅读目录，当前仅支持可重排文字 EPUB。") }
        var titles: [String] = [], chapters: [[String]] = [], imageBytes = 0
        for id in package.spine {
            try Task.checkCancellation()
            guard let item = package.manifest[id], ["application/xhtml+xml", "text/html"].contains(item.type) else { throw invalid() }
            let path = try resolve(item.href, relativeTo: packagePath)
            let chapter = EPUBXML(); try chapter.parse(read(path))
            var paragraphs: [String] = []
            for piece in chapter.pieces {
                switch piece {
                case .text(let text): if !text.isEmpty { paragraphs.append(text) }
                case .image(let href):
                    let bytes = try read(resolve(href, relativeTo: path)); imageBytes += bytes.count
                    guard imageBytes <= 8 * 1024 * 1024 else { throw BookImportError.message("EPUB 插图总量超过 8 MB，请使用较小的文件。") }
                    paragraphs.append(try ReaderInlineImage.token(bytes))
                }
            }
            if !paragraphs.isEmpty { titles.append(chapter.heading ?? "第 \(titles.count + 1) 节"); chapters.append(paragraphs) }
        }
        guard !chapters.isEmpty else { throw invalid() }
        return .init(title: package.title ?? "EPUB 作品", author: package.author ?? "本地导入", titles: titles, chapters: chapters)
    }
    static func resolve(_ href: String, relativeTo path: String) throws -> String {
        guard !href.contains("\\"), let parts = URLComponents(string: href), parts.scheme == nil, parts.host == nil,
              !parts.path.hasPrefix("/"), parts.query == nil else { throw invalid() }
        let root = URL(fileURLWithPath: "/epub-root/", isDirectory: true)
        let base = path.isEmpty ? root : root.appendingPathComponent(path).deletingLastPathComponent()
        let resolved = base.appendingPathComponent(parts.path).standardizedFileURL.path
        guard resolved.hasPrefix(root.path + "/") else { throw invalid() }
        return String(resolved.dropFirst(root.path.count + 1))
    }
    static func invalid() -> BookImportError { .message("EPUB 结构、资源路径或校验不完整，原文件未改动。") }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    enum Piece { case text(String), image(String) }
    var rootfile: String?, title: String?, author: String?, heading: String?
    var manifest: [String: (href: String, type: String)] = [:], spine: [String] = [], pieces: [Piece] = []
    var fixedLayout = false
    private var stack: [String] = [], text = "", capture = "", metadataText = "", skip = 0
    private let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "li", "blockquote", "section", "body"]
    func parse(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8), !source.localizedCaseInsensitiveContains("<!ENTITY"),
              !source.contains("<!DOCTYPE html [") else { throw EPUBBookParser.invalid() }
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse() else { throw EPUBBookParser.invalid() }; flush()
    }
    private func flush() {
        let value = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { pieces.append(.text(value)) }; text = ""
    }
    func parser(_ parser: XMLParser, didStartElement raw: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = raw.split(separator: ":").last.map(String.init) ?? raw; stack.append(name)
        if ["script", "style", "head"].contains(name) { skip += 1 }
        if name == "rootfile" { rootfile = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"], let type = attributes["media-type"] { manifest[id] = (href,type) }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        if name == "meta" && attributes["property"] == "rendition:layout" { capture = "layout"; metadataText = "" }
        if ["title", "creator"].contains(name) { capture = name; metadataText = "" }
        guard skip == 0 else { return }
        if blocks.contains(name) || name == "br" { flush() }
        if name == "img", let src = attributes["src"] { flush(); pieces.append(.image(src)) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !capture.isEmpty { metadataText += string }
        if skip == 0 { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement raw: String, namespaceURI: String?, qualifiedName: String?) {
        let name = raw.split(separator: ":").last.map(String.init) ?? raw
        if name == "title", capture == "title" { title = metadataText.trimmingCharacters(in: .whitespacesAndNewlines); capture = "" }
        if name == "creator", capture == "creator" { author = metadataText.trimmingCharacters(in: .whitespacesAndNewlines); capture = "" }
        if name == "meta", capture == "layout" { fixedLayout = metadataText.contains("pre-paginated"); capture = "" }
        if skip == 0, ["h1", "h2"].contains(name), heading == nil { heading = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if skip == 0 && blocks.contains(name) { flush() }
        if ["script", "style", "head"].contains(name) { skip -= 1 }
        _ = stack.popLast()
    }
}
