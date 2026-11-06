import Foundation
import GRDB

struct IndexedChapter: Sendable { let bookID: String; let document: ChapterDocument }
struct TextSearchHit: Identifiable, Equatable, Sendable {
    var id: String { StableContentID.make(bookID, chapterID, String(paragraph), String(offset)) }
    let bookID: String
    let chapterID: String
    let version: String
    let paragraph: Int
    let offset: Int
    let text: String
}

/// Disposable trigram index; short Chinese words and punctuation use an exact
/// substring fallback. Original UTF-16 offsets always come from the stored text.
actor TextSearchIndex {
    private let database: DatabaseQueue
    init(url: URL? = nil) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        database = try url.map { try DatabaseQueue(path: $0.path) } ?? DatabaseQueue()
        try database.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS content_index USING fts5(bookID UNINDEXED, chapterID UNINDEXED, version UNINDEXED, paragraph UNINDEXED, text, tokenize='trigram')")
        }
    }
    func replace(_ chapters: [IndexedChapter]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM content_index")
            for chapter in chapters {
                try Task.checkCancellation()
                for (index, paragraph) in chapter.document.paragraphs.enumerated() where !paragraph.text.hasPrefix(ReaderInlineImage.prefix) {
                    try db.execute(sql: "INSERT INTO content_index(bookID,chapterID,version,paragraph,text) VALUES (?,?,?,?,?)", arguments: [chapter.bookID, chapter.document.chapterID, chapter.document.version, index, paragraph.text])
                }
            }
        }
    }
    func search(_ input: String, bookID: String? = nil, limit: Int = 200) throws -> [TextSearchHit] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf16.count <= 200 else { return [] }
        return try database.read { db in
            var sql = "SELECT bookID,chapterID,version,paragraph,text FROM content_index WHERE instr(text, ?) > 0"
            var args: StatementArguments = [query]
            if query.count >= 3 && query.unicodeScalars.allSatisfy({ !CharacterSet.nonBaseCharacters.contains($0) }) {
                sql += " AND content_index MATCH ?"; args += ["\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""]
            }
            if let bookID { sql += " AND bookID=?"; args += [bookID] }
            sql += " ORDER BY bookID,chapterID,CAST(paragraph AS INTEGER) LIMIT ?"; args += [max(1,min(500,limit))]
            var result: [TextSearchHit] = []
            for row in try Row.fetchAll(db, sql: sql, arguments: args) {
                let text: String = row["text"], string = text as NSString
                var start = 0
                while start < string.length && result.count < limit {
                    let range = string.range(of: query, range: NSRange(location: start, length: string.length - start))
                    if range.location == NSNotFound { break }
                    result.append(.init(bookID: row["bookID"], chapterID: row["chapterID"], version: row["version"], paragraph: row["paragraph"], offset: range.location, text: text))
                    start = range.location + max(1,range.length)
                }
            }
            return result
        }
    }
}
