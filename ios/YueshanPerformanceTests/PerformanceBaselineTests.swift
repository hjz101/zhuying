import XCTest
import UIKit
import CoreText
import Darwin
@testable import Yueshan

@MainActor final class PerformanceBaselineTests: XCTestCase {
    struct Measurement: Codable {
        let id: String
        let samples: [Double]
        let median: Double
        let maximum: Double
        let limit: Double
        let withinTarget: Bool
    }
    struct Report: Codable {
        let schemaVersion: Int
        let profile: String
        let budgetSHA256: String
        let measuredAt: Date
        let os: String
        let model: String
        let configuration: String
        let scales: PerformanceBudget.Scales
        let measurements: [Measurement]
    }
    private var timings: [String: [Double]] = [:]
    private func traceMemory(_ stage: String) {
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        print("PERFORMANCE_MEMORY", stage, Double(usage.ru_maxrss) / 1_048_576)
    }
    private func record(_ id: String, started: Double) {
        timings[id, default: []].append((ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
    private func measureValue<T>(_ id: String, count: Int, _ operation: () throws -> T, validate: (T) throws -> Void) rethrows {
        for _ in 0..<count {
            try autoreleasepool {
                let started = ProcessInfo.processInfo.systemUptime
                let result = try operation()
                record(id, started: started)
                try validate(result)
            }
        }
    }
    private func validatePages(_ ranges: [NSRange], document: ReaderDocument) {
        XCTAssertGreaterThan(ranges.count, 1)
        var end = 0
        for range in ranges { XCTAssertEqual(range.location, end); XCTAssertGreaterThan(range.length, 0); end = NSMaxRange(range) }
        XCTAssertEqual(end, document.text.length, "No missing tail after pagination")
        let rebuilt = ranges.map { document.text.attributedSubstring(from: $0).string }.joined()
        XCTAssertEqual(rebuilt, document.text.string, "Unicode and prose must survive every page boundary")
        let anchor = ReaderAnchor(paragraph: document.paragraphRanges.count / 2, offset: 0)
        let page = ReaderPaginator.page(containing: anchor, document: document, ranges: ranges)
        XCTAssertTrue(NSLocationInRange(document.index(for: anchor), ranges[page]))
    }

    func testRecordStorageAndReaderBaselineWithoutChangingFrozenTargets() async throws {
        traceMemory("before-import")
        let (budget, raw) = try PerformanceBudget.load(bundle: Bundle(for: Self.self))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scale = budget.scales
        let longBook = PerformanceFixtures.book(id: "long-book", chapters: scale.longBookChapters, paragraphs: scale.longBookParagraphsPerChapter, paragraphUTF16: scale.longBookParagraphUTF16)
        for index in 0..<budget.storageSamples {
            let directory = root.appendingPathComponent("import-\(index)")
            let persistence = try ProductionLibraryPersistence(directory: directory)
            _ = try await persistence.bootstrap(legacySnapshot: nil, archiveURL: nil)
            let started = ProcessInfo.processInfo.systemUptime
            let added = try await persistence.importBook(longBook, group: "性能样本")
            record("library.import.ms", started: started)
            XCTAssertTrue(added)
            let reopened = try ProductionLibraryPersistence(directory: directory)
            let opening = ProcessInfo.processInfo.systemUptime
            let restored = try await reopened.bootstrap(legacySnapshot: nil, archiveURL: nil)
            record("library.open.ms", started: opening)
            XCTAssertEqual(restored.books, [longBook.metadataOnly()])
            XCTAssertEqual(restored.catalogs[longBook.id]?.count, scale.longBookChapters)
            let cachedCount = await reopened.cachedChapterCount()
            XCTAssertEqual(cachedCount, 0, "Opening a shelf must not load every chapter")
            XCTAssertEqual(restored.snapshot.favorites, [longBook.id])
        }
        let records = try SQLiteLibraryRepository(url: root.appendingPathComponent("catalog.sqlite"))
        traceMemory("after-import")
        for index in 0..<scale.shelfBooks { try await records.save(book: PerformanceFixtures.metadata(index), chapters: []) }
        let book = PerformanceFixtures.metadata(0)
        let catalog = PerformanceFixtures.catalog(bookID: book.id, count: scale.catalogChapters)
        try await records.save(book: book, chapters: catalog)
        for _ in 0..<budget.samples {
            let started = ProcessInfo.processInfo.systemUptime
            let loaded = try await records.chapters(bookID: book.id)
            record("catalog.load.ms", started: started)
            XCTAssertEqual(loaded, catalog)
        }
        let files = try FileChapterRepository(directory: root.appendingPathComponent("import-0/chapters"))
        traceMemory("after-catalog")
        for index in 0..<budget.samples {
            let id = StableContentID.make(longBook.id, "local-v1", String(index * 100))
            let started = ProcessInfo.processInfo.systemUptime
            let loaded = try await files.document(chapterID: id)
            record("chapter.load.ms", started: started)
            XCTAssertEqual(loaded?.paragraphs.map(\.text), longBook.content[index * 100])
        }
        let domain = "com.yueshan.performance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let books = (0..<scale.shelfBooks).map { PerformanceFixtures.book(id: "shelf-\($0)", chapters: 1, paragraphs: 1, paragraphUTF16: 40) }
        let progress = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.id, ReadingProgress(chapter: 0, paragraph: 0, updatedAt: Date(timeIntervalSince1970: Double($0.offset)))) })
        defaults.set(try JSONEncoder().encode(LibrarySnapshot(favorites: books.map(\.id), progress: progress)), forKey: LibraryStore.storageKey)
        let library = LibraryStore(books: books, defaults: defaults, seedDemoData: false)
        for sort in ShelfSort.allCases {
            library.sort = sort
            measureValue("shelf.sort.ms", count: budget.samples, { library.shelf }) { result in
                XCTAssertEqual(result.count, scale.shelfBooks)
                XCTAssertEqual(Set(result.map(\.id)), Set(books.map(\.id)))
            }
        }
        let longChapter = PerformanceFixtures.book(id: "long-chapter", chapters: 1, paragraphs: scale.longChapterParagraphs, paragraphUTF16: scale.longChapterParagraphUTF16)
        traceMemory("after-shelf")
        var settings = ReadingSettings()
        settings.preferences.showCommentBubbles = false; settings.preferences.showGodComments = false
        measureValue("reader.compose.ms", count: budget.samples, { ReaderDocument(book: longChapter, chapter: 0, settings: settings) }) { document in
            XCTAssertEqual(document.paragraphRanges.count, scale.longChapterParagraphs)
            for (index, range) in document.paragraphRanges.enumerated() {
                XCTAssertEqual(document.text.attributedSubstring(from: range).string, longChapter.content[0][index])
            }
        }
        let document = ReaderDocument(book: longChapter, chapter: 0, settings: settings)
        measureValue("reader.paginate.ms", count: budget.samples, { ReaderPaginator.ranges(document: document, size: CGSize(width: 393, height: 770)) }) { validatePages($0, document: document) }
        settings.fontSize = 30
        traceMemory("after-pagination")
        let large = ReaderDocument(book: longChapter, chapter: 0, settings: settings)
        measureValue("reader.reflow.ms", count: budget.samples, { ReaderPaginator.ranges(document: large, size: CGSize(width: 770, height: 393)) }) { validatePages($0, document: large) }
        var usage = rusage()
        traceMemory("after-reflow")
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        timings["process.peak-rss.mib"] = [Double(usage.ru_maxrss) / 1_048_576]
        let expected = Set(budget.limits.keys).subtracting(["app.empty-launch.ms"])
        XCTAssertEqual(Set(timings.keys), expected)
        let measurements = timings.keys.sorted().map { id -> Measurement in
            let samples = timings[id]!.sorted()
            let maximum = samples.last!, limit = budget.limits[id]!
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 > 0 })
            return .init(id: id, samples: timings[id]!, median: samples[samples.count / 2], maximum: maximum, limit: limit, withinTarget: maximum <= limit)
        }
        let report = Report(schemaVersion: 1, profile: budget.profile, budgetSHA256: StableContentID.version(String(decoding: raw, as: UTF8.self)), measuredAt: Date(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                            model: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown", configuration: "Debug simulator; reopen may use OS file cache", scales: scale, measurements: measurements)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
        let attachment = XCTAttachment(data: try encoder.encode(report), uniformTypeIdentifier: "public.json")
        attachment.name = "StepZero-Performance-Baseline"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testCompatibilityCorpusUsesActualFontFileThemeColorsAndMissingFontFallback() async throws {
        traceMemory("before-compatibility")
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "ReaderTestFont", withExtension: "ttf"))
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        defer { _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil) }
        XCTAssertTrue(ReadingFontLibrary.usesFile("YueshanReaderTest-Regular", url: url))
        let book = PerformanceFixtures.book(id: "compatibility", chapters: 1, paragraphs: 8, paragraphUTF16: 280)
        for name in ["YueshanReaderTest-Regular", "__serif__", "missing-performance-font"] {
            for dark in [false, true] {
                var settings = ReadingSettings(fontSize: 30)
                settings.preferences.fontName = name
                settings.preferences.colors = .init(background: dark ? 0x202820 : 0xFFF8EC, ink: dark ? 0xCAD4BC : 0x2D382E, accent: 0x97714A, name: "原创基线主题", dark: dark)
                settings.preferences.titleCSS = ".chapter-title { font-size: 32px; text-align: center; color: #97714A; }"
                settings.preferences.showCommentBubbles = false; settings.preferences.showGodComments = false
                let document = ReaderDocument(book: book, chapter: 0, settings: settings)
                let range = try XCTUnwrap(document.paragraphRanges.first)
                let font = try XCTUnwrap(document.text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
                XCTAssertEqual(font.pointSize, 30)
                if name == "YueshanReaderTest-Regular" { XCTAssertEqual(font.fontName, name) }
                if name == "missing-performance-font" { XCTAssertNotEqual(font.fontName, name) }
                let color = try XCTUnwrap(document.text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor)
                XCTAssertEqual(color, ReaderPalette(settings: settings).ink)
                validatePages(ReaderPaginator.ranges(document: document, size: CGSize(width: 240, height: 300)), document: document)
            }
        }
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='72' height='36' viewBox='0 0 72 36'><rect width='72' height='36' rx='12' fill='{{accent}}'/><text x='20' y='23' fill='white'>{{count}}</text></svg>"
        XCTAssertTrue(ThemeAssetValidator.isValid(svg, kind: .bubble))
        let theme = DemoTheme(id: "baseline", name: "原创基线主题", mode: .light, background: 0xFFF8EC, ink: 0x2D382E, accent: 0x97714A, summary: "自包含 SVG", source: "原创测试", version: "1")
        let png = try await ThemeBubbleRasterizer.render(svg, theme: theme)
        XCTAssertNotNil(UIImage(data: png), "The compatibility sample must actually render")
    }
}
