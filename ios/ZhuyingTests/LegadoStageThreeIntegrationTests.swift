import XCTest
@testable import Zhuying

private final class StageThreeVault: LegadoSecretVault {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ data: Data, id: String) throws { lock.lock(); values[id] = data; lock.unlock() }
    func remove(id: String) throws { lock.lock(); values[id] = nil; lock.unlock() }
}

private actor StageThreeTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(3))
        let url = try XCTUnwrap(request.url), parts = url.path.split(separator: "/")
        let object: [String: Any]
        let status: Int
        switch parts.first {
        case "many": object = ["books": (0..<240).map { ["name": "原创第\($0)部", "url": "/book/\($0)"] }]; status = 200
        case "search": object = ["books": [["name": "竹林来信", "url": "/book/A"], ["name": "山谷回声", "url": "/book/B"]]]; status = 200
        case "book": object = ["name": "原创作品" + String(parts.last!), "intro": "独立原创介绍", "toc": "/toc/" + String(parts.last!)]; status = 200
        case "toc": object = ["chapters": (1...3).map { ["name": "第\($0)章", "url": "/chapter/\(parts.last!)/\($0)"] }]; status = 200
        case "chapter": object = ["text": "竹影原创正文 \(parts.dropFirst().joined(separator: "-"))。\n下一段独立原创文字。"]; status = 200
        case "locked": object = ["error": "private-fixture-value-never-exported"]; status = 401
        default: throw ContentFailure.invalidResponse
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

final class LegadoStageThreeIntegrationTests: XCTestCase {
    private func source(id: String = "stage-three", search: String = "/search", content: String = "$.text") throws -> DemoSource {
        let configuration: [String: Any] = [
            "bookSourceName": "竹影原创阶段三回归", "bookSourceUrl": "https://stage3.fixture/", "searchUrl": search,
            "jsLib": "function title(input){if(globalThis.detailTag!=='prepared')throw new Error('Operation lease lost');return JSON.parse(input).name;}",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"],
            "ruleBookInfo": ["init": "@js:globalThis.detailTag='prepared'; result", "name": "@js:title(result)", "tocUrl": "$.toc",
                             "intro": "@js:if(book.readConfig==null){book.setUseReplaceRule(false);} if(book.readConfig.useReplaceRule!==book.getUseReplaceRule())throw new Error('Book config did not refresh');JSON.parse(result).intro"],
            "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"],
            "ruleContent": ["content": content]
        ]
        var source = DemoSource(id: id, name: "竹影原创阶段三回归", detail: "原创 fixture", url: "https://stage3.fixture/")
        source.configuration = try JSONSerialization.data(withJSONObject: configuration, options: .sortedKeys)
        return source
    }

    func testLegitimateLargeSearchCanEvaluateAnOriginalURLScriptForEveryResult() async throws {
        var configured = try source(search: "/many")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(configured.configuration)) as? [String: Any])
        raw["ruleSearch"] = ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "@js:result.url"]
        configured.configuration = try JSONSerialization.data(withJSONObject: raw)
        let adapter = try LegadoBookSource(source: configured, transport: StageThreeTransport())
        let page = try await adapter.search(query: "原创", page: 1)
        XCTAssertEqual(page.books.count, 240)
        XCTAssertEqual(Set(page.books.map(\.id)).count, 240)
    }

    func testUncaughtJavaScriptFailureRecordsOnlySchemaFieldAndSafeKind() async throws {
        var configured = try source()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(configured.configuration)) as? [String: Any])
        var info = try XCTUnwrap(raw["ruleBookInfo"] as? [String: String])
        info["intro"] = "@js:throw new TypeError('private-fixture-token is not a function')"
        raw["ruleBookInfo"] = info; configured.configuration = try JSONSerialization.data(withJSONObject: raw)
        let recorder = SourceDiagnosticHTTPTransport(base: StageThreeTransport())
        let adapter = SourceDiagnosticBookSource(base: try LegadoBookSource(source: configured, transport: recorder), recorder: recorder)
        let page = try await adapter.search(query: "原创", page: 1)
        do { _ = try await adapter.details(for: XCTUnwrap(page.books.first)); XCTFail("Failure must retain its schema location") }
        catch {
            XCTAssertEqual((error as? LegadoRuleExecutionError)?.field, .bookInfoIntro)
            XCTAssertEqual(SourceDiagnosticIssue.classify(error).code, .unsupportedHost)
        }
        let tags = await recorder.failureSnapshot()
        XCTAssertEqual(tags, ["operation": "details", "category": "javascript", "field": "ruleBookInfo.intro", "jsKind": "TypeError", "reason": "notFunction"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tags), as: UTF8.self).contains("private-fixture-token"))
    }

    func testBookReplacementHostRoundTripSurvivesAdapterRestartAndKeepsSourceRulesRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = try source(), vault = StageThreeVault()
        let state = try LegadoPersistentState(sourceID: configured.id, directory: root, vault: vault)
        let adapter = try LegadoBookSource(source: configured, transport: StageThreeTransport(), state: state)
        let page = try await adapter.search(query: "原创", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(page.books.first))
        XCTAssertEqual(book.source?.useReplaceRule, false)
        XCTAssertEqual(book.summary, "独立原创介绍")
        let catalog = try await adapter.chapters(for: book)
        let document = try await adapter.document(for: XCTUnwrap(catalog.first), book: book)
        XCTAssertEqual(document.paragraphs.first?.text, "竹影原创正文 A-1。")
        let restoredState = try LegadoPersistentState(sourceID: configured.id, directory: root, vault: vault)
        let restored = try LegadoBookSource(source: configured, transport: StageThreeTransport(), state: restoredState)
        let detail = try await restored.details(for: book)
        XCTAssertEqual(detail.id, book.id); XCTAssertEqual(detail.source?.useReplaceRule, false)
    }

    func testUncaughtSynchronousHostAuthenticationFailureRetainsNativeRecoveryAndExpiresState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = try source(content: "@js:java.ajax('https://stage3.fixture/locked')")
        let state = try LegadoPersistentState(sourceID: configured.id, directory: root, vault: StageThreeVault())
        try state.setLoginInfo(["账号": "original-reader"])
        let adapter = try LegadoBookSource(source: configured, transport: StageThreeTransport(), state: state)
        let page = try await adapter.search(query: "原创", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(page.books.first))
        let chapters = try await adapter.chapters(for: book)
        do { _ = try await adapter.document(for: XCTUnwrap(chapters.first), book: book); XCTFail("401 must not become chapter text") }
        catch {
            XCTAssertEqual(error as? ContentFailure, .authenticationRequired)
            let issue = SourceDiagnosticIssue.classify(error, authStatus: state.authStatus)
            XCTAssertEqual(issue.code, .loginExpired)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(issue), as: UTF8.self).contains("private-fixture-value"))
        }
        XCTAssertEqual(state.authStatus, .expired)
    }

    func testDynamicallyUnknownHostInsideQuickJSRetainsHostPolicyClassification() async throws {
        let configured = try source(search: "@js:java.ajax('https://'+'blocked.fixture/private')")
        let adapter = try LegadoBookSource(source: configured, transport: StageThreeTransport())
        do { _ = try await adapter.search(query: "原创", page: 1); XCTFail("An undeclared host must be rejected") }
        catch { XCTAssertEqual(SourceDiagnosticIssue.classify(error).code, .hostNotAllowed) }
    }

    func testManyRealSourcePipelinesRespectAggregateBudgetAndPinGlobalsBetweenRules() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: 32 * 1024 * 1024)
        let adapters = try (0..<16).map { try LegadoBookSource(source: source(id: "stage-three-\($0)"), transport: StageThreeTransport(), scriptBudget: budget) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for adapter in adapters {
                group.addTask {
                    let page = try await adapter.search(query: "原创", page: 1)
                    let book = try await adapter.details(for: XCTUnwrap(page.books.first))
                    XCTAssertEqual(book.title, "原创作品A")
                    let chapters = try await adapter.chapters(for: book)
                    let body = try await adapter.document(for: XCTUnwrap(chapters.first), book: book)
                    XCTAssertEqual(body.paragraphs.first?.text, "竹影原创正文 A-1。")
                }
            }
            try await group.waitForAll()
        }
        let evidence = budget.snapshot
        XCTAssertLessThanOrEqual(evidence.peakReservedBytes, budget.limitBytes)
        XCTAssertLessThanOrEqual(evidence.reservedSessionCount, 2)
        XCTAssertEqual(evidence.activeSessionCount, 0)
        XCTAssertGreaterThan(evidence.evictedSessionCount, 0)
    }

    func testDiagnosticRecorderCountsOnlyItsOwnHTTPResponsesWithoutRetainingCredentials() async throws {
        let recorder = SourceDiagnosticHTTPTransport(base: StageThreeTransport())
        var request = URLRequest(url: URL(string: "https://stage3.fixture/search?private=fixture-query")!)
        request.setValue("Bearer private-fixture-token", forHTTPHeaderField: "Authorization")
        _ = try await recorder.send(request)
        request.url = URL(string: "https://stage3.fixture/locked")!
        _ = try await recorder.send(request)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.successfulFetches, 1); XCTAssertEqual(snapshot.failedFetches, 1); XCTAssertGreaterThan(snapshot.bytes, 0)
        let report = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(report.contains("private")); XCTAssertFalse(report.contains("fixture-query")); XCTAssertFalse(report.contains("Bearer"))
        await recorder.recordFailure(LegadoRequestError.invalid("private-fixture-token"), operation: "search")
        let failure = await recorder.failureSnapshot()
        XCTAssertEqual(failure, ["operation": "search", "category": "requestInvalid"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains("private-fixture-token"))
        XCTAssertEqual(SourceDiagnosticIssue.classify(LegadoRequestError.limit).code, .resourceLimit)
        XCTAssertEqual(SourceDiagnosticIssue.classify(LegadoCompatibilityError.limit).code, .resourceLimit)
    }
}
