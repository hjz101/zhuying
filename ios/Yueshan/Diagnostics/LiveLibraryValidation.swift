#if DEBUG
import Foundation

/// Exercises the production store in a dedicated validation library; never
/// changes the reader's normal library, credentials or account settings.
@MainActor enum LiveLibraryValidation {
    private struct Work: Codable { let bookID: String; let chapters: [String]; let versions: [String]; let target: Int; let anchor: ReadingAnchor }
    static func run(credential: ShushanCredential?,restart: Bool) async throws {
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("DevelopmentValidation/LiveLibrary")
        let manifest = root.appendingPathComponent("expected.json"),report = root.deletingLastPathComponent().appendingPathComponent("live-library.json")
        let defaults = UserDefaults(suiteName:"com.yueshan.validation.live-library")!
        if !restart { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:"com.yueshan.validation.live-library") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var samples: [[String:Any]] = [],stage = "open"
        do {
            let service = OnlineReadingService(cache:try RecentChapterCache(directory:root.appendingPathComponent("RecentChapters")))
            let store = LibraryStore(books:[],defaults:defaults,seedDemoData:false,productionPersistence:try ProductionLibraryPersistence(directory:root.appendingPathComponent("Database")),onlineService:service)
            await store.bootstrapProductionIfNeeded(); guard store.loadState == .ready else { throw ContentFailure.storageFailure }
            if restart {
                let expected = try JSONDecoder().decode([Work].self,from:Data(contentsOf:manifest))
                for work in expected {
                    stage = "restart-check"
                    guard let book = store.books.first(where:{$0.id == work.bookID}),store.isFavorite(book),store.settings.fontSize == 23,store.bookmarks.contains(where:{$0.anchor.bookID == book.id && $0.anchor.chapterID == work.anchor.chapterID}),let saved = try store.chapterRequest(for:book,chapter:work.target,resume:true).anchor,saved.chapterID == work.anchor.chapterID,saved.paragraphID == work.anchor.paragraphID,saved.utf16Offset == work.anchor.utf16Offset else { throw ContentFailure.invalidResponse }
                    let repository = store.chapterRepository(for:book)
                    for (index,id) in work.chapters.enumerated() { guard let document = try await repository.document(chapterID:id),document.version == work.versions[index] else { throw ContentFailure.invalidResponse } }
                    samples.append(["book":StableContentID.make(book.id),"restartAccepted":true,"cachedChapters":work.chapters.count,"favorite":true,"bookmark":true,"sameParagraphAndUTF16Offset":true])
                }
                guard expected.count == 2 else { throw ContentFailure.invalidResponse }
            } else {
                guard let credential else { throw ContentFailure.authenticationRequired }
                let source = ShushanBookSource(credential:credential,transport:ResilientSourceTransport(base:SourceValidationTransport(minimumInterval:0.4)))
                await service.configure(source:source)
                var expected: [Work] = []
                for query in ["西游记","红楼梦"] {
                    stage = "search-" + query
                    let page = try await service.search(query:query,page:1)
                    guard let candidate = page.books.first(where:{$0.title == query && $0.source?.provider == "番茄小说"}) else { throw ContentFailure.missingChapter }
                    stage = "details-catalog-" + query
                    let (metadata,catalog) = try await service.details(candidate)
                    guard let start = catalog.firstIndex(where:{$0.title.range(of:"^第.{1,12}[回章]",options:.regularExpression) != nil}),start + 2 < catalog.count else { throw ContentFailure.invalidResponse }
                    let selected = Array(catalog[start...(start + 2)]); guard selected.allSatisfy({$0.access == .readable}) else { throw ContentFailure.restricted }
                    let book = try await store.registerRemoteBook(metadata,chapters:catalog)
                    var versions: [String] = [],last: ChapterDocument?
                    for chapter in selected {
                        stage = "read-" + query
                        guard let document = try await store.chapterRepository(for:book).document(chapterID:chapter.id),document.paragraphs.reduce(0,{$0 + $1.text.utf16.count}) >= 300,store.confirmChapter(book,chapter:chapter.order,document:document,anchor:.init(paragraph:1,offset:2)) else { throw ContentFailure.invalidResponse }
                        versions.append(document.version); last = document; await service.cancelPrefetch()
                    }
                    guard let last else { throw ContentFailure.missingChapter }
                    _ = store.toggleFavorite(book); store.settings.fontSize = 23
                    _ = try await store.saveBookmark(book,chapter:start + 2,paragraph:1,offset:2,title:"真实来源验收")
                    guard await store.flushPendingWrites(),let anchor = try store.chapterRequest(for:book,chapter:start + 2,resume:true).anchor else { throw ContentFailure.storageFailure }
                    expected.append(.init(bookID:book.id,chapters:selected.map(\.id),versions:versions,target:start + 2,anchor:anchor))
                    samples.append(["book":StableContentID.make(book.id),"title":query,"provider":"番茄小说","catalogItems":catalog.count,"consecutiveNarrativeChapters":selected.count,"titles":selected.map(\.title),"durableAnchor":anchor.contentVersion == last.version])
                }
                try JSONEncoder().encode(expected).write(to:manifest,options:.atomic)
            }
            try write(["schemaVersion":1,"status":"passed","phase":restart ? "restart" : "prepare","samples":samples,"normalUserLibraryMutated":false,"rawTextInReport":false],to:report)
        } catch { try write(["schemaVersion":1,"status":"failed","phase":restart ? "restart" : "prepare","stage":stage,"samples":samples,"errorDomain":(error as NSError).domain,"errorCode":(error as NSError).code,"normalUserLibraryMutated":false],to:report) }
    }
    private static func write(_ object: [String:Any],to url: URL) throws { try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) }
}
#endif
