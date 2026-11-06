import Foundation
import Combine
import AVFoundation
import MediaPlayer

struct NarrationSettings: Codable, Equatable, Sendable {
    var voiceID = ""
    var speed = 1.0
    var followsReader = true
    var profileID: String? = nil
    var roleVoices: [String:String] = [:]
    var maximumAnalysisRequests = 8
    var analyzesNextChapter = false
}
enum NarrationMode: String, CaseIterable, Codable, Sendable { case system = "系统朗读", online = "在线朗读", roles = "多角色朗读" }
enum NarrationPhase: String, Sendable { case idle, buffering, playing, paused, failed, completed }
struct NarrationState: Equatable, Sendable {
    var phase = NarrationPhase.idle
    var bookID = ""
    var title = ""
    var chapter = 0
    var chapterTitle = ""
    var fraction = 0.0
    var anchor: ReadingAnchor? = nil
    var message: String? = nil
}
enum NarrationError: LocalizedError {
    case unavailableVoice, invalidAudio, serviceNotConfigured, analysisRequired, quota, invalidAnalysis
    var errorDescription: String? {
        switch self {
        case .unavailableVoice: "当前声音不可用，请选择自动声音，或先在系统设置下载声音。"
        case .invalidAudio: "服务未返回可播放的 WAV 音频，已停止，朗读位置保留。"
        case .serviceNotConfigured: "请先配置兼容服务、模型和访问密钥。"
        case .analysisRequired: "本章尚未完成角色分析，请先分析后开始多角色朗读。"
        case .quota: "已达到本次分析请求上限，已停止，当前位置保留。"
        case .invalidAnalysis: "角色分析结果无法对应当前正文，请重试分析。"
        }
    }
}

struct NarrationSegment: Identifiable, Equatable, Sendable {
    let id: String
    let paragraph: Int
    let offset: Int
    let text: String
    static func make(document: ChapterDocument) throws -> [NarrationSegment] {
        var segments: [NarrationSegment] = []
        for (paragraph,value) in document.paragraphs.enumerated() where !ReaderInlineImage.isToken(value.text) {
            let string = value.text as NSString
            var sentences: [NSRange] = []
            value.text.enumerateSubstrings(in:value.text.startIndex...,options:.bySentences) { _,range,_,_ in sentences.append(NSRange(range,in:value.text)) }
            if sentences.isEmpty { sentences = [NSRange(location:0,length:string.length)] }
            for sentence in sentences {
                var start = sentence.location
                while start < NSMaxRange(sentence) {
                    var end = min(NSMaxRange(sentence),start + 900)
                    if end < string.length { end = string.rangeOfComposedCharacterSequence(at:end).location }
                    if end <= start { end = NSMaxRange(string.rangeOfComposedCharacterSequence(at:start)) }
                    guard end - start <= 4096 else { throw ContentFailure.invalidResponse }
                    let text = string.substring(with:NSRange(location:start,length:end - start))
                    if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        segments.append(.init(id:StableContentID.make(document.chapterID,document.version,String(paragraph),String(start)),paragraph:paragraph,offset:start,text:text))
                    }
                    start = end
                }
            }
        }
        guard !segments.isEmpty else { throw ContentFailure.missingChapter }; return segments
    }
}

@MainActor protocol NarrationOutput: AnyObject {
    var onStarted: ((UUID) -> Void)? { get set }
    var onProgress: ((UUID,NSRange) -> Void)? { get set }
    var onFinished: ((UUID,Bool) -> Void)? { get set }
    var isPlaying: Bool { get }
    func speak(_ text: String,voiceID: String,speed: Double,token: UUID) throws
    func play(_ audio: Data,token: UUID) throws
    func pause() -> Bool
    func resume() -> Bool
    func stop()
    func reset()
}
extension NarrationOutput { func reset() { stop() } }

