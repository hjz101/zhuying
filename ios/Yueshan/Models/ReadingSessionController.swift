import Foundation
import Combine

struct ReadingChapterRequest: Equatable, Sendable {
    let bookID: String
    let chapter: ChapterRecord
    var anchor: ReadingAnchor? = nil
    var atEnd = false
}

@MainActor
final class ReadingSessionController: ObservableObject {
    enum Phase: Equatable { case idle, loading, readable, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pending: ReadingChapterRequest?
    @Published private(set) var document: ChapterDocument?
    @Published private(set) var confirmed: ReadingAnchor?
    private let repository: any ChapterDocumentLoading
    private var generation = 0
    private var operation: Task<ChapterDocument?, Error>?

    init(repository: any ChapterDocumentLoading) { self.repository = repository }

    /// A requested chapter is never a reading location until its validated
    /// content arrives. Cancellation also invalidates adapters that return late.
    @discardableResult
    func load(_ request: ReadingChapterRequest) async -> Bool {
        operation?.cancel(); generation += 1
        let revision = generation
        pending = request; phase = .loading
        guard request.chapter.bookID == request.bookID, request.chapter.access == .readable else {
            phase = .failed(ContentFailure.missingChapter.localizedDescription); operation = nil; return false
        }
        let repository = repository
        let task = Task { try await repository.document(chapterID: request.chapter.id) }
        operation = task
        do {
            let loaded = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard revision == generation else { return false }
            guard let loaded, loaded.chapterID == request.chapter.id, !loaded.paragraphs.isEmpty,
                  loaded.paragraphs.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ContentFailure.invalidResponse }
            let paragraph: Int, offset: Int
            if let saved = request.anchor {
                guard saved.bookID == request.bookID else { throw ContentFailure.missingChapter }
                switch ReadingAnchorResolver.resolve(saved, in: loaded) {
                case let .exact(p, o), let .recovered(p, o): paragraph = p; offset = o
                default: throw ContentFailure.missingChapter
                }
            } else {
                paragraph = request.atEnd ? loaded.paragraphs.count - 1 : 0
                offset = request.atEnd ? (loaded.paragraphs[paragraph].text as NSString).length - 1 : 0
            }
            let location = try ReadingAnchor(bookID: request.bookID, document: loaded, paragraph: paragraph, offset: offset)
            document = loaded; confirmed = location; phase = .readable; pending = nil; operation = nil
            return true
        } catch {
            guard revision == generation else { return false }
            operation = nil
            if error is CancellationError || Task.isCancelled {
                phase = document == nil ? .idle : .readable; pending = nil
            } else { phase = .failed(error.localizedDescription) }
            return false
        }
    }

    @discardableResult func retry() async -> Bool {
        guard let pending else { return false }
        return await load(pending)
    }
    func cancel() {
        generation += 1; operation?.cancel(); operation = nil; pending = nil
        phase = document == nil ? .idle : .readable
    }
}
