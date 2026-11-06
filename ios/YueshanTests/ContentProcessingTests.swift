import XCTest
@testable import Yueshan

final class ContentProcessingTests: XCTestCase {
    func testOrderedScopedRulesKeepOriginalAndIdentityMapAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = ContentProcessingStore(directory:root),raw = ChapterDocument(chapterID:"c",paragraphs:["广告：仅测试","原始正文。","山海😀"])
        let rules: [ContentProcessingRule] = [.init(name:"广告",pattern:"^广告：.*$",enabled:true),.init(name:"书籍替换",pattern:"原始",replacement:"净化",enabled:true,scope:.book,bookID:"b"),.init(name:"来源替换",pattern:"净化",replacement:"来源",enabled:true,scope:.source,sourceID:"s")]
        try await store.save(rules)
        let result = try await store.process(raw,bookID:"b",sourceID:"s")
        XCTAssertEqual(result.document.paragraphs.map(\.text),["来源正文。","山海😀"]); XCTAssertEqual(raw.paragraphs.count,3); XCTAssertEqual(result.raw,raw)
        XCTAssertEqual(result.origins[result.document.paragraphs[0].id],raw.paragraphs[1].id); XCTAssertEqual(result.document.originVersion,raw.version)
        let other = try await store.process(raw,bookID:"another",sourceID:"s"); XCTAssertEqual(other.document.paragraphs.first?.text,"原始正文。")
        let restarted = ContentProcessingStore(directory:root),again = try await restarted.process(raw,bookID:"b",sourceID:"s")
        XCTAssertEqual(again.document,result.document); XCTAssertEqual(again.rulesVersion,result.rulesVersion)
        let file = try FileChapterRepository(directory:root.appendingPathComponent("raw")); try await file.save(raw)
        do { try await file.save(result.document); XCTFail("Processed content must not replace raw") } catch {}
        let saved = try await file.document(chapterID:raw.chapterID); XCTAssertEqual(saved,raw)
    }
    func testActualJavaScriptKeepsIDsAndFailureFallsBackToLastValidOrRaw() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = ContentProcessingStore(directory:root),raw = ChapterDocument(chapterID:"c",paragraphs:["原始正文。","保留段落。"])
        try await store.save([.init(name:"JS",kind:.javascript,pattern:"return input.map(p => ({id:p.id,text:p.text.replace('原始','处理')}));",enabled:true)])
        let valid = try await store.process(raw,bookID:"b",sourceID:nil); XCTAssertEqual(valid.document.paragraphs.first?.text,"处理正文。")
        try await store.save([.init(name:"错误",kind:.javascript,pattern:"return [{id:'forged',text:'invented'}];",enabled:true)])
        let failed = try await store.process(raw,bookID:"b",sourceID:nil); XCTAssertEqual(failed.document,valid.document)
        let uncached = ChapterDocument(chapterID:"another",paragraphs:["另一章原文。"]),fallback = try await store.process(uncached,bookID:"b",sourceID:nil)
        XCTAssertEqual(fallback.document,uncached)
        let message = await store.message; XCTAssertNotNil(message)
        try await store.save([]); let rebuilt = try await store.process(raw,bookID:"b",sourceID:nil); XCTAssertEqual(rebuilt.document,raw)
    }
    func testPackageVersionInvalidRegexEmptyOutputAndCancellationPreserveBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = ContentProcessingStore(directory:root),raw = ChapterDocument(chapterID:"c",paragraphs:["原文。"])
        XCTAssertThrowsError(try ContentProcessingStore.encode([.init(name:"错误正则",pattern:"(")]))
        let bytes = try ContentProcessingStore.encode([.init(name:"保留",pattern:"原文",replacement:"修改",enabled:true)])
        XCTAssertEqual(try ContentProcessingStore.decode(bytes).count,1)
        let version = String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:"\"version\" : 1",with:"\"version\" : 99")
        XCTAssertThrowsError(try ContentProcessingStore.decode(Data(version.utf8)))
        try await store.save([.init(name:"清空",pattern:".*",enabled:true)]); let empty = try await store.process(raw,bookID:"b",sourceID:nil); XCTAssertEqual(empty.document,raw)
        let task = Task { try Task.checkCancellation(); return try await store.process(raw,bookID:"b",sourceID:nil) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation") } catch is CancellationError {}
    }
    @MainActor func testReadingNarrationRepositorySearchAndRawExportShareCorrectVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!
        defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:domain) }
        let backend = try ProductionLibraryPersistence(directory:root),library = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:backend)
        await library.bootstrapProductionIfNeeded()
        let book = try BookImporter.prepare(data:Data("第一章\n广告：测试文本。\n原始正文中的山谷。".utf8),name:"原创.txt").book
        _ = try await library.importBookDurably(book)
        try await library.contentProcessor.save([.init(name:"去广告",pattern:"^广告.*$",enabled:true),.init(name:"正文",pattern:"原始",replacement:"处理",enabled:true)])
        let request = try library.chapterRequest(for:book,chapter:0),value = try await library.chapterRepository(for:book).document(chapterID:request.chapter.id),document = try XCTUnwrap(value)
        XCTAssertEqual(document.paragraphs.map(\.text),["处理正文中的山谷。"])
        let found = try await library.searchText("处理正文"); XCTAssertEqual(found.hits.count,1)
        let removed = try await library.searchText("广告"); XCTAssertTrue(removed.hits.isEmpty)
        let export = try await library.exportLocalText(id:book.id); XCTAssertTrue(String(decoding:export,as:UTF8.self).contains("原始正文")); XCTAssertTrue(String(decoding:export,as:UTF8.self).contains("广告"))
        let context = await library.contentProcessor.context(bookID:book.id,document:document); XCTAssertEqual(context?.raw.paragraphs.count,2)
        let location = try ReadingAnchor(bookID:book.id,document:document,paragraph:0,offset:2)
        XCTAssertEqual(ReadingAnchorResolver.resolve(location,in:document),.exact(paragraph:0,offset:2))
    }
    func testCompleteBackupRestoresRuleManifestWithRawBodyInNewGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let workspace = LibraryWorkspace(root:root,legacyFonts:root.appendingPathComponent("fonts")),database = try workspace.databaseDirectory(),backend = try ProductionLibraryPersistence(directory:database)
        _ = try await backend.bootstrap(legacySnapshot:nil,archiveURL:nil)
        let book = try BookImporter.prepare(data:Data("第一章\n保留原始的正文。".utf8),name:"原创.txt").book; _ = try await backend.importBook(book,group:"原始")
        let processor = ContentProcessingStore(directory:database.appendingPathComponent("resources/processing")),rules = [ContentProcessingRule(name:"替换",pattern:"原始",replacement:"处理",enabled:true)]
        try await processor.save(rules)
        let backup = try await backend.backup(fontDirectory:root.appendingPathComponent("fonts")); try backup.validate()
        XCTAssertTrue(backup.resources.contains{$0.path == "processing/rules.json"})
        try await workspace.restore(backup)
        let restored = try workspace.databaseDirectory(),reopened = try ProductionLibraryPersistence(directory:restored),state = try await reopened.bootstrap(legacySnapshot:nil,archiveURL:nil),chapter = try XCTUnwrap(state.catalogs[book.id]?.first)
        let value = try await reopened.document(chapterID:chapter.id),raw = try XCTUnwrap(value)
        XCTAssertEqual(raw.paragraphs.first?.text,"保留原始的正文。")
        let restoredProcessor = ContentProcessingStore(directory:restored.appendingPathComponent("resources/processing")),result = try await restoredProcessor.process(raw,bookID:book.id,sourceID:nil)
        XCTAssertEqual(result.document.paragraphs.first?.text,"保留处理的正文。")
    }
}
