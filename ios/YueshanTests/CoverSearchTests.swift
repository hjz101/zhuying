import XCTest
import UIKit
@testable import Yueshan

private actor CoverTransportProbe: HTTPTransport {
    let payload: Data
    var requests: [URLRequest] = []
    init(_ payload: Data) { self.payload = payload }
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        return (payload,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
final class CoverSearchTests: XCTestCase {
    func testSearchUsesUserQueryAndOnlyValidatedCoverResults() async throws {
        let transport = CoverTransportProbe(try JSONSerialization.data(withJSONObject:["docs":[["key":"/works/OL1W","title":"原创","author_name":["作者"],"cover_i":123],["key":"/works/OL2W","title":"重复图片","cover_i":123],["key":"/works/OL3W","title":"无封面"],["key":"/works/OL4W","title":"无效图片","cover_i":-1]]]))
        let results = try await CoverSearchClient(transport:transport).search(" 山 & 海 ")
        XCTAssertEqual(results.count,1); XCTAssertEqual(results[0].author,"作者"); XCTAssertEqual(results[0].imageURL.host,"covers.openlibrary.org")
        let request = await transport.requests.first!
        XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "title"})?.value,"山 & 海")
        XCTAssertNil(request.value(forHTTPHeaderField:"Authorization")); XCTAssertNil(request.value(forHTTPHeaderField:"X-Api-Key"))
    }
    @MainActor func testSelectedCoverSurvivesRestartBackupRenameAndFailedReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!
        defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:domain) }
        let png = UIGraphicsImageRenderer(size:CGSize(width:100,height:150)).pngData { context in UIColor.systemGreen.setFill(); context.fill(CGRect(x:0,y:0,width:100,height:150)) }
        let normalized = try CoverSearchClient.normalized(png)
        func store() throws -> LibraryStore { LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root)) }
        let library = try store(); await library.bootstrapProductionIfNeeded()
        let prepared = try BookImporter.prepare(data:Data("第一章\n原创正文。".utf8),name:"原创.txt")
        _ = try await library.importBookDurably(prepared.book)
        try await library.saveCover(bookID:prepared.book.id,data:normalized)
        let ref = try XCTUnwrap(library.books.first?.cover)
        do { try await library.saveCover(bookID:prepared.book.id,data:Data("invalid".utf8)); XCTFail("Invalid cover") } catch {}
        XCTAssertEqual(library.books.first?.cover,ref)
        try await library.renameLocalBook(id:prepared.book.id,title:"新书名"); XCTAssertEqual(library.books.first?.cover,ref)
        _ = await library.flushPendingWrites()
        let reopened = try store(); await reopened.bootstrapProductionIfNeeded(); XCTAssertEqual(reopened.books.first?.cover,ref)
        let url = try await reopened.mediaURL(ref); XCTAssertEqual(try Data(contentsOf:url),normalized)
        let backend = try ProductionLibraryPersistence(directory:root),backup = try await backend.backup(fontDirectory:root.appendingPathComponent("fonts"))
        try backup.validate(); XCTAssertTrue(backup.resources.contains{$0.path == "media/" + ref.filename})
        try await reopened.saveCover(bookID:prepared.book.id,data:nil); XCTAssertNil(reopened.books.first?.cover)
    }
    @MainActor func testCoverStagingRollsBackWhenBookDoesNotExistAndRejectsNonImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = UIGraphicsImageRenderer(size:CGSize(width:10,height:20)).pngData{ _ in UIColor.systemBlue.setFill(); UIRectFill(CGRect(x:0,y:0,width:10,height:20)) }
        let backend = try ProductionLibraryPersistence(directory:root)
        _ = try await backend.bootstrap(legacySnapshot:nil,archiveURL:nil)
        do { _ = try await backend.saveCover(bookID:"missing",data:bytes); XCTFail("Missing book") } catch ContentFailure.missingChapter {}
        let files = (try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("resources/media"),includingPropertiesForKeys:nil)) ?? []
        XCTAssertTrue(files.isEmpty); XCTAssertThrowsError(try CoverSearchClient.normalized(Data("<svg/>".utf8)))
    }
    func testProductionCoverSummaryNamesVerifiedProviderWhileDemoCopyIsPreserved() {
        let feature = FeatureCatalog.feature("covers")
        XCTAssertTrue(feature.summary.contains("Bing")); XCTAssertTrue(ProductionCapabilities.summary(for:feature).contains("Open Library")); XCTAssertFalse(ProductionCapabilities.summary(for:feature).contains("Bing"))
        XCTAssertEqual(ProductionCapabilities.summary(for:FeatureCatalog.feature("fonts")),FeatureCatalog.feature("fonts").summary)
    }

}
