import Foundation
import PDFKit
import CoreFoundation

struct ParsedBookText {
    let text: String
    let encoding: String
}

protocol BookFormatParsing {
    var extensions: Set<String> { get }
    func parse(_ data: Data, encoding: ImportEncoding) throws -> ParsedBookText
}

enum BookFormatParsers {
    static let parsers: [any BookFormatParsing] = [PlainTextBookParser(), TextPDFBookParser()]
    static func parse(data: Data, extension format: String, encoding: ImportEncoding) throws -> ParsedBookText {
        guard let parser = parsers.first(where: { $0.extensions.contains(format.lowercased()) }) else {
            throw BookImportError.message("暂不支持 \(format.isEmpty ? "此格式" : format.uppercased())，请选择 TXT 或有文字层的 PDF。")
        }
        try Task.checkCancellation()
        return try parser.parse(data, encoding: encoding)
    }
}

struct PlainTextBookParser: BookFormatParsing {
    let extensions: Set<String> = ["txt"]
    func parse(_ data: Data, encoding: ImportEncoding) throws -> ParsedBookText {
        let value = try Self.decode(data, encoding: encoding)
        return .init(text: value.0, encoding: value.1)
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

/// PDF imports are explicitly text extraction, never a facsimile or OCR reader.
struct TextPDFBookParser: BookFormatParsing {
    let extensions: Set<String> = ["pdf"]
    func parse(_ data: Data, encoding: ImportEncoding) throws -> ParsedBookText {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw BookImportError.message("PDF 无法读取或需要密码。") }
        guard pdf.pageCount <= 2000 else { throw BookImportError.message("PDF 页数过多，暂支持 2000 页以内。") }
        var pages: [String] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            if let text = pdf.page(at: index)?.string { pages.append(text) }
        }
        return .init(text: pages.joined(separator: "\n\n"), encoding: "PDF 文字提取")
    }
}
