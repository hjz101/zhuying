import XCTest
@testable import Yueshan

private actor CloudTransportProbe: CloudDocumentTransport {
    var identity = String(repeating:"a",count:64)
    var contents: [String:Data] = [:]
    var reads = 0
    var changesOnRead = false
    func changeOnRead() { changesOnRead = true }
    func account() -> String { identity }
    private func check(_ account: String) throws { if account != identity { throw CloudAccessError.accountChanged } }
    func files(folder: String,account: String) throws -> [CloudFile] {
        try check(account)
        return contents.filter { $0.key.hasPrefix(folder + "/") }.map { .init(id:String($0.key.dropFirst(folder.count + 1)),bytes:$0.value.count,modified:Date(timeIntervalSince1970:100),downloaded:true) }
    }
    func read(folder: String,id: String,maximumBytes: Int,account: String) throws -> Data {
        try check(account); reads += 1
        guard let data = contents[folder + "/" + id],data.count <= maximumBytes else { throw CloudAccessError.invalidData }
        if changesOnRead { identity = String(repeating:"b",count:64) }; return data
    }
    func write(_ data: Data,folder: String,id: String,account: String) throws { try check(account); contents[folder + "/" + id] = data }
    func remove(folder: String,id: String,account: String) throws { try check(account); contents.removeValue(forKey:folder + "/" + id) }
}
final class CloudRecordTests: XCTestCase {
    func testConcurrentDeleteWinsInEitherMergeOrderAndOldOfflineEditsCannotResurrect() throws {
        var base = RecordSyncState(); try base.edit(kind:.bookmark,id:"bookmark",payload:Data("first".utf8),device:"A")
        var a = base,b = base
        try a.edit(kind:.bookmark,id:"bookmark",payload:nil,device:"A")
        try b.edit(kind:.bookmark,id:"bookmark",payload:Data("offline edit".utf8),device:"B")
        let deletion = a.entries["bookmark:bookmark"]!,edit = b.entries["bookmark:bookmark"]!
        try a.merge(edit); try b.merge(deletion)
        XCTAssertTrue(a.entries[deletion.key]!.deleted); XCTAssertEqual(a.entries,b.entries)
        try a.merge(base.entries[deletion.key]!); XCTAssertTrue(a.entries[deletion.key]!.deleted)
        try a.edit(kind:.bookmark,id:"bookmark",payload:Data("explicit new bookmark".utf8),device:"A")
        XCTAssertFalse(a.entries[deletion.key]!.deleted)
    }
    func testCurrentReadBackIsIndependentOfFarthestAndWallClockSkew() throws {
        let doc = ChapterDocument(chapterID:"chapter",paragraphs:["原始正文。"])
        let late = SyncedPosition(anchor:try .init(bookID:"b",document:doc,paragraph:0,offset:2,now:.distantPast),chapterOrder:20)
        let early = SyncedPosition(anchor:try .init(bookID:"b",document:doc,paragraph:0,offset:0,now:.distantFuture),chapterOrder:1)
        var state = RecordSyncState()
        for kind: SyncEntry.Kind in [.current,.farthest] { try state.edit(kind:kind,id:"b",payload:JSONEncoder().encode(late),device:"A") }
        var other = state
        for kind: SyncEntry.Kind in [.current,.farthest] { try other.edit(kind:kind,id:"b",payload:JSONEncoder().encode(early),device:"B"); try state.merge(other.entries[kind.rawValue + ":b"]!) }
        XCTAssertEqual(try JSONDecoder().decode(SyncedPosition.self,from:state.entries["current:b"]!.payload!).chapterOrder,1)
        XCTAssertEqual(try JSONDecoder().decode(SyncedPosition.self,from:state.entries["farthest:b"]!.payload!).chapterOrder,20)
    }
    func testTwoDeviceJournalRestartIncrementalPullAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let transport = CloudTransportProbe(),account = await transport.account()
        let a = CloudRecordStore(directory:root.appendingPathComponent("a"),device:"A",transport:transport),b = CloudRecordStore(directory:root.appendingPathComponent("b"),device:"B",transport:transport)
        let desired: [SyncEntry.Kind:[String:Data]] = [.bookmark:["bookmark":Data("original".utf8)]]
        _ = try await a.synchronize(desired,account:account)
        let pulled = try await b.synchronize([.bookmark:[:]],account:account); XCTAssertEqual(pulled.entries["bookmark:bookmark"]?.payload,Data("original".utf8))
        _ = try await a.synchronize([.bookmark:[:]],account:account)
        let restarted = CloudRecordStore(directory:root.appendingPathComponent("b"),device:"B",transport:transport)
        let deleted = try await restarted.synchronize(desired,account:account); XCTAssertTrue(deleted.entries["bookmark:bookmark"]!.deleted)
        _ = try await restarted.synchronize([.bookmark:[:]],account:account)
        let before = await transport.reads
        _ = try await restarted.synchronize([.bookmark:[:]],account:account)
        let after = await transport.reads; XCTAssertEqual(before,after)
    }
    func testBackupChecksDigestAndAccountBeforeReturningDataAndUnsignedBuildFailsClearly() async throws {
        let transport = CloudTransportProbe(),store = CloudBackupStore(transport:transport),account = await transport.account()
        let backup = LibraryBackup(createdAt:Date(),database:.init(books:[],chapters:[],progress:[],bookmarks:[],favorites:[],groups:[:],preferences:[ProductionLibraryPersistence.migrationKey:Data("1".utf8)]),documents:[],resources:[])
        let id = try await store.save(backup,account:account),restored = try await store.restore(id,account:account)
        XCTAssertEqual(restored.createdAt,backup.createdAt)
        await transport.changeOnRead()
        do { _ = try await store.restore(id,account:account); XCTFail("Changed account") } catch CloudAccessError.accountChanged {}
        do { _ = try await UbiquitousDocuments(enabled:false).account(); XCTFail("No entitlement") } catch CloudAccessError.notConfigured {}
    }
    func testFailedApplyCannotReusePublishedClockForAnotherPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let transport = CloudTransportProbe(),account = await transport.account()
        let a = CloudRecordStore(directory:root.appendingPathComponent("a"),device:"A",transport:transport)
        do { _ = try await a.synchronize([.bookmark:["m":Data("before failure".utf8)]],account:account) { _ in throw ContentFailure.storageFailure }; XCTFail("Apply fails") } catch ContentFailure.storageFailure {}
        let restarted = CloudRecordStore(directory:root.appendingPathComponent("a"),device:"A",transport:transport)
        _ = try await restarted.synchronize([.bookmark:["m":Data("new local edit".utf8)]],account:account)
        let b = CloudRecordStore(directory:root.appendingPathComponent("b"),device:"B",transport:transport)
        let state = try await b.synchronize([.bookmark:[:]],account:account)
        XCTAssertEqual(state.entries["bookmark:m"]?.payload,Data("new local edit".utf8)); XCTAssertGreaterThan(state.entries["bookmark:m"]?.counter ?? 0,1)
    }
    func testConcurrentConflictRetainsChoicesAndExplicitResolutionIsCausal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let transport = CloudTransportProbe(),account = await transport.account()
        let a = CloudRecordStore(directory:root.appendingPathComponent("a"),device:"A",transport:transport),b = CloudRecordStore(directory:root.appendingPathComponent("b"),device:"B",transport:transport)
        _ = try await a.synchronize([.settings:["reader":Data("A".utf8)]],account:account)
        let conflicted = try await b.synchronize([.settings:["reader":Data("B".utf8)]],account:account)
        XCTAssertEqual(conflicted.alternatives?["settings:reader"]?.count,2)
        let choice = try XCTUnwrap(conflicted.alternatives?["settings:reader"]?.first(where:{$0.device == "A"}))
        let resolved = try await b.synchronize([.settings:["reader":conflicted.entries["settings:reader"]!.payload!]],account:account,resolutions:["settings:reader":choice])
        XCTAssertEqual(resolved.entries["settings:reader"]?.payload,Data("A".utf8)); XCTAssertTrue(resolved.conflicts.isEmpty)
        let pulled = try await a.synchronize([.settings:["reader":Data("A".utf8)]],account:account)
        XCTAssertEqual(pulled.entries["settings:reader"]?.payload,Data("A".utf8)); XCTAssertTrue(pulled.conflicts.isEmpty)
    }
    func testRecordsApplyToRealDatabaseWithSeparateBodyRecoveryAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let transport = CloudTransportProbe(),account = await transport.account()
        let a = try ProductionLibraryPersistence(directory:root.appendingPathComponent("dbA")),b = try ProductionLibraryPersistence(directory:root.appendingPathComponent("dbB"))
        _ = try await a.bootstrap(legacySnapshot:nil,archiveURL:nil); _ = try await b.bootstrap(legacySnapshot:nil,archiveURL:nil)
        let book = try BookImporter.prepare(data:Data("第一章\n原创正文。\n第二章\n山谷中的星光。".utf8),name:"原创.txt").book
        _ = try await a.importBook(book,group:"原创分组")
        var settings = ReadingSettings(); settings.fontSize = 25
        try await a.saveState(.init(favorites:[book.id],progress:[book.id:.init(chapter:1,paragraph:0,updatedAt:Date())],settings:settings,importedGroups:[book.id:"原创分组"]))
        let ar = CloudRecordStore(directory:root.appendingPathComponent("syncA"),device:"A",transport:transport),br = CloudRecordStore(directory:root.appendingPathComponent("syncB"),device:"B",transport:transport)
        _ = try await ar.synchronize(a.recordSyncDesired(),account:account)
        _ = try await br.synchronize(b.recordSyncDesired(),account:account) { state in try await b.applyRecordSync(state) }
        let state = try await b.bootstrap(legacySnapshot:nil,archiveURL:nil)
        XCTAssertEqual(state.books.map(\.id),[book.id]); XCTAssertEqual(state.snapshot.favorites,[book.id]); XCTAssertEqual(state.snapshot.importedGroups?[book.id],"原创分组"); XCTAssertEqual(state.snapshot.settings.fontSize,25); XCTAssertEqual(state.snapshot.progress[book.id]?.chapter,1)
        let chapter = try XCTUnwrap(state.catalogs[book.id]?.first)
        do { _ = try await b.document(chapterID:chapter.id); XCTFail("Metadata sync must not synthesize prose") } catch {}
        _ = try await b.deleteBook(id:book.id)
        _ = try await br.synchronize(b.recordSyncDesired(),account:account)
        _ = try await ar.synchronize(a.recordSyncDesired(),account:account) { state in try await a.applyRecordSync(state) }
        let deleted = try await a.bootstrap(legacySnapshot:nil,archiveURL:nil); XCTAssertTrue(deleted.books.isEmpty)
    }
    func testPristineDeviceDoesNotPublishDefaultPreferencesButExplicitResetDoes() throws {
        var original = LibraryDatabaseArchive(books:[],chapters:[],progress:[],bookmarks:[],favorites:[],groups:[:],preferences:[:])
        let initial = LibraryViewPreferences(.init(favorites:[],progress:[:]))
        original.preferences[ProductionLibraryPersistence.viewKey] = try JSONEncoder().encode(initial)
        XCTAssertNil(try LibraryRecordSync.desired(original)[.settings])
        let edited = LibraryViewPreferences(.init(favorites:[],progress:[:],userSettingsEdited:true))
        original.preferences[ProductionLibraryPersistence.viewKey] = try JSONEncoder().encode(edited)
        XCTAssertNotNil(try LibraryRecordSync.desired(original)[.settings]?["reader"])
    }
    func testDatabaseSyncFailureRollsBackDeletedAndReplacedRecords() async throws {
        let repository = try SQLiteLibraryRepository()
        let original = LibraryBookRecord(id:"original",title:"保留作品",author:"原创",summary:"",addedAt:Date())
        let chapter = ChapterRecord(id:"original-chapter",bookID:original.id,nativeChapterID:"one",title:"第一章",order:0,access:.readable)
        try await repository.save(book:original,chapters:[chapter])
        let invalid = LibraryDatabaseArchive(books:[],chapters:[chapter],progress:[],bookmarks:[],favorites:[],groups:[:],preferences:[:])
        do { try await repository.applyRecordSync(invalid); XCTFail("Foreign key failure") } catch {}
        let remaining = try await repository.books(); XCTAssertEqual(remaining,[original])
        let chapters = try await repository.chapters(bookID:original.id); XCTAssertEqual(chapters,[chapter])
    }
    func testInitialCatalogLargerThanOneJournalRoundTripsAndDamagedCheckpointIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let transport = CloudTransportProbe(),account = await transport.account()
        let a = CloudRecordStore(directory:root.appendingPathComponent("a"),device:"A",transport:transport),b = CloudRecordStore(directory:root.appendingPathComponent("b"),device:"B",transport:transport)
        let desired = Dictionary(uniqueKeysWithValues:(0..<5001).map{("chapter-\($0)",Data("original-\($0)".utf8))})
        _ = try await a.synchronize([.chapter:desired],account:account)
        let copied = try await b.synchronize([.chapter:[:]],account:account); XCTAssertEqual(copied.entries.count,5001)
        XCTAssertEqual(copied.entries["chapter:chapter-5000"]?.payload,desired["chapter-5000"])
        var damaged = copied; damaged.vector = .init(); XCTAssertThrowsError(try damaged.validate())
    }
    @MainActor func testReadingBackBeforeNextSyncKeepsDurableFarthestAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!
        defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:domain) }
        let backend = try ProductionLibraryPersistence(directory:root),store = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:backend)
        await store.bootstrapProductionIfNeeded()
        let book = try BookImporter.prepare(data:Data("第一章\n原始的来信正文。\n第二章\n山谷中的远方星光。".utf8),name:"原创.txt").book
        _ = try await store.importBookDurably(book)
        for index in [1,0] {
            let request = try store.chapterRequest(for:book,chapter:index),value = try await backend.document(chapterID:request.chapter.id),document = try XCTUnwrap(value)
            XCTAssertTrue(store.confirmChapter(book,chapter:index,document:document,anchor:.init(paragraph:0,offset:2)))
        }
        let saved = await store.flushPendingWrites(); XCTAssertTrue(saved)
        let values = try await backend.recordSyncDesired()
        let current = try JSONDecoder().decode(SyncedPosition.self,from:values[.current]![book.id]!),farthest = try JSONDecoder().decode(SyncedPosition.self,from:values[.farthest]![book.id]!)
        XCTAssertEqual(current.chapterOrder,0); XCTAssertEqual(farthest.chapterOrder,1)
        let reopened = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root)); await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.progress[book.id]?.chapter,0)
    }
}
