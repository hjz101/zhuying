import Foundation

/// Demo content uses the same chapter-loading contract as archived local books.
struct EmbeddedChapterRepository: ChapterDocumentLoading {
    let book: Book
    static func chapter(_ book: Book, index: Int) -> ChapterRecord {
        .init(id: StableContentID.make(book.id, "local-v1", String(index)), bookID: book.id,
              nativeChapterID: String(index), title: book.chapters[index], order: index, access: .readable)
    }
    func document(chapterID: String) async throws -> ChapterDocument? {
        guard let index = book.chapters.indices.first(where: { Self.chapter(book, index: $0).id == chapterID }),
              book.content.indices.contains(index), !book.content[index].isEmpty else { throw ContentFailure.missingChapter }
        return .init(chapterID: chapterID, paragraphs: book.content[index])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
