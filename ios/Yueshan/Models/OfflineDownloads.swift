import Foundation
import Network

struct OfflineDownloadTask: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case queued, running, paused, failed, completed }
    let id: String
    let book: LibraryBookRecord
    let chapters: [ChapterRecord]
    var completed: Set<String> = []
    var status: Status = .queued
    var wifiOnly = true
    var message: String? = nil
}

/// User-requested downloads are pinned separately from the small recent cache.
/// Progress commits only after the immutable chapter file commits successfully.
actor OfflineDownloadStore {
    typealias Fetch = @Sendable (LibraryBookRecord,ChapterRecord) async throws -> ChapterDocument
    private let root: URL
    private let files: FileChapterRepository
    private let writer: any AtomicFileWriting
    private let quota: Int
    private var tasks: [OfflineDownloadTask]
    private var operation: Task<Void,Never>?
    private var fetch: Fetch?
    private var activeID: String?
    private var connected = false
    private var wifi = false
    private var changingTasks = false
    private var foreground = true
    init(directory: URL, quota: Int = 256 * 1024 * 1024, writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        root = directory; self.writer = writer; self.quota = quota
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true)
        files = try FileChapterRepository(directory:directory.appendingPathComponent("chapters"),writer:writer)
        let url = directory.appendingPathComponent("tasks.json")
        if FileManager.default.fileExists(atPath:url.path) {
            tasks = try JSONDecoder().decode([OfflineDownloadTask].self,from:Data(contentsOf:url))
            guard tasks.count <= 100, Set(tasks.map(\.id)).count == tasks.count,
                  tasks.allSatisfy({ task in task.book.source != nil && !task.chapters.isEmpty && task.chapters.count <= 10000 &&
                      task.chapters.allSatisfy { $0.bookID == task.book.id && $0.access == .readable } &&
                      Set(task.chapters.map(\.id)).count == task.chapters.count && task.completed.isSubset(of: Set(task.chapters.map(\.id))) }) else { throw ContentFailure.storageFailure }
            for index in tasks.indices where tasks[index].status == .running || tasks[index].status == .queued {
                tasks[index].status = .paused; tasks[index].message = "上次退出，已保留已下载章节；点击继续。"
            }
        } else { tasks = [] }
    }
    private func save(_ next: [OfflineDownloadTask]) throws {
        try writer.write(JSONEncoder().encode(next),to:root.appendingPathComponent("tasks.json")); tasks = next
    }
    func list() -> [OfflineDownloadTask] { tasks }
    func connectivity(connected: Bool, wifi: Bool) async {
        self.connected = connected; self.wifi = wifi
        if !connected || (!wifi && tasks.first(where: { $0.id == activeID })?.wifiOnly == true), let activeID { try? pause(activeID) }
        try? start()
    }
    func configure(fetch: @escaping Fetch) { self.fetch = fetch; try? start() }
    @discardableResult func enqueue(book: LibraryBookRecord, chapters: [ChapterRecord], wifiOnly: Bool) throws -> String {
        guard book.source != nil, !chapters.isEmpty, chapters.count <= 10000, tasks.count < 100,
              chapters.allSatisfy({ $0.bookID == book.id && $0.access == .readable }), Set(chapters.map(\.id)).count == chapters.count else { throw ContentFailure.invalidResponse }
        if let existing = tasks.first(where: { $0.book.id == book.id && $0.chapters == chapters && $0.status != .failed }) { return existing.id }
        let task = OfflineDownloadTask(id:UUID().uuidString,book:book,chapters:chapters,wifiOnly:wifiOnly)
        try save(tasks + [task]); try start(); return task.id
    }
    func pause(_ id: String) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status != .completed else { return }
        var next = tasks; next[index].status = .paused; next[index].message = nil
        if activeID == id { operation?.cancel() }
        do { try save(next) } catch { tasks = next; throw error }
    }
    func resume(_ id: String) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status != .completed else { return }
        var next = tasks; next[index].status = .queued; next[index].message = nil; try save(next); try start()
    }
    func pauseForBackground() async {
        foreground = false
        if let activeID { try? pause(activeID) }
        await operation?.value
    }
    func returnToForeground() { foreground = true; try? start() }
    func remove(_ id: String) async throws {
        changingTasks = true
        defer { changingTasks = false; try? start() }
        if activeID == id { try pause(id); await operation?.value }
        let removed = tasks.first { $0.id == id }
        try save(tasks.filter { $0.id != id })
        let keep = Set(tasks.flatMap { $0.completed })
        try await files.removeBatch((removed?.completed ?? []).subtracting(keep))
        try await files.collectUnreferenced()
    }
    func usage() async throws -> Int {
        let objects = root.appendingPathComponent("chapters/objects")
        return try FileManager.default.contentsOfDirectory(at:objects,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey]).reduce(0) { total,url in
            let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
            return total + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
        }
    }
    func document(book: LibraryBookRecord, chapter: ChapterRecord) async throws -> ChapterDocument? {
        guard tasks.contains(where: { task in task.book.id == book.id && task.book.source == book.source && task.completed.contains(chapter.id) && task.chapters.contains(where: { $0 == chapter }) }) else { return nil }
        return try await files.document(chapterID:chapter.id)
    }
    private func start() throws {
        guard foreground, !changingTasks, operation == nil, connected, let fetch, let task = tasks.first(where: { $0.status == .queued && (!$0.wifiOnly || wifi) }) else { return }
        if task.completed.count == task.chapters.count {
            var next = tasks; next[next.firstIndex(where: { $0.id == task.id })!].status = .completed; try save(next); try start(); return
        }
        var next = tasks; next[next.firstIndex(where: { $0.id == task.id })!].status = .running; try save(next)
        activeID = task.id
        operation = Task { [weak self] in
            guard let self else { return }
            await self.run(task,fetch:fetch)
            await self.finished()
        }
    }
    private func finished() {
        operation = nil; activeID = nil; try? start()
    }
    private func run(_ task: OfflineDownloadTask, fetch: @escaping Fetch) async {
        let pending = task.chapters.filter { !task.completed.contains($0.id) }
        await withTaskGroup(of: (ChapterRecord,ChapterDocument?,Bool).self) { group in
            var index = 0
            func enqueue() {
                guard index < pending.count else { return }
                let chapter = pending[index]; index += 1
                group.addTask {
                    do {
                        let document = try await fetch(task.book,chapter); try Task.checkCancellation()
                        return (chapter,document,false)
                    } catch { return (chapter,nil,error is CancellationError) }
                }
            }
            for _ in 0..<min(2,pending.count) { enqueue() }
            while let (chapter,document,cancelled) = await group.next() {
                if Task.isCancelled || tasks.first(where: { $0.id == task.id })?.status != .running { group.cancelAll(); continue }
                do {
                    guard let document, document.chapterID == chapter.id else { if cancelled { throw CancellationError() }; throw ContentFailure.unavailable }
                    guard try await usage() + JSONEncoder().encode(document).count <= quota else { throw ContentFailure.storageFailure }
                    do { try await files.save(document) } catch { throw ContentFailure.storageFailure }
                    guard !Task.isCancelled, let taskIndex = tasks.firstIndex(where: { $0.id == task.id }), tasks[taskIndex].status == .running else { group.cancelAll(); continue }
                    var next = tasks; next[taskIndex].completed.insert(chapter.id)
                    if next[taskIndex].completed.count == next[taskIndex].chapters.count { next[taskIndex].status = .completed }
                    try save(next); if !Task.isCancelled { enqueue() }
                } catch {
                    if let taskIndex = tasks.firstIndex(where: { $0.id == task.id }), tasks[taskIndex].status == .running {
                        var next = tasks; next[taskIndex].status = error is CancellationError ? .paused : .failed
                        next[taskIndex].message = error as? ContentFailure == .storageFailure ? "空间不足或存储提交失败，已保留下载进度。" : "部分章节下载失败，已完成章节保留，可重试。"
                        try? save(next)
                    }
                    group.cancelAll()
                }
            }
        }
    }
}

final class DownloadNetworkObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    init(store: OfflineDownloadStore) {
        monitor.pathUpdateHandler = { path in Task { await store.connectivity(connected:path.status == .satisfied,wifi:path.usesInterfaceType(.wifi)) } }
        monitor.start(queue:DispatchQueue(label:"com.yueshan.download-network"))
    }
    deinit { monitor.cancel() }
}