/// Retain callbacks for identity comparison only. AV objects are accessed on
/// MainActor; no mutable speech/player state crosses the delegate's thread.
private final class NarrationCallbackObject<T: AnyObject>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@MainActor final class NativeNarrationOutput: NSObject, NarrationOutput, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onStarted: ((UUID) -> Void)?
    var onProgress: ((UUID,NSRange) -> Void)?
    var onFinished: ((UUID,Bool) -> Void)?
    private lazy var speech: AVSpeechSynthesizer = { let value = AVSpeechSynthesizer(); value.delegate = self; return value }()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private var token: UUID?
    private var usingSpeech = false
    var isPlaying: Bool { usingSpeech ? speech.isSpeaking && !speech.isPaused : player?.isPlaying ?? false }
    func speak(_ text: String,voiceID: String,speed: Double,token: UUID) throws {
        stop()
        let voice = voiceID.isEmpty ? AVSpeechSynthesisVoice(language:text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) ? "zh-CN" : "en-US") : AVSpeechSynthesisVoice(identifier:voiceID)
        guard let voice else { throw NarrationError.unavailableVoice }
        let utterance = AVSpeechUtterance(string:text); utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,max(AVSpeechUtteranceMinimumSpeechRate,AVSpeechUtteranceDefaultSpeechRate * Float(min(2,max(0.5,speed)))))
        self.utterance = utterance; self.token = token; usingSpeech = true; speech.speak(utterance)
    }
    func play(_ audio: Data,token: UUID) throws {
        stop()
        let player = try AVAudioPlayer(data:audio); player.delegate = self
        guard player.duration > 0, player.prepareToPlay(), player.play() else { throw NarrationError.invalidAudio }
        self.player = player; self.token = token; usingSpeech = false; onStarted?(token)
    }
    func pause() -> Bool { if usingSpeech { return speech.pauseSpeaking(at:.immediate) }; player?.pause(); return player != nil }
    func resume() -> Bool { usingSpeech ? speech.continueSpeaking() : player?.play() ?? false }
    func stop() {
        token = nil; utterance = nil
        if usingSpeech { speech.stopSpeaking(at:.immediate) }; player?.stop(); player = nil
    }
    func reset() { stop(); speech = AVSpeechSynthesizer(); speech.delegate = self }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,didStart utterance: AVSpeechUtterance) {
        let object = NarrationCallbackObject(utterance)
        Task { @MainActor [weak self] in if let self,self.utterance === object.value,let token { onStarted?(token) } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,willSpeakRangeOfSpeechString range: NSRange,utterance: AVSpeechUtterance) {
        let object = NarrationCallbackObject(utterance)
        Task { @MainActor [weak self] in if let self,self.utterance === object.value,let token { onProgress?(token,range) } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,didFinish utterance: AVSpeechUtterance) {
        let object = NarrationCallbackObject(utterance)
        Task { @MainActor [weak self] in if let self,self.utterance === object.value,let token { onFinished?(token,true) } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,didCancel utterance: AVSpeechUtterance) {
        let object = NarrationCallbackObject(utterance)
        Task { @MainActor [weak self] in if let self,self.utterance === object.value,let token { onFinished?(token,false) } }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,successfully flag: Bool) {
        let object = NarrationCallbackObject(player)
        Task { @MainActor [weak self] in if let self,self.player === object.value,let token { onFinished?(token,flag) } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer,error: Error?) {
        let object = NarrationCallbackObject(player)
        Task { @MainActor [weak self] in if let self,self.player === object.value,let token { onFinished?(token,false) } }
    }
}

@MainActor final class NarrationController: ObservableObject {
    struct Chapter: Sendable { let index: Int; let document: ChapterDocument }
    typealias Loader = @MainActor (Int,Int) async throws -> Chapter
    typealias AudioLoader = @MainActor (NarrationSegment,ChapterDocument,NarrationMode) async throws -> Data
    @Published private(set) var state = NarrationState() { didSet { onState?(state); remote?.update(state) } }
    var onState: ((NarrationState) -> Void)?
    private let output: any NarrationOutput
    private let activatesSession: Bool
    private var remote: NarrationRemoteControls?
    private var book: Book?
    private var document: ChapterDocument?
    private var segments: [NarrationSegment] = []
    private var cursor = 0
    private var token: UUID?
    private var generation = UUID()
    private var operation: Task<Void,Never>?
    private var preload: Task<Data,Error>?
    private var preloadedID: String?
    private var loader: Loader?
    private var audioLoader: AudioLoader?
    private var settings = NarrationSettings()
    private var mode = NarrationMode.system
    private var userIntent = 0
    private var interruption: (playing: Bool,intent: Int)?
    private var heartbeat: Timer?
    init(output: (any NarrationOutput)? = nil,activatesSession: Bool = true) {
        self.output = output ?? NativeNarrationOutput(); self.activatesSession = activatesSession
        self.output.onStarted = { [weak self] in self?.started($0) }
        self.output.onProgress = { [weak self] in self?.progress($0,range:$1) }
        self.output.onFinished = { [weak self] in self?.finished($0,success:$1) }
    }
    func start(book: Book,chapter: Int,anchor: ReadingAnchor?,settings: NarrationSettings,mode: NarrationMode = .system,
               loader: @escaping Loader,audioLoader: AudioLoader? = nil) {
        stop(); self.book = book.metadataOnly(); self.settings = settings; self.loader = loader; self.mode = mode; self.audioLoader = audioLoader
        state = .init(phase:.buffering,bookID:book.id,title:book.title,chapter:chapter,chapterTitle:book.chapterTitle(chapter),anchor:anchor)
        do {
            if activatesSession {
                let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback,mode:.spokenAudio); try session.setActive(true)
                if remote == nil { remote = NarrationRemoteControls(controller:self) }
            }
            loadChapter(chapter,anchor:anchor)
        } catch { fail(error) }
    }
    private func loadChapter(_ chapter: Int,anchor: ReadingAnchor? = nil) {
        operation?.cancel(); preload?.cancel(); preload = nil; preloadedID = nil; token = nil; output.stop()
        generation = UUID(); let revision = generation
        let direction = chapter < state.chapter ? -1 : 1
        state.phase = .buffering; state.chapter = chapter; state.chapterTitle = book?.chapterTitle(chapter) ?? ""
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let loader = self.loader else { throw ContentFailure.missingChapter }
                let loaded = try await loader(chapter,direction); try Task.checkCancellation()
                guard generation == revision else { return }
                let content = loaded.document
                state.chapter = loaded.index; state.chapterTitle = book?.chapterTitle(loaded.index) ?? ""
                document = content; segments = try NarrationSegment.make(document:content); cursor = 0
                if let anchor, anchor.chapterID == content.chapterID {
                    switch ReadingAnchorResolver.resolve(anchor,in:content) {
                    case .exact(let paragraph,let offset), .recovered(let paragraph,let offset):
                        if let index = segments.firstIndex(where: { $0.paragraph > paragraph || ($0.paragraph == paragraph && $0.offset + $0.text.utf16.count > offset) }) {
                            cursor = index
                            let segment = segments[index], trim = max(0,offset - segment.offset)
                            if segment.paragraph == paragraph && trim > 0 {
                                let text = segment.text as NSString, safe = ReadingAnchor.safeOffset(trim,in:text)
                                segments[index] = .init(id:segment.id,paragraph:segment.paragraph,offset:segment.offset + safe,text:text.substring(from:safe))
                            }
                        }
                    default: throw ContentFailure.missingChapter
                    }
                }
                await playCurrent(revision:revision)
            } catch { if !Task.isCancelled && generation == revision { fail(error) } }
        }
    }
    private func playCurrent(revision: UUID) async {
        guard generation == revision, let document, segments.indices.contains(cursor), let book else { return }
        let segment = segments[cursor], nextToken = UUID(); token = nextToken; state.phase = .buffering
        do {
            state.anchor = try ReadingAnchor(bookID:book.id,document:document,paragraph:segment.paragraph,offset:segment.offset)
            if mode == .system { try output.speak(segment.text,voiceID:settings.voiceID,speed:settings.speed,token:nextToken) }
            else {
                guard let audioLoader else { throw NarrationError.serviceNotConfigured }
                let bytes: Data
                if preloadedID == segment.id, let preload { bytes = try await preload.value }
                else { bytes = try await audioLoader(segment,document,mode) }
                try Task.checkCancellation(); guard generation == revision, token == nextToken else { return }
                preload = nil; preloadedID = nil; try output.play(bytes,token:nextToken)
                if let next = segments[safe:cursor + 1] {
                    let mode = mode; preloadedID = next.id
                    preload = Task { try await audioLoader(next,document,mode) }
                }
            }
        } catch { if !Task.isCancelled && generation == revision { fail(error) } }
    }
    private func started(_ value: UUID) {
        guard token == value else { return }; state.phase = .playing; state.message = nil
        guard activatesSession,heartbeat == nil else { return }
        let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in guard let self,self.state.phase == .playing,self.output.isPlaying else { return }; self.onState?(self.state) }
        }
        heartbeat = timer; RunLoop.main.add(timer,forMode:.common)
    }
    private func progress(_ value: UUID,range: NSRange) {
        guard token == value, state.phase == .playing, let document, let book, let segment = segments[safe:cursor] else { return }
        guard range.location >= 0,range.location <= segment.text.utf16.count else { return }
        state.anchor = try? .init(bookID:book.id,document:document,paragraph:segment.paragraph,offset:segment.offset + range.location)
        state.fraction = min(1,(Double(cursor) + Double(range.location) / Double(max(1,segment.text.utf16.count))) / Double(max(1,segments.count)))
    }
    private func finished(_ value: UUID,success: Bool) {
        guard token == value,state.phase == .playing else { return }
        if !success { fail(NarrationError.invalidAudio); return }
        token = nil; cursor += 1
        state.fraction = Double(cursor) / Double(max(1,segments.count))
        if cursor < segments.count { let revision = generation; operation = Task { await playCurrent(revision:revision) } }
        else if let book, state.chapter + 1 < book.chapters.count { loadChapter(state.chapter + 1) }
        else { state.phase = .completed; state.fraction = 1; heartbeat?.invalidate(); heartbeat = nil; deactivate() }
    }
    func pause(userInitiated: Bool = true) {
        if userInitiated { userIntent += 1 }
        guard state.phase == .playing || state.phase == .buffering else { return }
        if state.phase == .buffering {
            generation = UUID(); operation?.cancel(); preload?.cancel(); preload = nil; preloadedID = nil; token = nil; output.stop()
        } else { _ = output.pause() }
        state.phase = .paused
        heartbeat?.invalidate(); heartbeat = nil; deactivate()
    }
    func resume(userInitiated: Bool = true) {
        if userInitiated { userIntent += 1 }
        guard state.phase == .paused || state.phase == .failed else { return }
        if token != nil,activatesSession { do { try AVAudioSession.sharedInstance().setActive(true) } catch { fail(error); return } }
        if token != nil, output.resume(),let token { started(token) }
        else if let book, let loader { start(book:book,chapter:state.chapter,anchor:state.anchor,settings:settings,mode:mode,loader:loader,audioLoader:audioLoader) }
    }
    func stop() {
        interruption = nil
        generation = UUID(); operation?.cancel(); operation = nil; preload?.cancel(); preload = nil; preloadedID = nil; token = nil
        output.stop(); state.phase = .idle; deactivate()
        heartbeat?.invalidate(); heartbeat = nil
        book = nil; document = nil; segments = []; loader = nil; audioLoader = nil
    }
    func changeChapter(_ delta: Int) { guard let book, book.chapters.indices.contains(state.chapter + delta) else { return }; loadChapter(state.chapter + delta) }
    func update(settings: NarrationSettings) {
        let wasPlaying = state.phase == .playing || state.phase == .buffering
        let restart = self.settings.voiceID != settings.voiceID || self.settings.speed != settings.speed || self.settings.profileID != settings.profileID || self.settings.roleVoices != settings.roleVoices
        self.settings = settings
        if wasPlaying && restart, let book, let loader { start(book:book,chapter:state.chapter,anchor:state.anchor,settings:settings,mode:mode,loader:loader,audioLoader:audioLoader) }
    }
    func interruptionBegan() { interruption = (state.phase == .playing,userIntent); pause(userInitiated:false) }
    func interruptionEnded(shouldResume: Bool) {
        defer { interruption = nil }
        if let interruption, interruption.playing, interruption.intent == userIntent, shouldResume { resume(userInitiated:false) }
    }
    func audioServicesReset() {
        interruption = nil
        generation = UUID(); operation?.cancel(); preload?.cancel(); preload = nil; preloadedID = nil; token = nil; output.reset()
        heartbeat?.invalidate(); heartbeat = nil
        if state.phase != .idle && state.phase != .completed { state.phase = .paused; state.message = "系统音频已重置，点击继续从保留的位置重启。" }
    }
    private func fail(_ error: Error) { token = nil; output.stop(); preload?.cancel(); preload = nil; preloadedID = nil; heartbeat?.invalidate(); heartbeat = nil; state.phase = .failed; state.message = error.localizedDescription; deactivate() }
    private func deactivate() { if activatesSession { try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation) } }
    deinit { heartbeat?.invalidate() }
}

