import XCTest
import PDFKit
import UIKit
@testable import Zhuying

final class ArchiveAndMediaTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data { try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)) }
    func testOriginalZIPRARAndLZMASevenZipDecodeAndUnsafePathsAreRejected() throws {
        let expected = "第一章 来信\n归档中的原创正文。\n第二章 星光\n读者看见星光。\n"
        for name in ["original-stored.rar","original-lzma.7z"] {
            let items = try BoundedArchive.read(fixture(name)); XCTAssertEqual(items.count,1)
            XCTAssertEqual(String(data:items[0].data,encoding:.utf8),expected)
        }
        let mixed = try BoundedArchive.read(fixture("mixed-books.zip")); XCTAssertEqual(mixed.count,3)
        let txt = try XCTUnwrap(mixed.first{$0.format == "txt"})
        XCTAssertEqual(try BookImporter.prepare(data:txt.data,name:txt.path).book.chapters.count,2)
        XCTAssertThrowsError(try BoundedArchive.read(fixture("unsafe-archive.zip")))
        XCTAssertThrowsError(try BoundedArchive.read(Data("not an archive".utf8)))
        var broken = try fixture("original-lzma.7z"); broken[broken.count - 1] ^= 0xff
        XCTAssertThrowsError(try BoundedArchive.read(broken))
    }
    func testComicNaturalOrderUniqueResourcesAndCancellationAreReal() async throws {
        let bytes = try fixture("original-comic.cbz"),members = try BoundedArchive.read(bytes)
        XCTAssertEqual(members.map(\.path),["pages/2.png","pages/10.png"])
        let prepared = try MediaBookImporter.comic(members,name:"原创漫画.cbz")
        XCTAssertEqual(prepared.book.media?.kind,.comic); XCTAssertEqual(prepared.resources.count,2)
        XCTAssertEqual(prepared.book.media?.resources.map(\.digest),members.map{FileResourceStore.digest($0.data)})
        let semaphore = DispatchSemaphore(value:0)
        let cancelled = Task.detached { semaphore.wait(); return try BoundedArchive.read(bytes) }; cancelled.cancel(); semaphore.signal()
        do { _ = try await cancelled.value; XCTFail("Cancellation") } catch is CancellationError {}
    }
    func testUpstreamCompressedRAR5AndEncryptedRARHaveSeparateDeclaredOutcomes() throws {
        let members = try BoundedArchive.read(fixture("upstream-rar5-compressed.rar"))
        XCTAssertEqual(members.count,1); XCTAssertEqual(members.first?.path,"test.bin"); XCTAssertEqual(members.first?.data.count,1200)
        XCTAssertThrowsError(try BoundedArchive.read(fixture("upstream-encrypted.rar")))
    }
    func testRAR4AndRAR5VolumesAreRejectedBeforeDecompression() throws {
        var rar4 = try fixture("original-stored.rar"); rar4[10] |= 1
        do { _ = try BoundedArchive.read(rar4); XCTFail("Split RAR4") } catch { XCTAssertTrue(error.localizedDescription.contains("分卷")) }
        // Original minimal RAR5 main header: size=3, type=main, flags=0, archive volume=1.
        let rar5 = Data([0x52,0x61,0x72,0x21,0x1a,0x07,0x01,0,0,0,0,0,3,1,0,1])
        do { _ = try BoundedArchive.read(rar5); XCTFail("Split RAR5") } catch { XCTAssertTrue(error.localizedDescription.contains("分卷")) }
    }
    @MainActor func testOriginalPDFAndComicResourcesSurviveDatabaseBackupAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let renderer = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:320,height:480))
        let bytes = renderer.pdfData { context in
            for index in 0..<3 { context.beginPage(); ("Original PDF page \(index + 1)" as NSString).draw(at:CGPoint(x:25,y:50),withAttributes:[.font:UIFont.systemFont(ofSize:18)]) }
        }
        let pdf = try MediaBookImporter.originalPDF(bytes,name:"原版式.pdf")
        XCTAssertEqual(pdf.book.media?.pageCount,3)
        let workspace = LibraryWorkspace(root:root.appendingPathComponent("library"),legacyFonts:root.appendingPathComponent("fonts"))
        let backend = try ProductionLibraryPersistence(directory:workspace.root); _ = try await backend.bootstrap(legacySnapshot:nil,archiveURL:nil)
        let imported = try await backend.importBook(pdf.book,group:"PDF",resources:pdf.resources); XCTAssertTrue(imported)
        let comic = try MediaBookImporter.comic(BoundedArchive.read(fixture("original-comic.cbz")),name:"漫画.cbz")
        _ = try await backend.importBook(comic.book,group:"漫画",resources:comic.resources)
        let backup = try await backend.backup(fontDirectory:root.appendingPathComponent("fonts")); try backup.validate()
        XCTAssertEqual(backup.resources.filter{$0.path.hasPrefix("media/")}.count,3)
        let broken = LibraryBackup(createdAt:backup.createdAt,database:backup.database,documents:backup.documents,resources:Array(backup.resources.dropFirst()))
        XCTAssertThrowsError(try broken.validate())
        try await workspace.restore(backup)
        let reopened = try ProductionLibraryPersistence(directory:workspace.databaseDirectory()),state = try await reopened.bootstrap(legacySnapshot:nil,archiveURL:nil)
        XCTAssertEqual(state.books.first{$0.id == pdf.book.id}?.media?.kind,.pdf)
        let original = try await reopened.mediaURL(try XCTUnwrap(pdf.book.media?.resources.first))
        XCTAssertEqual(try Data(contentsOf:original),bytes)
        XCTAssertEqual(PDFDocument(url:original)?.pageCount,3)
        do { _ = try await reopened.exportText(bookID:pdf.book.id); XCTFail("Page metadata is not prose") } catch {}
    }
    @MainActor func testMediaLocationsBookmarksAndImageCacheKeepTheirOwnBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!
        defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:domain) }
        func library() throws -> LibraryStore { LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root)) }
        let store = try library(); await store.bootstrapProductionIfNeeded()
        let prepared = try MediaBookImporter.comic(BoundedArchive.read(fixture("original-comic.cbz")),name:"漫画.cbz")
        _ = try await store.importBookDurably(prepared.book,resources:prepared.resources)
        store.recordMedia(prepared.book,location:.init(page:1,x:0.4,y:0.7,zoom:2)); store.saveMediaBookmark(prepared.book)
        _ = await store.flushPendingWrites()
        let reopened = try library(); await reopened.bootstrapProductionIfNeeded()
        XCTAssertEqual(reopened.mediaLocations[prepared.book.id]?.page,1); XCTAssertEqual(reopened.mediaBookmarks.count,1)
        XCTAssertEqual(reopened.progress[prepared.book.id]?.chapter,1)
        let search = try await reopened.searchText("页面索引"); XCTAssertTrue(search.hits.isEmpty)
        XCTAssertThrowsError(try reopened.audio.start(bookID:prepared.book.id,mode:.system))
        let imageURL = try await reopened.mediaURL(prepared.book.media!.resources[0])
        let cache = MediaImageCache(),ref = prepared.book.media!.resources[0]
        cache.save(UIImage(data:prepared.resources[ref]!)!,reference:ref); XCTAssertNotNil(cache.image(ref)); cache.clear(); XCTAssertNil(cache.image(ref))
        try await reopened.permanentlyDeleteBook(id:prepared.book.id); _ = await reopened.flushPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath:imageURL.path))
        let deleted = try library(); await deleted.bootstrapProductionIfNeeded(); XCTAssertTrue(deleted.mediaBookmarks.isEmpty); XCTAssertTrue(deleted.mediaLocations.isEmpty)
    }
    @MainActor func testExtensionCacheCleanupUsesActualBytesAndPreservesRulesAndOriginalMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let scripts = ScriptCache(directory:root.appendingPathComponent("scripts")),comments = SourceCommentCache(directory:root.appendingPathComponent("comments")),images = MediaImageCache(),scope = StableContentID.make("original-cache-test")
        try await scripts.put(scope:scope,key:"k",value:"v"); try await comments.write([SourceParagraphCount(nativeID:"0",count:2,hot:true)],key:scope)
        let scriptBytes = try await scripts.usage(),commentBytes = try await comments.usage(); XCTAssertGreaterThan(scriptBytes,0); XCTAssertGreaterThan(commentBytes,0)
        let processor = ContentProcessingStore(directory:root.appendingPathComponent("rules")); try await processor.save([.init(name:"规则",pattern:"广告")])
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:700,height:700),format:format).image { context in UIColor.green.setFill(); context.fill(CGRect(x:0,y:0,width:700,height:700)) }
        let refs = (0..<10).map{ResourceFileReference(digest:StableContentID.make("image",String($0)),bytes:1,kind:.image)}
        for ref in refs { images.save(image,reference:ref) }
        XCTAssertLessThanOrEqual(images.bytes,16 * 1024 * 1024); XCTAssertNil(images.image(refs[0])); XCTAssertNotNil(images.image(refs[9]))
        let original = root.appendingPathComponent("original.png"); try image.pngData()!.write(to:original)
        try await ExtensionCacheMaintenance.clear(comments:comments,scripts:scripts,images:images)
        let remainingScripts = try await scripts.usage(),remainingComments = try await comments.usage(); XCTAssertEqual(remainingScripts,0); XCTAssertEqual(remainingComments,0); XCTAssertEqual(images.bytes,0)
        let rules = try await processor.rules(); XCTAssertEqual(rules.count,1); XCTAssertTrue(FileManager.default.fileExists(atPath:original.path))
    }

}
