import XCTest
@testable import Zhuying

final class SourceReplacementPolicyTests: XCTestCase {
    private struct RawRepository: ChapterDocumentLoading {
        let value: ChapterDocument
        func document(chapterID: String) async throws -> ChapterDocument? { chapterID == value.chapterID ? value : nil }
    }

    func testLegacyMetadataDefaultsToUnspecifiedAndBookPreferencePersistsWithoutChangingIdentity() throws {
        var reference = SourceBookReference(sourceID:"s",nativeBookID:"book",provider:"来源",bookURL:"https://example.test/book",origin:"https://example.test")
        let identity = reference.id
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(reference)) as? [String:Any])
        legacy.removeValue(forKey:"useReplaceRule")
        let old = try JSONDecoder().decode(SourceBookReference.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(old.useReplaceRule)
        reference.useReplaceRule = false
        XCTAssertEqual(reference.id,identity)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("metadata.json")
        let book = LibraryBookRecord(id:identity,title:"书籍",author:"作者",summary:"简介",source:reference,addedAt:Date(timeIntervalSince1970:0))
        try JSONEncoder().encode(book).write(to:file,options:.atomic)
        let restored = try JSONDecoder().decode(LibraryBookRecord.self,from:Data(contentsOf:file))
        XCTAssertEqual(restored.source?.useReplaceRule,false)
        XCTAssertEqual(restored.id,identity)
        XCTAssertEqual(restored.source?.id,identity)
    }

    func testDisabledPurificationKeepsSourceExtractionAndBypassesPreviouslyProcessedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ContentProcessingStore(directory:root)
        let sourceText = try LegadoRuleEngine().text("tag.p@text##源端##已提取",in:"<p>源端正文。</p>")
        let raw = ChapterDocument(chapterID:"chapter",paragraphs:[sourceText])
        let rules = [ContentProcessingRule(name:"用户净化",pattern:"已提取",replacement:"已净化",enabled:true)]
        try await store.save(rules)
        let enabled = ProcessedChapterRepository(base:RawRepository(value:raw),processor:store,bookID:"book",sourceID:"source")
        let processed = try await enabled.document(chapterID:raw.chapterID)
        XCTAssertEqual(processed?.paragraphs.first?.text,"已净化正文。")
        let disabled = ProcessedChapterRepository(base:RawRepository(value:raw),processor:store,bookID:"book",sourceID:"source",useReplaceRule:false)
        let unprocessed = try await disabled.document(chapterID:raw.chapterID)
        XCTAssertEqual(unprocessed,raw)
        let result = try await store.process(raw,bookID:"book",sourceID:"source",useReplaceRule:false)
        XCTAssertEqual(result.origins,Dictionary(uniqueKeysWithValues:raw.paragraphs.map{($0.id,$0.id)}))
        XCTAssertEqual(result.document.originVersion,nil)
        let persisted = try await store.rules()
        XCTAssertEqual(persisted,rules)
        let reenabled = try await enabled.document(chapterID:raw.chapterID)
        XCTAssertEqual(reenabled,processed)
    }

    func testDisabledPurificationDoesNotLoadOrRewriteInvalidManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("rules.json"),invalid = Data("not a rule package".utf8)
        try invalid.write(to:file)
        let store = ContentProcessingStore(directory:root),raw = ChapterDocument(chapterID:"chapter",paragraphs:["有效源正文。"])
        let result = try await store.process(raw,bookID:"book",sourceID:"source",useReplaceRule:false)
        XCTAssertEqual(result.document,raw)
        let message = await store.message
        XCTAssertNil(message)
        XCTAssertEqual(try Data(contentsOf:file),invalid)
        do { _ = try await store.rules(); XCTFail("The manifest must remain invalid rather than being silently replaced") } catch {}
    }
}
