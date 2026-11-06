#if DEBUG
import UIKit
import Darwin

@MainActor enum NativePerformanceValidation {
    static let processStarted = ProcessInfo.processInfo.systemUptime
    struct Report: Codable {
        let schemaVersion: Int
        let method: String
        let measuredAt: Date
        let appInitializationToReadyMS: Double
        let paginateMS: Double
        let reflowMS: Double
        let peakRSSMiB: Double
        let utf16Units: Int
        let pages: Int
        let contentPreserved: Bool
    }
    static func measure(readyMS: Double) -> Report {
        let seed = "山间来信：读者👩🏽‍🚀与家人👨‍👩‍👧‍👦看见星光。e\u{301} / café / 𠮷 / 🇨🇳 / مرحبا / 12345，‘保留文字位置’。"
        let paragraphs = (0..<360).map { index -> String in
            var text = "段落 \(index)："
            while text.utf16.count < 280 { text += seed }
            return text
        }
        let book = Book(id: "local-diagnostic", title: "原创排版样本", author: "阅山测试", genre: "本地", category: "其他", status: "测试", words: "测试规模", color: "sage", subtitle: "测试", intro: "原创测试样本", tags: [], chapters: ["第一章 原创排版"], content: [paragraphs])
        var settings = ReadingSettings(); settings.preferences.showCommentBubbles = false; settings.preferences.showGodComments = false
        let document = ReaderDocument(book: book, chapter: 0, settings: settings)
        var start = ProcessInfo.processInfo.systemUptime
        let ranges = ReaderPaginator.ranges(document: document, size: CGSize(width: 393, height: 770))
        let paginate = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let exact = ranges.map { document.pageText(in: $0).string }.joined() == document.text.string
        settings.fontSize = 30
        let large = ReaderDocument(book: book, chapter: 0, settings: settings)
        start = ProcessInfo.processInfo.systemUptime
        let reflow = ReaderPaginator.ranges(document: large, size: CGSize(width: 770, height: 393))
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        return .init(schemaVersion: 1, method: "Debug simulator App process without XCTest injection; initialization-to-ready excludes dyld; complements but does not replace frozen XCTest criteria",
                     measuredAt: Date(), appInitializationToReadyMS: readyMS, paginateMS: paginate, reflowMS: elapsed,
                     peakRSSMiB: Double(usage.ru_maxrss) / 1_048_576, utf16Units: document.text.length, pages: ranges.count,
                     contentPreserved: exact && reflow.map { large.pageText(in: $0).string }.joined() == large.text.string)
    }
    static func writeReport(readyMS: Double) throws {
        let report = measure(readyMS: readyMS)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DevelopmentValidation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("native-performance.json"), options: .atomic)
    }
}
#endif