@MainActor private final class NarrationRemoteControls {
    private weak var controller: NarrationController?
    private var targets: [(MPRemoteCommand,Any)] = []
    private var observers: [NSObjectProtocol] = []
    init(controller: NarrationController) {
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { $0.resume() }; add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.state.phase == .playing ? $0.pause() : $0.resume() }
        add(center.nextTrackCommand) { $0.changeChapter(1) }; add(center.previousTrackCommand) { $0.changeChapter(-1) }
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in
                guard let self, let controller = self.controller else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { controller.interruptionBegan() }
                else { controller.interruptionEnded(shouldResume:AVAudioSession.InterruptionOptions(rawValue:options).contains(.shouldResume)) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak controller] notification in
            guard (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in controller?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.mediaServicesWereResetNotification,object:nil,queue:.main) { [weak controller] _ in Task { @MainActor in controller?.audioServicesReset() } })
    }
    private func add(_ command: MPRemoteCommand,action: @escaping @MainActor (NarrationController) -> Void) {
        let target = command.addTarget { [weak controller] _ in Task { @MainActor in if let controller { action(controller) } }; return .success }
        targets.append((command,target))
    }
    func update(_ state: NarrationState) {
        if state.phase == .idle || state.phase == .completed || state.phase == .failed { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle:state.title,MPMediaItemPropertyAlbumTitle:state.chapterTitle,MPNowPlayingInfoPropertyPlaybackRate:state.phase == .playing ? 1 : 0]
    }
    deinit { for (command,target) in targets { command.removeTarget(target) }; for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
