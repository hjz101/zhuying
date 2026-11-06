import XCTest
@testable import Zhuying

@MainActor final class LegadoIntegrationTests: XCTestCase {
    func testImportedRuleAndScriptSourcesRunAllFourStepsThroughExistingServiceAndPersist() async throws {
        for scripted in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingLegado-" + UUID().uuidString)
            let domain = "com.zhuying.legado-integration." + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: domain) }
            let workspace = LibraryWorkspace(root: directory, legacyFonts: directory.appendingPathComponent("legacy-fonts"))
            let service = OnlineReadingService(cache: try RecentChapterCache(directory: directory.appendingPathComponent("cache")))
            let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                productionFactory: { try ProductionLibraryPersistence(directory: workspace.databaseDirectory()) }, onlineService: service, workspace: workspace)
            await library.bootstrapProductionIfNeeded()
            let source = try XCTUnwrap(SourcePackages.parse(LegadoDevelopmentFixtures.package(scripted: scripted), existing: []).sources.first)
            XCTAssertTrue(SourcePackages.isRunnable(source)); XCTAssertTrue(source.detail.contains("阅读 3.0"))
            XCTAssertTrue(SourcePackages.accountTitle(source, isDemo: false).contains("阅读 3.0"))
            let provider = try LegadoBookSource(source: source, transport: LegadoDevelopmentTransport())
            await service.configure(sources: [provider])
            let page = try await service.search(query: "山间来信", page: 1)
            let record = try XCTUnwrap(page.books.first)
            let (details, catalog) = try await service.details(record)
            XCTAssertEqual(details.title, "山间来信"); XCTAssertEqual(catalog.count, 2)
            let book = try await library.registerRemoteBook(details, chapters: catalog)
            library.read(book)
            XCTAssertEqual(library.reader?.book.id, book.id)
            let document = try await service.document(book: details, chapter: catalog[0])
            XCTAssertTrue(document.paragraphs.map(\.text).joined().contains(scripted ? "同步脚本" : "阅读规则"))
            XCTAssertTrue(document.paragraphs.map(\.text).joined().contains("第1章"))
            let second = try await service.document(book: details, chapter: catalog[1])
            XCTAssertTrue(second.paragraphs.map(\.text).joined().contains("第2章"))
            XCTAssertFalse(second.paragraphs.map(\.text).joined().contains("第1章"))
            XCTAssertNotEqual(document.version, second.version)
            XCTAssertEqual(document.chapterID, catalog[0].id)
            _ = library.confirmChapter(book, chapter: 0, document: document, anchor: .init())
            let flushed = await library.flushPendingWrites(); XCTAssertTrue(flushed)
            let stored = try ProductionLibraryPersistence(directory: workspace.databaseDirectory())
            let restored = try await stored.bootstrap(legacySnapshot: nil, archiveURL: nil)
            XCTAssertTrue(restored.books.contains(where: { $0.id == book.id }))
        }
    }

    func testImportPreservesRequestMetadataAndStillRemovesCredentialFields() throws {
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: LegadoDevelopmentFixtures.package(scripted: false)) as? [String: Any])
        row["header"] = "{\"User-Agent\":\"ZhuyingCompat\",\"Authorization\":\"secret-to-remove\"}"
        row["headers"] = ["Accept": "text/html", "Cookie": "session=secret-to-remove"]
        let source = try XCTUnwrap(SourcePackages.parse(JSONSerialization.data(withJSONObject: row), existing: []).sources.first)
        let definition = try SourcePackages.legadoDefinition(source)
        XCTAssertTrue(definition.header.contains("ZhuyingCompat"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.configuration)) as? [String: Any])
        XCTAssertEqual((saved["headers"] as? [String: String])?["Accept"], "text/html")
        let exported = String(decoding: try SourcePackages.export([source]), as: UTF8.self)
        XCTAssertFalse(exported.contains("secret-to-remove"))
    }

    func testOtherMediaRulesAreRetainedWithoutAdvertisingNovelCompatibility() throws {
        for type in [1, 2] {
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: LegadoDevelopmentFixtures.package(scripted: false)) as? [String: Any])
            row["bookSourceType"] = type
            let source = try XCTUnwrap(SourcePackages.parse(JSONSerialization.data(withJSONObject: row), existing: []).sources.first)
            XCTAssertFalse(SourcePackages.isRunnable(source))
            XCTAssertThrowsError(try SourcePackages.legadoDefinition(source))
            XCTAssertFalse(SourcePackages.executionDetail(source).contains("基础兼容"))
            XCTAssertTrue(String(decoding: try SourcePackages.export([source]), as: UTF8.self).contains("ruleContent"))
        }
    }
}
