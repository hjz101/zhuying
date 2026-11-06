import XCTest
@testable import Zhuying

private struct AuthenticationFailureSource: BookSource {
    let sourceID: String
    func search(query: String, page: Int) async throws -> BookSearchPage { throw ContentFailure.authenticationRequired }
    func details(for book: LibraryBookRecord) async throws -> LibraryBookRecord { throw ContentFailure.authenticationRequired }
    func chapters(for book: LibraryBookRecord) async throws -> [ChapterRecord] { throw ContentFailure.authenticationRequired }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) async throws -> ChapterDocument { throw ContentFailure.authenticationRequired }
}

@MainActor final class SourceAuthenticationRecoveryTests: XCTestCase {
    func testCompletedLoginActionRequestsProviderRecoveryWithoutClaimingAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let persistence = try ProductionLibraryPersistence(directory: root)
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false, productionPersistence: persistence)
        await library.bootstrapProductionIfNeeded()
        let id = "login-recovery-" + UUID().uuidString
        var source = DemoSource(id: id, name: "竹影原创登录恢复", detail: "原创 fixture", url: "https://recovery.fixture/")
        source.configuration = try JSONSerialization.data(withJSONObject: [
            "bookSourceUrl": source.url, "searchUrl": "/search", "loginUrl": "function login(){java.toast('原创操作已完成');}",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"],
            "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"],
            "ruleContent": ["content": "$.text"]
        ])
        library.updateSources([source])
        let notification = expectation(forNotification: .legadoLoginActionCompleted, object: nil) { note in
            note.userInfo?["sourceID"] as? String == id
        }
        let result = try await library.runLegadoLoginAction(sourceID: id, action: "login()", values: ["账号": "original-reader"])
        await fulfillment(of: [notification], timeout: 2)
        XCTAssertEqual(result.message, "原创操作已完成")
        XCTAssertEqual(try library.legadoLoginState(for: source).authStatus, .unverified)
        let saved = await library.flushPendingWrites(); XCTAssertTrue(saved)
    }

    func testSourceSpecificLoginRecoveryDoesNotExpireAnotherAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = OnlineReadingService(cache: try RecentChapterCache(directory: root))
        var notified = 0
        await service.setAuthenticationHandler(sourceID: "shushan") { @MainActor in notified += 1 }
        await service.configure(source: AuthenticationFailureSource(sourceID: "original-legado"))
        do { _ = try await service.search(query: "原创", page: 1); XCTFail("Expired source should request login") }
        catch { XCTAssertEqual(error as? ContentFailure, .authenticationRequired) }
        XCTAssertEqual(notified, 0)
        await service.configure(source: AuthenticationFailureSource(sourceID: "shushan"))
        do { _ = try await service.search(query: "原创", page: 1); XCTFail("Expired source should request login") }
        catch { XCTAssertEqual(error as? ContentFailure, .authenticationRequired) }
        XCTAssertEqual(notified, 1)
    }
}
