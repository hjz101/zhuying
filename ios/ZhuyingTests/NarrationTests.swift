import XCTest
@testable import Zhuying

@MainActor private final class NarrationOutputProbe: NarrationOutput {
    var onStarted: ((UUID) -> Void)?
    var onProgress: ((UUID,NSRange) -> Void)?
    var onFinished: ((UUID,Bool) -> Void)?
    var isPlaying = false
    var tokens: [UUID] = [], texts: [String] = [], voices: [String] = [], audioCount = 0
    var autoStart = true, rejects = false
    func speak(_ text: String,voiceID: String,speed: Double,token: UUID) throws {
        if rejects { throw NarrationError.unavailableVoice }; tokens.append(token); texts.append(text); voices.append(voiceID)
        if autoStart { isPlaying = true; onStarted?(token) }
    }
    func play(_ audio: Data,token: UUID) throws { try WAVAudio.validate(audio); audioCount += 1; tokens.append(token); if autoStart { isPlaying = true; onStarted?(token) } }
    func pause() -> Bool { isPlaying = false; return true }
    func resume() -> Bool { isPlaying = true; return true }
    func stop() { isPlaying = false }
    func finish(_ success: Bool = true) { guard let token = tokens.last else { return }; isPlaying = false; onFinished?(token,success) }
}
@MainActor private final class AudioResponseGate {
    var requests = 0
    var continuations: [CheckedContinuation<Data,Error>] = []
    func load() async throws -> Data { requests += 1; return try await withCheckedThrowingContinuation { continuations.append($0) } }
    func resolve() { let pending = continuations; continuations = []; for c in pending { c.resume(returning:AudioTestFixtures.wave()) } }
}
@MainActor final class NarrationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws { for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for:.milliseconds(1)) }; XCTFail("Narration did not reach the expected state") }
    private func start(_ player: NarrationController,book: Book = AudioTestFixtures.book(),settings: NarrationSettings = .init()) {
        player.start(book:book,chapter:0,anchor:nil,settings:settings,loader:{ index,_ in .init(index:index,document:.init(chapterID:"c\(index)",paragraphs:book.content[index])) })
    }
    func testUnicodeSegmentsPreserveTextBoundariesAndSkipEmbeddedImages() throws {
        let text = String(repeating:"山间👩🏽‍🚀e\u{301}星光",count:300), doc = ChapterDocument(chapterID:"unicode",paragraphs:[text,ReaderInlineImage.prefix + "asset","English words. 第二句。"]) 
        let segments = try NarrationSegment.make(document:doc)
        XCTAssertTrue(segments.allSatisfy { !$0.text.contains(ReaderInlineImage.prefix) && $0.text.utf16.count <= 4096 })
        XCTAssertEqual(segments.filter { $0.paragraph == 0 }.map(\.text).joined(),text)
        for segment in segments { XCTAssertEqual((doc.paragraphs[segment.paragraph].text as NSString).substring(with:NSRange(location:segment.offset,length:segment.text.utf16.count)),segment.text) }
        let other = try NarrationSegment.make(document:.init(chapterID:"other",paragraphs:[text])); XCTAssertNotEqual(other.first?.id,segments.first?.id)
    }
    func testStartsOnlyOnOutputConfirmationAndPreservesWordPositionAcrossPause() async throws {
        let output = NarrationOutputProbe(); output.autoStart = false
        let player = NarrationController(output:output,activatesSession:false); defer { player.stop() }; start(player)
        try await wait { !output.tokens.isEmpty }; XCTAssertEqual(player.state.phase,.buffering)
        let token = output.tokens[0]; output.isPlaying = true; output.onStarted?(token)
        output.onProgress?(token,NSRange(location:2,length:1)); let anchor = player.state.anchor
        XCTAssertEqual(anchor?.utf16Offset,2)
        player.pause(); XCTAssertEqual(player.state.phase,.paused)
        output.onFinished?(token,true); XCTAssertEqual(player.state.chapter,0); XCTAssertEqual(player.state.phase,.paused)
        player.resume(); XCTAssertEqual(player.state.phase,.playing); XCTAssertEqual(player.state.anchor,anchor)
        player.stop(); output.onProgress?(token,NSRange(location:5,length:1)); output.onFinished?(token,true)
        XCTAssertEqual(player.state.phase,.idle); XCTAssertEqual(player.state.anchor,anchor)
    }
    func testFinishedSpeechAdvancesChaptersAndFailureKeepsConfirmedChapter() async throws {
        let output = NarrationOutputProbe(), player = NarrationController(output:output,activatesSession:false); defer { player.stop() }; start(player)
        try await wait { player.state.phase == .playing }
        output.finish(); try await wait { player.state.chapter == 1 && player.state.phase == .playing }
        let last = player.state.anchor; output.finish(false)
        XCTAssertEqual(player.state.phase,.failed); XCTAssertEqual(player.state.anchor,last); XCTAssertEqual(player.state.chapter,1)
    }
    func testCancelledBufferCannotStartAudioAndCanBeExplicitlyResumed() async throws {
        let output = NarrationOutputProbe(), gate = AudioResponseGate(), player = NarrationController(output:output,activatesSession:false), book = AudioTestFixtures.book(chapters:1)
        defer { player.stop(); gate.resolve() }
        player.start(book:book,chapter:0,anchor:nil,settings:.init(),mode:.online,loader:{ index,_ in .init(index:index,document:.init(chapterID:"c",paragraphs:book.content[0])) },audioLoader:{ _,_,_ in try await gate.load() })
        try await wait { gate.requests == 1 }; XCTAssertEqual(player.state.phase,.buffering); XCTAssertEqual(output.audioCount,0)
        player.pause(); gate.resolve(); await Task.yield(); XCTAssertEqual(player.state.phase,.paused); XCTAssertEqual(output.audioCount,0)
        player.resume(); try await wait { gate.requests == 2 }; gate.resolve(); try await wait { player.state.phase == .playing }
        XCTAssertEqual(output.audioCount,1)
    }
    func testOnlyOneFutureAudioSegmentIsPrefetchedAndPlayedInOrder() async throws {
        let output = NarrationOutputProbe(), player = NarrationController(output:output,activatesSession:false), book = AudioTestFixtures.book(chapters:1)
        var fetched: [String] = []; defer { player.stop() }
        player.start(book:book,chapter:0,anchor:nil,settings:.init(),mode:.online,loader:{ index,_ in .init(index:index,document:.init(chapterID:"c",paragraphs:["第一句。","第二句。","第三句。"])) },audioLoader:{ segment,_,_ in fetched.append(segment.text); return AudioTestFixtures.wave() })
        try await wait { fetched.count == 2 }; XCTAssertEqual(output.audioCount,1); XCTAssertEqual(fetched,["第一句。","第二句。"])
        output.finish(); try await wait { fetched.count == 3 && output.audioCount == 2 }; XCTAssertEqual(fetched.last,"第三句。")
    }
    func testInterruptionRespectsUserPauseAndAudioResetRequiresExplicitResume() async throws {
        let output = NarrationOutputProbe(), player = NarrationController(output:output,activatesSession:false); defer { player.stop() }; start(player)
        try await wait { player.state.phase == .playing }
        player.interruptionBegan(); XCTAssertEqual(player.state.phase,.paused)
        player.pause(); player.interruptionEnded(shouldResume:true); XCTAssertEqual(player.state.phase,.paused)
        player.resume(); XCTAssertEqual(player.state.phase,.playing)
        player.interruptionBegan(); player.interruptionEnded(shouldResume:true); XCTAssertEqual(player.state.phase,.playing)
        player.audioServicesReset(); XCTAssertEqual(player.state.phase,.paused)
        player.resume(); try await wait { output.tokens.count >= 2 && player.state.phase == .playing }
    }
    func testUnavailableVoiceDoesNotPretendToPlayOrAdvance() async throws {
        let output = NarrationOutputProbe(); output.rejects = true
        let player = NarrationController(output:output,activatesSession:false); defer { player.stop() }; start(player)
        try await wait { player.state.phase == .failed }; XCTAssertTrue(output.tokens.isEmpty); XCTAssertEqual(player.state.chapter,0)
    }
}
