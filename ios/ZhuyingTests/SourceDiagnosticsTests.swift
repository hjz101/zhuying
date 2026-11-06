import XCTest
@testable import Zhuying

private actor DiagnosticProbe: SourceDiagnosticEvidenceProvider {
    let sourceID = "diagnostic-secret-source?token=private"
    enum Mode { case normal, noSearch, noCatalog, noContent, cachedContent, failedCachedContent, changedContent, duplicateWork, authentication, cancelled }
    let mode: Mode
    private var evidence = SourceDiagnosticNetworkEvidence()
    private var searches = 0
    init(_ mode: Mode = .normal) { self.mode = mode }
    func searchCount() -> Int { searches }
    func diagnosticNetworkEvidence() -> SourceDiagnosticNetworkEvidence { evidence }
    private func fetched() { evidence.successfulFetches += 1; evidence.bytes += 64 }
    func search(query: String, page: Int) throws -> BookSearchPage {
        searches += 1; fetched()
        if mode == .authentication { throw ContentFailure.authenticationRequired }
        if mode == .cancelled { throw CancellationError() }
        return .init(books: mode == .noSearch ? [] : (0..<2).map { .init(id: "private-book-\($0)", title: mode == .duplicateWork ? ($0 == 0 ? "原创！" : " 原创 ") : "原创\($0)", author: "竹影", summary: "", coverURL: nil, source: nil, addedAt: Date(timeIntervalSince1970: 0)) }, nextPage: nil)
    }
    func details(for book: LibraryBookRecord) -> LibraryBookRecord { fetched(); return book }
    func chapters(for book: LibraryBookRecord) -> [ChapterRecord] {
        fetched()
        return mode == .noCatalog ? [] : (0..<3).map { .init(id: book.id + "-\($0)", bookID: book.id, nativeChapterID: String($0), title: "原创章节", order: $0, access: .readable) }
    }
    func document(for chapter: ChapterRecord, book: LibraryBookRecord) -> ChapterDocument {
        if mode == .failedCachedContent { evidence.failedFetches += 1 }
        else if mode != .cachedContent { fetched() }
        return .init(chapterID: chapter.id, paragraphs: mode == .noContent ? [" \n"] : [mode == .changedContent ? "变化后的原创正文" : "private-original-body：竹影原创正文"])
    }
}
private struct DiagnosticFailingWriter: AtomicFileWriting {
    func write(_ data: Data, to url: URL) throws { throw ContentFailure.storageFailure }
}

