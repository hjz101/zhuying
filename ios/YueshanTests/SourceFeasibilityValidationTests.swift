import XCTest
@testable import Yueshan

private struct FeasibilityFixtureSource: BookSource {
    let sourceID = "fixture"
    var repeatedWork = false
    var restricted = false
    var wrongDocument = false
    var duplicateBody = false
    var cancel = false
    var placeholder = false
    var repeatedAcrossWorks = false
    var shortPreface = false
    func search(query: String, page: Int) async throws -> BookSearchPage {
        if cancel { throw CancellationError() }
        if page > 1 { return .init(books: [], nextPage: nil) }
        let title = repeatedWork ? "one" : query
        return .init(books: [.init(id: title, title: title, author: "原创测试", summary: "", addedAt: Date(timeIntervalSince1970: 0))], nextPage: nil)
    }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { book }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] {
        (0..<(shortPreface ? 5 : 4)).map { .init(id: "\(book.id)-\($0)", bookID: book.id, nativeChapterID: "\($0)", title: "章 \($0)", order: $0,
                           access: $0 == 0 ? .volume : restricted && $0 == 2 ? .restricted : .readable) }
    }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument {
        let text = placeholder || (shortPreface && chapter.order == 1) ? "第\(chapter.order)页内容" : (duplicateBody ? "重复正文" : "本章的原创内容 \(repeatedAcrossWorks ? chapter.nativeChapterID : chapter.id)") + String(repeating: "山谷间传来回声，读者记下每一个不同的日子。", count: 20)
        return .init(chapterID: wrongDocument ? "another-chapter" : chapter.id, paragraphs: [text])
    }
}

@MainActor final class SourceFeasibilityValidationTests: XCTestCase {
    func testTwoDifferentWorksRequireThreeConsecutiveReadableChaptersAndRecordPagination() async throws {
        let report = await SourceFeasibilityValidation.run(source: FeasibilityFixtureSource(), queries: ["one", "two"])
        XCTAssertEqual(report.status, "passed")
        XCTAssertEqual(report.works.map(\.title), ["one", "two"])
        for work in report.works {
            XCTAssertEqual(work.volumeCount, 1)
            XCTAssertEqual(work.chapters.map(\.order), [1, 2, 3])
            XCTAssertEqual(Set(work.chapters.map(\.contentHash)).count, 3)
            XCTAssertTrue(work.chapters.allSatisfy { $0.paragraphCount == 1 && $0.utf16Count > 0 })
        }
        XCTAssertEqual(report.events.filter { $0.stage == "pagination" }.map(\.result), ["page-2-empty", "page-2-empty"])
    }

    func testRepeatedWorkRestrictedGapWrongChapterAndDuplicateProseNeverPass() async {
        let cases = [FeasibilityFixtureSource(repeatedWork: true), .init(restricted: true), .init(wrongDocument: true), .init(duplicateBody: true), .init(placeholder: true), .init(repeatedAcrossWorks: true)]
        for source in cases {
            let report = await SourceFeasibilityValidation.run(source: source, queries: ["one", "two"])
            XCTAssertEqual(report.status, "failed")
            XCTAssertEqual(report.events.last?.stage, "failure")
        }
        let partial = await SourceFeasibilityValidation.run(source: FeasibilityFixtureSource(), queries: ["one"])
        XCTAssertEqual(partial.status, "failed", "One work is insufficient")
    }

    func testCancellationIsDistinctAndDoesNotProduceSuccessfulWorks() async {
        let report = await SourceFeasibilityValidation.run(source: FeasibilityFixtureSource(cancel: true), queries: ["one", "two"])
        XCTAssertEqual(report.status, "cancelled")
        XCTAssertTrue(report.works.isEmpty)
        XCTAssertEqual(report.events.last?.result, "cancelled")
    }
    func testShortPrefaceCanPrecedeARealRunWithoutSkippingAChapterInsideThatRun() async {
        let report = await SourceFeasibilityValidation.run(source: FeasibilityFixtureSource(shortPreface: true), queries: ["one", "two"])
        XCTAssertEqual(report.status, "passed")
        XCTAssertEqual(report.works.map { $0.chapters.map(\.order) }, [[2, 3, 4], [2, 3, 4]])
    }
    func testProbeQueriesRequireTwoDistinctNonemptyBoundedBookNames() throws {
        XCTAssertEqual(try SourceFeasibilityValidation.queries(arguments: []), ["西游记", "红楼梦"])
        XCTAssertEqual(try SourceFeasibilityValidation.queries(arguments: ["--source-validation-queries", " 作品甲 | 作品乙 "]), ["作品甲", "作品乙"])
        for value in ["", "一", "一|", "一|一", "一|二|三", String(repeating: "a", count: 81) + "|二"] {
            XCTAssertThrowsError(try SourceFeasibilityValidation.queries(arguments: ["--source-validation-queries", value]))
        }
        XCTAssertThrowsError(try SourceFeasibilityValidation.queries(arguments: ["--source-validation-queries"]))
    }

    private struct PrivateResponseTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let data = Data("{\"data\":{\"user\":{\"api_key\":\"private-key\"},\"content\":\"private-prose\",\"private-as-key\":\"secret\"}}".utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    func testTransportReportRedactsHeadersQueryBodyResponseValuesAndUnknownSchemaKeys() async throws {
        let transport = SourceValidationTransport(base: PrivateResponseTransport())
        var request = URLRequest(url: URL(string: "https://example.test/content?key=private-query")!)
        request.setValue("private-header", forHTTPHeaderField: "X-Api-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cid": "private-body", "url": "https://example.test/?key=private-query"]); request.httpMethod = "POST"
        _ = try await transport.send(request)
        let records = await transport.records
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        for value in ["private-key", "private-prose", "private-as-key", "private-query", "private-header", "private-body", "secret", "example.test"] {
            XCTAssertFalse(encoded.contains(value), value)
        }
        XCTAssertEqual(records.first?.endpoint, "content")
        XCTAssertEqual(records.first?.httpStatus, 200)
        XCTAssertTrue(records.first!.shape.contains("content:string"))
    }
}
