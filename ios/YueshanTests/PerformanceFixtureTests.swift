import XCTest
@testable import Yueshan

final class PerformanceFixtureTests: XCTestCase {
    func testFrozenBudgetIncludesAllScalesAndMeasurements() throws {
        let (budget, _) = try PerformanceBudget.load(bundle: Bundle(for: Self.self))
        XCTAssertEqual(budget.schemaVersion, 1)
        XCTAssertEqual(budget.profile, "simulator-debug-m4-ios26.5-v1")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: budget.frozenAt))
        XCTAssertGreaterThanOrEqual(budget.scales.shelfBooks, 1000)
        XCTAssertGreaterThanOrEqual(budget.scales.catalogChapters, 10000)
        XCTAssertGreaterThanOrEqual(budget.scales.longBookChapters, 1200)
        XCTAssertGreaterThanOrEqual(budget.scales.longChapterParagraphs * budget.scales.longChapterParagraphUTF16, 100000)
        XCTAssertEqual(Set(budget.limits.keys), Set(["library.import.ms", "library.open.ms", "shelf.sort.ms", "catalog.load.ms", "chapter.load.ms", "reader.compose.ms", "reader.paginate.ms", "reader.reflow.ms", "process.peak-rss.mib", "app.empty-launch.ms"]))
        XCTAssertTrue(budget.limits.values.allSatisfy { $0.isFinite && $0 > 0 })
    }
    func testOriginalFixturesAreDeterministicAndPreserveMixedUnicodeAndDistinctIdentities() {
        let a = PerformanceFixtures.book(id: "same", chapters: 3, paragraphs: 4, paragraphUTF16: 280)
        let b = PerformanceFixtures.book(id: "same", chapters: 3, paragraphs: 4, paragraphUTF16: 280)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.content.count, 3)
        XCTAssertTrue(a.content.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.utf16.count >= 280 } })
        let paragraphs = a.content.flatMap { $0 }
        XCTAssertEqual(Set(paragraphs).count, 12)
        for marker in ["👩🏽‍🚀", "👨‍👩‍👧‍👦", "e\u{301}", "𠮷", "🇨🇳", "مرحبا"] { XCTAssertTrue(paragraphs[0].contains(marker)) }
        let catalog = PerformanceFixtures.catalog(bookID: a.id, count: 10000)
        XCTAssertEqual(Set(catalog.map(\.id)).count, 10000)
        XCTAssertEqual(catalog.last?.order, 9999)
    }
}
