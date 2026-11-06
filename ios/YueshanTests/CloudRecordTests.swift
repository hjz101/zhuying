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
}
