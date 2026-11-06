import XCTest
import UIKit
@testable import Zhuying

private struct SourceCoverFixture: HTTPTransport {
    let data: Data
    var status = 200
    var destination = "https://art.fixture/cover.png"
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: URL(string: destination)!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}
final class SourceBookCoverTests: XCTestCase {
    @MainActor func testRemoteCoverIsValidatedAndRedirectsCannotCrossOrigins() async throws {
        let png = UIGraphicsImageRenderer(size: .init(width: 10, height: 15)).pngData { context in
            UIColor.systemGreen.setFill(); context.fill(.init(x: 0, y: 0, width: 10, height: 15))
        }
        let request = URLRequest(url: URL(string: "https://art.fixture/cover.png")!)
        let loaded = try await SourceCoverLoader.load(request, transport: SourceCoverFixture(data: png))
        XCTAssertNotNil(UIImage(data: loaded))
        for fixture in [SourceCoverFixture(data: png, status: 404), SourceCoverFixture(data: png, destination: "https://other.fixture/cover.png"), SourceCoverFixture(data: Data("not an image".utf8))] {
            do { _ = try await SourceCoverLoader.load(request, transport: fixture); XCTFail("Invalid artwork must use the native fallback") } catch { }
        }
    }
    @MainActor func testPublicArtworkNeverInheritsCredentialsAndHTTPNeedsConfiguredSource() throws {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false)
        var book = LibraryBookRecord(id: "cover-fixture", title: "竹影原创", author: "作者", summary: "简介", coverURL: "https://art.fixture/cover.png", source: nil, addedAt: Date())
        let (request, _) = try library.sourceCoverRequest(book)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        book.source = .init(sourceID: "removed-source", nativeBookID: "one", provider: "已移除", bookURL: "https://art.fixture/book")
        XCTAssertThrowsError(try library.sourceCoverRequest(book))
        book.source = nil
        book.coverURL = "http://art.fixture/cover.png"
        XCTAssertThrowsError(try library.sourceCoverRequest(book))
        book.coverURL = "https://reader:secret@art.fixture/cover.png"
        XCTAssertThrowsError(try library.sourceCoverRequest(book))
    }
}
