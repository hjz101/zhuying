import Foundation
import Combine

@MainActor final class LibraryAudioCoordinator: ObservableObject {
    @Published private(set) var state = NarrationState()
    @Published private(set) var mode = NarrationMode.system
    private weak var library: LibraryStore?
    private var controller: NarrationController?
    private var serviceStore: AudioServiceStore?
    private var audioCache: AudioCache?
    private var roleStore: RoleAnalysisStore?
    private var listeningClock = ReadingActivityClock()
    private var analysisRequestsRemaining = 0
    private var rolesPlaybackBegan = false
    init(library: LibraryStore) { self.library = library }
    private var directory: URL {
        library?.workspace?.root.appendingPathComponent("AudioServices") ?? FileManager.default.temporaryDirectory.appendingPathComponent("YueshanAudio-" + String(ObjectIdentifier(self).hashValue))
    }
    private var cacheDirectory: URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("YueshanAudio/" + StableContentID.make(directory.path))
    }
    func services() throws -> AudioServiceStore {
        if let serviceStore { return serviceStore }
        let value = try AudioServiceStore(directory:directory,vault:ServiceKeychain(service:"com.yueshan.audio." + StableContentID.make(directory.path)))
        serviceStore = value; return value
    }
    private func cache() throws -> AudioCache {
        if let audioCache { return audioCache }; let value = try AudioCache(directory:cacheDirectory); audioCache = value; return value
    }
    private func roles() throws -> RoleAnalysisStore {
        if let roleStore { return roleStore }; let value = try RoleAnalysisStore(directory:cacheDirectory); roleStore = value; return value
    }
    private func player() -> NarrationController {
        if let controller { return controller }
        let value = NarrationController(); value.onState = { [weak self] in self?.receive($0) }; controller = value; return value
    }
    private func receive(_ next: NarrationState) {
        guard let library else { return }
        let previous = state
        if let session = listeningClock.advance(bookID:next.bookID,active:next.phase == .playing,interacted:true,wall:Date(),uptime:ProcessInfo.processInfo.systemUptime,kind:.listening) { library.appendActivity(session) }
        state = next
        if (previous.phase == .playing) != (next.phase == .playing) { library.narrationPlaybackChanged(next.phase == .playing) }
        if let anchor = next.anchor, next.phase == .playing || next.phase == .completed || (next.phase == .paused && previous.phase == .playing) {
            library.narrationAnchor = anchor
            if library.narrationSettings.followsReader && next.phase == .playing && library.reader?.book.id == anchor.bookID { library.followNarration(anchor) }
        }
    }
    private func client() throws -> CompatibleAudioClient {
        let services = try services()
        guard let profile = services.profiles.first(where: { $0.id == library?.narrationSettings.profileID }) else { throw NarrationError.serviceNotConfigured }
        return .init(profile:profile,key:try services.key(for:profile))
    }
    private func load(book: Book,index: Int,direction: Int = 1) async throws -> NarrationController.Chapter {
        guard let library else { throw CancellationError() }
        var index = index
        while book.chapters.indices.contains(index), library.chapterAccess(book,chapter:index) == .volume { index += direction }
        let request = try library.chapterRequest(for:book,chapter:index)
        guard request.chapter.access == .readable, let document = try await library.chapterRepository(for:book).document(chapterID:request.chapter.id) else { throw ContentFailure.restricted }
        return .init(index:index,document:document)
    }
    func start(bookID: String,mode: NarrationMode) throws {
        guard let library,let book = library.books.first(where: { $0.id == bookID }) else { throw ContentFailure.missingChapter }
        guard book.media == nil else { throw BookImportError.message("原版式 PDF 与漫画使用页面阅读；朗读请导入文字提取版本。") }
        if mode != .system { _ = try client() }
        self.mode = mode; rolesPlaybackBegan = false
        let anchor = library.narrationAnchor?.bookID == bookID ? library.narrationAnchor : nil
        let chapter = anchor.flatMap { library.chapterIndex(bookID:bookID,chapterID:$0.chapterID) } ?? library.progress[bookID]?.chapter ?? 0
        analysisRequestsRemaining = max(1,min(20,library.narrationSettings.maximumAnalysisRequests))
        player().start(book:book,chapter:chapter,anchor:anchor,settings:library.narrationSettings,mode:mode,loader:{ [weak self] index,direction in
            guard let self else { throw CancellationError() }; return try await load(book:book,index:index,direction:direction)
        },audioLoader:{ [weak self] segment,document,mode in
            guard let self else { throw CancellationError() }; return try await audio(segment:segment,document:document,bookID:book.id,mode:mode)
        })
    }
    private func audio(segment: NarrationSegment,document: ChapterDocument,bookID: String,mode: NarrationMode) async throws -> Data {
        guard let library else { throw CancellationError() }
        let client = try client(), cache = try cache()
        var voice = client.profile.voice
        if mode == .roles {
            let store = try roles()
            var analysis = await store.result(document:document,profile:client.profile)
            if analysis == nil {
                guard library.narrationSettings.analyzesNextChapter, rolesPlaybackBegan else { throw NarrationError.analysisRequired }
                let (created,requests) = try await store.analyze(document:document,client:client,maximumRequests:analysisRequestsRemaining)
                analysisRequestsRemaining -= requests; analysis = created
            }
            guard let analysis,analysis.documentVersion == document.version,let role = analysis.assignments[segment.id] else { throw NarrationError.invalidAnalysis }
            rolesPlaybackBegan = true
            voice = library.narrationSettings.roleVoices[Self.voiceKey(bookID:bookID,profileID:client.profile.id,roleID:role)] ?? voice
        }
        let key = StableContentID.make(client.profile.id,client.profile.credentialOrigin,client.profile.ttsModel,voice,String(library.narrationSettings.speed),document.version,segment.text)
        if let bytes = try await cache.data(key:key) { return bytes }
        let bytes = try await client.speech(text:segment.text,voice:voice,speed:library.narrationSettings.speed)
        try Task.checkCancellation(); try? await cache.save(bytes,key:key); return bytes
    }
    static func voiceKey(bookID: String,profileID: String,roleID: String) -> String { StableContentID.make(bookID,profileID,roleID) }
    func analyze(bookID: String,force: Bool) async throws -> RoleAnalysis {
        guard let library,let book = library.books.first(where: { $0.id == bookID }) else { throw ContentFailure.missingChapter }
        stop()
        let chapter = library.progress[bookID]?.chapter ?? 0,loaded = try await load(book:book,index:chapter)
        let store = try roles(), client = try client()
        let (result,_) = try await store.analyze(document:loaded.document,client:client,maximumRequests:library.narrationSettings.maximumAnalysisRequests,force:force)
        return result
    }
    func saveAnalysis(_ analysis: RoleAnalysis) async throws { try await roles().save(analysis) }
    func pause() { controller?.pause() }
    func resume() { controller?.resume() }
    func stop() { controller?.stop() }
    func next() { controller?.changeChapter(1) }
    func previous() { controller?.changeChapter(-1) }
    func updateSettings() { if let library { controller?.update(settings:library.narrationSettings) } }
    func cacheBytes() async throws -> Int { try await cache().bytes() }
    func clearCache() async throws { stop(); try await cache().clear() }
    func testConnection(profileID: String) async throws -> Data? {
        let services = try services()
        guard let profile = services.profiles.first(where: { $0.id == profileID }) else { throw NarrationError.serviceNotConfigured }
        let client = CompatibleAudioClient(profile:profile,key:try services.key(for:profile))
        if !profile.ttsModel.isEmpty { return try await client.speech(text:"阅山连接测试。",voice:profile.voice,speed:1) }
        let document = ChapterDocument(chapterID:"connection-test",paragraphs:["连接测试。"]), segments = try NarrationSegment.make(document:document)
        _ = try RoleAnalysis.decodeBatch(await client.roleResponse(segments:segments),segments:segments); return nil
    }
}