final class SourceDiagnosticsTests: XCTestCase {
    private let scope = SourceDiagnosticScope(sourceID: "diagnostic-secret-source?token=private", accountID: "private-account", libraryProfile: "private-library")
    private func run(_ probe: DiagnosticProbe, process: UUID = UUID(), baseline: SourceAcceptanceReport? = nil) async throws -> SourceAcceptanceReport {
        try await SourceAcceptanceRunner.run(source: probe, query: "private-query", scope: scope, evidenceKind: .controlledFixture, processID: process, baseline: baseline)
    }
    func testClassifiesSafeRecoveryWithoutCopyingRawExceptions() throws {
        XCTAssertEqual(SourceDiagnosticIssue.classify(ContentFailure.authenticationRequired).code, .loginRequired)
        XCTAssertEqual(SourceDiagnosticIssue.classify(ContentFailure.authenticationRequired, authStatus: .expired).code, .loginExpired)
        XCTAssertEqual(SourceDiagnosticIssue.classify(LegadoCompatibilityError.unsupported("尚未允许主机 https://secret.invalid/?token=private")).code, .hostNotAllowed)
        XCTAssertEqual(SourceDiagnosticIssue.classify(QuickJSScriptError.memoryBudgetTimedOut).code, .timedOut)
        XCTAssertEqual(SourceDiagnosticIssue.classify(QuickJSScriptError.memoryLimit).code, .resourceLimit)
        XCTAssertEqual(SourceDiagnosticIssue.classify(QuickJSScriptError.busy).code, .busy)
        let issue = SourceDiagnosticIssue.classify(LegadoRequestError.unsupported("脚本宿主方法 secret-script-password"))
        XCTAssertEqual(issue.code, .unsupportedHost)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(issue), as: UTF8.self).contains("secret"))
    }
    func testImportedIssueOriginsAreReducedToCredentialFreeHTTPSOrigins() throws {
        let data = Data(#"{"code":"hostNotAllowed","origin":"https://fixture.test/private?token=secret"}"#.utf8)
        let issue = try JSONDecoder().decode(SourceDiagnosticIssue.self, from: data)
        XCTAssertEqual(issue.origin, "https://fixture.test/")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(issue), as: UTF8.self).contains("secret"))
        XCTAssertNil(SourceDiagnosticIssue(code: .hostNotAllowed, origin: URL(string: "https://user:password@fixture.test")).origin)
    }
    func testEmptyStagesProduceActionableFailureAtTheCorrectStep() async throws {
        for (mode, expected, stage) in [(DiagnosticProbe.Mode.noSearch, SourceDiagnosticIssue.Code.noSearchResults, "搜索"), (.noCatalog, .emptyCatalog, "目录"), (.noContent, .emptyContent, "正文")] {
            let reports = try await SourceDiagnostics.run(source: DiagnosticProbe(mode), query: "private", through: .content)
            XCTAssertEqual(reports.last?.issue?.code, expected); XCTAssertEqual(reports.last?.step, stage)
            XCTAssertEqual(reports.last?.status, "失败")
        }
    }
    func testCancellationStillPropagatesAndAuthenticationKeepsRecovery() async throws {
        do { _ = try await SourceDiagnostics.run(source: DiagnosticProbe(.cancelled), query: "private", through: .content); XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let reports = try await SourceDiagnostics.run(source: DiagnosticProbe(.authentication), query: "private", through: .content, authStatus: .expired)
        XCTAssertEqual(reports.last?.issue?.code, .loginExpired)
        XCTAssertEqual(reports.last?.issue?.recoveries, [.login, .retry])
    }
    func testCompleteAcceptanceRequiresTwoBooksSixChaptersAndAnotherProcess() async throws {
        let firstProcess = UUID(), probe = DiagnosticProbe()
        let initial = try await run(probe, process: firstProcess)
        XCTAssertEqual(initial.status, .awaitingRestart); XCTAssertEqual(initial.books.count, 2)
        XCTAssertTrue(initial.books.allSatisfy { $0.chapters.count == 3 })
        XCTAssertEqual(initial.initialSteps.filter { $0.step == .content }.count, 6)
        XCTAssertTrue(initial.initialSteps.allSatisfy { ($0.network?.successfulFetches ?? 0) > 0 })
        let before = await probe.searchCount()
        do { _ = try await run(probe, process: firstProcess, baseline: initial); XCTFail("Same process is not restart proof") }
        catch { XCTAssertEqual(SourceDiagnosticIssue.classify(error).code, .incompleteAcceptance) }
        let after = await probe.searchCount(); XCTAssertEqual(before, after)
        let verified = try await run(DiagnosticProbe(), baseline: initial)
        XCTAssertEqual(verified.status, .restartVerified); XCTAssertNotEqual(verified.verificationProcessID, initial.initialProcessID)
        XCTAssertEqual(verified.verificationSteps.filter { $0.step == .content }.count, 6)
    }
    func testCachedOrFailedNetworkContentCannotPassDespiteSuccessfulCatalog() async throws {
        let cached = try await run(DiagnosticProbe(.cachedContent))
        XCTAssertEqual(cached.status, .failed); XCTAssertEqual(cached.issue?.code, .incompleteAcceptance)
        let failed = try await run(DiagnosticProbe(.failedCachedContent))
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.issue?.code, .unavailable)
    }
    func testChangedChapterCannotPassRestartVerification() async throws {
        let baseline = try await run(DiagnosticProbe())
        let changed = try await run(DiagnosticProbe(.changedContent), baseline: baseline)
        XCTAssertEqual(changed.status, .verificationFailed); XCTAssertEqual(changed.issue?.code, .incompleteAcceptance)
        XCTAssertNil(changed.verifiedAt)
    }
    func testDifferentProviderIdentitiesForSameWorkDoNotCountAsTwoBooks() async throws {
        let report = try await run(DiagnosticProbe(.duplicateWork))
        XCTAssertEqual(report.status, .failed); XCTAssertEqual(report.issue?.code, .incompleteAcceptance)
    }
    func testRestartBaselineRejectsChangedConfigurationOrLoginEpoch() async throws {
        let baseline = try await run(DiagnosticProbe())
        var changed = scope; changed.configurationHash = StableContentID.make("new-rules")
        for candidate in [changed, SourceDiagnosticScope(sourceID: scope.sourceID, accountID: scope.accountID, libraryProfile: scope.libraryProfile, sessionEpoch: 1)] {
            do { _ = try await SourceAcceptanceRunner.run(source: DiagnosticProbe(), query: "private", scope: candidate, evidenceKind: .controlledFixture, baseline: baseline); XCTFail("Changed session/rules must not verify an old baseline") }
            catch { XCTAssertEqual(SourceDiagnosticIssue.classify(error).code, .incompleteAcceptance) }
        }
    }
    func testCheckpointIsAccountAndProfileScopedAndFailedWriteKeepsOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await run(DiagnosticProbe()), store = SourceAcceptanceStore(directory: directory)
        try await store.save(initial, scope: scope)
        let loaded = try await store.load(scope: scope); XCTAssertEqual(loaded?.id, initial.id)
        let account = try await store.load(scope: .init(sourceID: scope.sourceID, accountID: "another", libraryProfile: scope.libraryProfile))
        let profile = try await store.load(scope: .init(sourceID: scope.sourceID, accountID: scope.accountID, libraryProfile: "another"))
        XCTAssertNil(account); XCTAssertNil(profile)
        let failing = SourceAcceptanceStore(directory: directory, writer: DiagnosticFailingWriter())
        do { try await failing.save(try await run(DiagnosticProbe()), scope: scope); XCTFail("Storage errors must propagate") } catch {}
        let preserved = try await store.load(scope: scope); XCTAssertEqual(preserved?.id, initial.id)
    }
    func testExportContainsOnlyFixedClassificationHashesAndRequestCounts() async throws {
        let report = try await run(DiagnosticProbe())
        let full = String(decoding: try SourceAcceptanceRunner.export(report), as: UTF8.self)
        for secret in ["private-query", "private-account", "private-library", "private-book", "private-original-body", "token=private"] { XCTAssertFalse(full.contains(secret)) }
        let basic = try await SourceDiagnostics.run(source: DiagnosticProbe(.authentication), query: "private-query", through: .content)
        let exported = String(decoding: try SourceDiagnostics.export(basic), as: UTF8.self)
        XCTAssertFalse(exported.contains("token=private")); XCTAssertTrue(exported.contains("loginRequired"))
    }
    func testCheckpointRejectsMissingRestartEvidenceNegativeCountsAndSymlinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceAcceptanceStore(directory: directory)
        var report = try await run(DiagnosticProbe())
        report.status = .restartVerified; report.verificationProcessID = UUID(); report.verifiedAt = Date()
        do { try await store.save(report, scope: scope); XCTFail("A status label is not restart evidence") } catch {}
        report.status = .awaitingRestart
        try await store.save(report, scope: scope)
        let url = directory.appendingPathComponent(scope.id + ".json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var steps = try XCTUnwrap(object["initialSteps"] as? [[String: Any]])
        steps[0]["count"] = -1; object["initialSteps"] = steps
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        do { _ = try await store.load(scope: scope); XCTFail("Negative counts must be rejected") } catch {}
        let target = directory.appendingPathComponent("outside.json")
        try Data().write(to: target); try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        do { _ = try await store.load(scope: scope); XCTFail("Symlink must be rejected before reading") } catch {}
    }
    func testOriginalFixtureRunsRealQuickJSNativeTransportAndSixChapters() async throws {
        let configuration = try SourceDiagnosticDevelopmentFixtures.package
        var source = DemoSource(id: "original-diagnostic-fixture", name: "原创诊断", detail: "", url: SourceDiagnosticDevelopmentFixtures.origin)
        source.configuration = configuration
        let recorder = SourceDiagnosticHTTPTransport(base: SourceDiagnosticDevelopmentFixtures.transport())
        let adapter = try LegadoBookSource(source: source, transport: recorder)
        let provider = SourceDiagnosticBookSource(base: adapter, recorder: recorder)
        let report = try await SourceAcceptanceRunner.run(source: provider, query: "原创", scope: .init(sourceID: source.id), evidenceKind: .controlledFixture)
        XCTAssertEqual(report.status, .awaitingRestart, report.issue?.message ?? "")
        XCTAssertEqual(report.books.flatMap(\.chapters).count, 6)
        XCTAssertTrue(report.initialSteps.filter { $0.step == .content }.allSatisfy { ($0.network?.successfulFetches ?? 0) > 0 })
        let login = try await SourceDiagnostics.run(source: provider, query: "登录", through: .content)
        XCTAssertEqual(login.last?.issue?.code, .loginRequired)
    }
}
