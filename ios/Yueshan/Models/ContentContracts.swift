import Foundation
import CryptoKit

enum ContentFailure: Error, LocalizedError, Equatable, Sendable {
    case authenticationRequired, unavailable, restricted, missingChapter, invalidResponse, storageFailure
    case offline, timedOut, rateLimited, sourceDisabled, cacheMiss
    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "请先登录书源，或重新登录后重试。"
        case .unavailable: "暂时无法连接书源，请稍后重试。"
        case .restricted: "该章节暂不可阅读。"
        case .missingChapter: "原章节已不可用，请重新选择章节；之前的阅读记录已保留。"
        case .invalidResponse: "书源返回的内容无法识别，请稍后重试。"
        case .storageFailure: "保存失败，请检查设备空间后重试。"
        case .offline: "当前没有网络，已缓存章节仍可阅读。"
        case .timedOut: "书源响应超时，请重试。"
        case .rateLimited: "书源请求频繁，请稍后重试。"
        case .sourceDisabled: "书源已停用或移除，书架、缓存与历史记录保留。"
        case .cacheMiss: "该章节尚未缓存，请联网并启用书源后重试。"
        }
    }
}

enum StableContentID {
    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 15)]) }
        return String(decoding: result, as: UTF8.self)
    }
    /// Encode components, rather than concatenate delimiters which may occur in IDs.
    static func make(_ components: String...) -> String {
        list(components)
    }
    static func list(_ components: [String]) -> String {
        var bytes = Data()
        for component in components {
            let value = Data(component.utf8)
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        return hex(SHA256.hash(data: bytes))
    }
    static func version(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }
}

struct SourceBookReference: Codable, Equatable, Sendable {
    let sourceID: String
    let nativeBookID: String
    var provider: String
    var bookURL: String
    var remoteBookID: String = ""
    var origin: String? = nil
    var id: String { origin.map { StableContentID.make(sourceID, $0, nativeBookID) } ?? StableContentID.make(sourceID, nativeBookID) }
}

struct LibraryBookRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var author: String
    var summary: String
    var coverURL: String?
    var source: SourceBookReference?
    var addedAt: Date
    var display: BookDisplayMetadata? = nil
}

/// Presentation metadata retained when migrating the existing Demo book model.
/// Text remains in the chapter repository, never in this metadata record.
struct BookDisplayMetadata: Codable, Equatable, Sendable {
    var genre: String
    var category: String
    var status: String
    var words: String
    var color: String
    var subtitle: String
    var tags: [String]
}

struct ChapterRecord: Codable, Identifiable, Equatable, Sendable {
    enum Access: String, Codable, Sendable { case readable, restricted, volume }
    let id: String
    let bookID: String
    let nativeChapterID: String
    var title: String
    var order: Int
    var access: Access
    /// Opaque adapter parameters, never a script or credentials.
    var requestParameters: [String: String] = [:]
}

struct ContentParagraph: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let text: String
}

struct ChapterDocument: Codable, Equatable, Sendable {
    let chapterID: String
    let version: String
    let paragraphs: [ContentParagraph]

    init(chapterID: String, paragraphs texts: [String]) {
        self.chapterID = chapterID
        version = StableContentID.list(texts)
        var occurrences: [String: Int] = [:]
        paragraphs = texts.map { text in
            let digest = StableContentID.version(text)
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            return ContentParagraph(id: StableContentID.make(chapterID, digest, String(occurrence)), text: text)
        }
    }
}

struct ReadingAnchor: Codable, Equatable, Sendable {
    let bookID: String
    let chapterID: String
    let contentVersion: String
    let paragraphID: String
    let paragraphIndex: Int
    let utf16Offset: Int
    let quote: String
    let offsetInQuote: Int
    let paragraphCount: Int?
    var updatedAt: Date

