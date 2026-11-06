import Foundation
import Combine

/// Rebuildable account- and body-version-scoped data, excluded from backups.
actor SourceCommentCache {
    static let shared = SourceCommentCache(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("SourceComments-v1"))
    private struct Entry<Value: Codable>: Codable { let date: Date; let value: Value }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static func key(client: ShushanCommentsClient,context: ShushanCommentContext,version: String,paragraph: String = "",cursor: String = "") -> String {
        StableContentID.make("comments-v1",client.cacheScope,context.source,context.bookID,context.chapterID,version,paragraph,cursor)
    }
    func read<T: Codable>(_ type: T.Type,key: String,maximumAge: TimeInterval,now: Date = Date()) -> T? {
        guard valid(key),let url = try? path(key),let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf:url),let entry = try? JSONDecoder().decode(Entry<T>.self,from:data),now.timeIntervalSince(entry.date) >= -300,now.timeIntervalSince(entry.date) <= maximumAge else { return nil }
        return entry.value
    }
    func write<T: Codable>(_ value: T,key: String,now: Date = Date()) throws {
        let url = try path(key),data = try JSONEncoder().encode(Entry(date:now,value:value)); guard data.count <= 2 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey,.isSymbolicLinkKey]).filter{ $0.pathExtension == "json" }
        let sorted = files.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var bytes = 0
        for (index,file) in sorted.enumerated() {
            let values = try file.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]); bytes += values.fileSize ?? 0
            if index >= 128 || bytes > 16 * 1024 * 1024 || values.isSymbolicLink == true { try FileManager.default.removeItem(at:file) }
        }
    }
    func clear() throws {
        do { try FileManager.default.removeItem(at:directory) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) { }
    }
    private func valid(_ key: String) -> Bool { key.count == 64 && key.allSatisfy{"0123456789abcdef".contains($0)} }
    private func path(_ key: String) throws -> URL {
        guard valid(key) else { throw ContentFailure.invalidResponse }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath(),url = root.appendingPathComponent(key + ".json").resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path else { throw ContentFailure.storageFailure }; return url
    }
}

@MainActor final class ReaderCommentsModel: ObservableObject {
    @Published private(set) var counts: [String:SourceParagraphCount] = [:]
    @Published private(set) var stale = false
    private(set) var originalTexts: [String:String] = [:]
    private var generation = UUID()
    func reset() { generation = UUID(); counts = [:]; originalTexts = [:]; stale = false }
    func remap(_ origins: [String:String]) {
        let original = counts,text = originalTexts
        counts = Dictionary(uniqueKeysWithValues:origins.compactMap{ id,raw in original[raw].map{(id,$0)} })
        originalTexts = Dictionary(uniqueKeysWithValues:origins.compactMap{ id,raw in text[raw].map{(id,$0)} })
    }
    func load(client: ShushanCommentsClient,context: ShushanCommentContext,document: ChapterDocument,cache: SourceCommentCache = .shared) async {
        reset(); let ticket = generation,key = SourceCommentCache.key(client:client,context:context,version:document.version)
        do {
            let rows: [SourceParagraphCount]
            if let recent = await cache.read([SourceParagraphCount].self,key:key,maximumAge:300) { rows = recent }
            else { rows = try await client.counts(context); try? await cache.write(rows,key:key) }
            try Task.checkCancellation(); guard ticket == generation else { return }
            counts = ShushanCommentsClient.map(rows,context:context,document:document)
            originalTexts = Dictionary(uniqueKeysWithValues:document.paragraphs.map{($0.id,$0.text)})
        } catch {
            guard !Task.isCancelled,ticket == generation,let saved = await cache.read([SourceParagraphCount].self,key:key,maximumAge:7 * 86400),!Task.isCancelled,ticket == generation else { return }
            counts = ShushanCommentsClient.map(saved,context:context,document:document); stale = true
            originalTexts = Dictionary(uniqueKeysWithValues:document.paragraphs.map{($0.id,$0.text)})
        }
    }
}
