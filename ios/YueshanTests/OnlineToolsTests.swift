import XCTest
import GRDB
@testable import Yueshan

private struct DownloadObjectFailure: AtomicFileWriting {
    func write(_ data: Data,to url: URL) throws {
        if url.lastPathComponent.count == 69 { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to:url,options:.atomic)
    }
}
final class OnlineToolsTests: XCTestCase {
    private func book(_ id: String = "book") -> LibraryBookRecord {
        .init(id:id,title:"原创下载作品",author:"阅山测试",summary:"",source:.init(sourceID:"source-" + id,nativeBookID:id,provider:"来源",bookURL:"https://source.test"),addedAt:Date())
    }
    private func catalog(_ book: LibraryBookRecord,count: Int = 3) -> [ChapterRecord] {
        (0..<count).map { .init(id:book.id + "-\($0)",bookID:book.id,nativeChapterID:String($0),title:"第\($0 + 1)章 来信",order:$0,access:.readable) }
    }
    private func wait(_ store: OfflineDownloadStore,until predicate: ([OfflineDownloadTask]) -> Bool) async throws {
        for _ in 0..<300 { if predicate(await store.list()) { return }; try await Task.sleep(for:.milliseconds(5)) }
        XCTFail("Download queue did not reach the expected state")
    }
    func testPinnedDownloadsSurviveRestartAndDeletionReclaimsActualBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try OfflineDownloadStore(directory:root), book = book(), chapters = catalog(book)
        await store.configure { _,chapter in .init(chapterID:chapter.id,paragraphs:["原创持久化正文 \(chapter.title)"]) }
        await store.connectivity(connected:true,wifi:true)
        let id = try await store.enqueue(book:book,chapters:chapters,wifiOnly:true)
        try await wait(store) { $0.first?.status == .completed }
        let reopened = try OfflineDownloadStore(directory:root)
        let document = try await reopened.document(book:book,chapter:chapters[1]); XCTAssertNotNil(document)
        let before = try await reopened.usage(); XCTAssertGreaterThan(before,0)
        try await reopened.remove(id)
        let after = try await reopened.usage(); XCTAssertEqual(after,0)
        let removed = try await reopened.document(book:book,chapter:chapters[1]); XCTAssertNil(removed)
    }
    func testInterruptedTaskResumesOnlyMissingChaptersAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try OfflineDownloadStore(directory:root), book = book(), chapters = catalog(book,count:5)
        await store.configure { _,chapter in
            if chapter.order > 0 { try await Task.sleep(for:.seconds(2)) }
            return .init(chapterID:chapter.id,paragraphs:["已下载正文 \(chapter.order)"])
        }
        await store.connectivity(connected:true,wifi:true)
        let id = try await store.enqueue(book:book,chapters:chapters,wifiOnly:true)
        try await wait(store) { $0.first?.completed.count == 1 }
        await store.pauseForBackground()
        let reopened = try OfflineDownloadStore(directory:root)
        let state = await reopened.list(); XCTAssertEqual(state[0].status,.paused); XCTAssertEqual(state[0].completed.count,1)
        await reopened.configure { _,chapter in
            XCTAssertNotEqual(chapter.order,0,"A committed chapter must not be downloaded again")
            return .init(chapterID:chapter.id,paragraphs:["续传正文 \(chapter.order)"])
        }
        await reopened.connectivity(connected:true,wifi:true); try await reopened.resume(id)
        try await wait(reopened) { $0.first?.status == .completed }
    }
    func testWiFiAndForegroundPoliciesPreventUnattendedDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try OfflineDownloadStore(directory:root), book = book(), chapters = catalog(book,count:1)
        await store.configure { _,chapter in .init(chapterID:chapter.id,paragraphs:["Wi-Fi 正文"]) }
        await store.connectivity(connected:true,wifi:false)
        _ = try await store.enqueue(book:book,chapters:chapters,wifiOnly:true)
        let waiting = await store.list(); XCTAssertEqual(waiting[0].status,.queued)
        await store.pauseForBackground(); await store.connectivity(connected:true,wifi:true)
        let background = await store.list(); XCTAssertEqual(background[0].status,.queued)
        await store.returnToForeground(); try await wait(store) { $0.first?.status == .completed }
    }
    func testQuotaAndFileCommitFailuresNeverClaimCompletedChapters() async throws {
        for failure in [false,true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
            let store = try OfflineDownloadStore(directory:root,quota:failure ? 100000 : 1,writer:failure ? DownloadObjectFailure() : AtomicFileWriter())
            let book = book(), chapters = catalog(book,count:1)
            await store.configure { _,chapter in .init(chapterID:chapter.id,paragraphs:["不能误报成功的正文"]) }
            await store.connectivity(connected:true,wifi:true)
            _ = try await store.enqueue(book:book,chapters:chapters,wifiOnly:true)
            try await wait(store) { $0.first?.status == .failed }
            let result = await store.list(); XCTAssertTrue(result[0].completed.isEmpty)
            XCTAssertTrue(result[0].message?.contains("空间") == true)
        }
    }
    func testChapterMappingRequiresUniqueTitleOrderAndContextOrExplicitChapterStart() throws {
        let book = book(), chapters = catalog(book)
        XCTAssertNil(SourceChapterMapping.suggestion(title:"第一章 来信",order:0,catalog:chapters),"Repeated titles require selection")
        var unique = chapters; unique[1].title = "第二章 回声"
        XCTAssertEqual(SourceChapterMapping.suggestion(title:"第2章 回声",order:1,catalog:unique),1)
        XCTAssertNil(SourceChapterMapping.suggestion(title:"第2章 回声",order:100,catalog:unique))
        let old = ChapterDocument(chapterID:"old",paragraphs:["保留旧来源的唯一文字上下文。"])
        let anchor = try ReadingAnchor(bookID:"old-book",document:old,paragraph:0,offset:5)
        let next = ChapterDocument(chapterID:"new",paragraphs:["新段落",old.paragraphs[0].text])
        let mapped = try SourceChapterMapping.anchor(from:anchor,bookID:"new-book",document:next,allowChapterStart:false)
        XCTAssertEqual(mapped.paragraphIndex,1); XCTAssertEqual(mapped.utf16Offset,5)
        let split = ChapterDocument(chapterID:"new",paragraphs:["内容已经重新拆分，无法确认。"])
        XCTAssertThrowsError(try SourceChapterMapping.anchor(from:anchor,bookID:"new-book",document:split,allowChapterStart:false))
        XCTAssertEqual(try SourceChapterMapping.anchor(from:anchor,bookID:"new-book",document:split,allowChapterStart:true).utf16Offset,0)
    }
    func testSourceSwitchLateSQLFailureRollsBackShelfAndPreservesOriginalLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("test.sqlite"), repository = try SQLiteLibraryRepository(url:url)
        let old = book("old"), oldCatalog = catalog(old,count:1), new = book("new"), newCatalog = catalog(new,count:1)
        try await repository.save(book:old,chapters:oldCatalog); try await repository.setFavorite(bookID:old.id,enabled:true)
        let oldDocument = ChapterDocument(chapterID:oldCatalog[0].id,paragraphs:["旧来源正文保持不变。"])
        let oldAnchor = try ReadingAnchor(bookID:old.id,document:oldDocument,paragraph:0,offset:2)
        try await repository.save(progress:oldAnchor)
        let newDocument = ChapterDocument(chapterID:newCatalog[0].id,paragraphs:["新来源已成功返回的正文。"])
        let newAnchor = try ReadingAnchor(bookID:new.id,document:newDocument,paragraph:0,offset:0)
        let injection = try DatabaseQueue(path:url.path)
        try await injection.write { try $0.execute(sql:"CREATE TRIGGER reject_switch BEFORE INSERT ON reading_progress WHEN NEW.bookID='new' BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        do { try await repository.commitSourceSwitch(from:old.id,book:new,chapters:newCatalog,anchor:newAnchor); XCTFail("Late failure") } catch {}
        let favorites = try await repository.favoriteIDs(), progress = try await repository.progress(bookID:old.id), books = try await repository.books()
        XCTAssertEqual(favorites,[old.id]); XCTAssertEqual(progress,oldAnchor); XCTAssertEqual(books.map(\.id),[old.id])
        try await injection.write { try $0.execute(sql:"DROP TRIGGER reject_switch") }
        try await repository.commitSourceSwitch(from:old.id,book:new,chapters:newCatalog,anchor:newAnchor)
        let switched = try await repository.favoriteIDs(), retained = try await repository.progress(bookID:old.id)
        XCTAssertEqual(switched,[new.id]); XCTAssertEqual(retained,oldAnchor)
    }
}