    init(bookID: String, document: ChapterDocument, paragraph: Int, offset: Int, now: Date = Date()) throws {
        guard document.paragraphs.indices.contains(paragraph), !document.paragraphs[paragraph].text.isEmpty else { throw ContentFailure.missingChapter }
        self.bookID = bookID; chapterID = document.chapterID; contentVersion = document.version
        let content = document.paragraphs[paragraph]
        paragraphID = content.id; paragraphIndex = paragraph
        paragraphCount = document.paragraphs.count
        let text = content.text as NSString
        utf16Offset = Self.safeOffset(offset, in: text)
        let start = Self.safeOffset(max(0, utf16Offset - 24), in: text)
        let proposedEnd = min(text.length, utf16Offset + 48)
        let end = proposedEnd == text.length ? proposedEnd : Self.safeOffset(proposedEnd, in: text)
        quote = text.substring(with: NSRange(location: start, length: end - start))
        offsetInQuote = utf16Offset - start; updatedAt = now
    }

    static func safeOffset(_ offset: Int, in text: NSString) -> Int {
        guard text.length > 0 else { return 0 }
        let bounded = min(max(0, offset), text.length - 1)
        return text.rangeOfComposedCharacterSequence(at: bounded).location
    }
}

enum AnchorResolution: Equatable {
    case exact(paragraph: Int, offset: Int)
    case recovered(paragraph: Int, offset: Int)
    case unresolved
    case missingChapter
}

enum ReadingAnchorResolver {
    static func resolve(_ anchor: ReadingAnchor, in document: ChapterDocument) -> AnchorResolution {
        guard anchor.chapterID == document.chapterID else { return .missingChapter }
        if let index = document.paragraphs.firstIndex(where: { $0.id == anchor.paragraphID }) {
            if anchor.contentVersion != document.version,
               document.paragraphs.filter({ $0.text == document.paragraphs[index].text }).count > 1 { return .unresolved }
            let offset = ReadingAnchor.safeOffset(anchor.utf16Offset, in: document.paragraphs[index].text as NSString)
            return anchor.contentVersion == document.version ? .exact(paragraph: index, offset: offset) : .recovered(paragraph: index, offset: offset)
        }
        guard !anchor.quote.isEmpty else { return .unresolved }
        var matches: [(Int, Int)] = []
        for (index, paragraph) in document.paragraphs.enumerated() {
            let text = paragraph.text as NSString
            var start = 0
            while start < text.length {
                let range = text.range(of: anchor.quote, range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound else { break }
                matches.append((index, ReadingAnchor.safeOffset(range.location + anchor.offsetInQuote, in: text)))
                if matches.count > 1 { return .unresolved }
                start = range.location + max(1, range.length)
            }
        }
        guard let match = matches.first else { return .unresolved }
        return .recovered(paragraph: match.0, offset: match.1)
    }
}

struct BookSearchPage: Equatable, Sendable {
    var books: [LibraryBookRecord]
    /// nil means the adapter has reached its final page, or does not support pagination.
    var nextPage: Int?
    /// An aggregate source may return usable results while some providers fail.
    var hasPartialFailures = false
    var sourceReports: [SourceSearchReport] = []
}

protocol BookSource: Sendable {
    var sourceID: String { get }
    func search(query: String, page: Int) async throws -> BookSearchPage
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord]
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument
}

protocol ChapterDocumentLoading: Sendable {
    func document(chapterID: String) async throws -> ChapterDocument?
}
protocol ChapterContentRepository: ChapterDocumentLoading {
    func save(_ document: ChapterDocument) async throws
}

protocol LibraryRecordRepository: Sendable {
    func books() async throws -> [LibraryBookRecord]
    func save(book: LibraryBookRecord, chapters: [ChapterRecord]) async throws
    func chapters(bookID: String) async throws -> [ChapterRecord]
    func progress(bookID: String) async throws -> ReadingAnchor?
    func save(progress: ReadingAnchor) async throws
}
