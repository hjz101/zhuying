import XCTest
import AVFoundation
@testable import Yueshan

private actor AudioTransportProbe: HTTPTransport {
    var requests: [URLRequest] = []
    var invalidAudio = false
    var delay = false
    func configure(invalid: Bool = false,delay: Bool = false) { invalidAudio = invalid; self.delay = delay }
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request); if delay { try await Task.sleep(for:.milliseconds(100)) }
        let data: Data
        if request.url!.path.hasSuffix("audio/speech") { data = invalidAudio ? Data("{\"error\":\"not audio\"}".utf8) : AudioTestFixtures.wave() }
        else {
            let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any], messages = body["messages"] as! [[String:Any]]
            let text = messages.last!["content"] as! String, segments = try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [[String:String]]
            let result: [String:Any] = ["roles":[["id":"narrator","name":"旁白"],["id":"reader","name":"读者"]],"segments":segments.enumerated().map { ["id":$0.element["id"]!,"role":$0.offset % 2 == 0 ? "reader" : "narrator"] }]
            let content = String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self)
            data = try JSONSerialization.data(withJSONObject:["choices":[["message":["content":content]]]])
        }
        return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
private actor AudioSocketProbe: WebSocketAudioFetching {
    var requests = 0
    func audio(url: URL,key: String?,body: [String:String]) async throws -> Data { requests += 1; return AudioTestFixtures.wave() }
}
private struct AudioIndexFailure: AtomicFileWriting {
    func write(_ data: Data,to url: URL) throws { if url.lastPathComponent == "audio-cache.json" { throw CocoaError(.fileWriteOutOfSpace) }; try data.write(to:url,options:.atomic) }
}
private final class ResumeSocketProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String:Any]] = []
    private var connections = 0
    private var cursor: [Int:Int] = [:]
    var rejectResume = false
    func connect(_ request: URLRequest) -> any AudioSocketConnection {
        lock.lock(); defer { lock.unlock() }; connections += 1
        return Connection(probe:self,index:connections)
    }
    func sent(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; messages.append(try JSONSerialization.jsonObject(with:data) as! [String:Any]) }
    func receive(_ index: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let position = cursor[index,default:0]; cursor[index] = position + 1
        let id = messages[0]["request_id"] as! String, wave = AudioTestFixtures.wave(), split = wave.count / 2
        let object: [String:Any]
        if index == 1 {
            if position > 0 { throw URLError(.networkConnectionLost) }
            object = ["type":"audio","request_id":id,"sequence":0,"audio":wave.prefix(split).base64EncodedString()]
        } else if rejectResume { object = ["type":"error","request_id":id] }
        else if position == 0 { object = ["type":"audio","request_id":id,"sequence":1,"audio":wave.suffix(from:split).base64EncodedString()] }
        else { object = ["type":"done","request_id":id] }
        return String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    }
    func payloads() -> [[String:Any]] { lock.lock(); defer { lock.unlock() }; return messages }
    private struct Connection: AudioSocketConnection {
        let probe: ResumeSocketProbe; let index: Int
        func send(_ data: Data) async throws { try probe.sent(data) }
        func receive() async throws -> String { try probe.receive(index) }
        func cancel() {}
    }
}
private final class RoleWriteOnceFailure: AtomicFileWriting, @unchecked Sendable {
    private let lock = NSLock(); private var failed = false
    func write(_ data: Data,to url: URL) throws {
        lock.lock(); let shouldFail = !failed; failed = true; lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to:url,options:.atomic)
    }
}
final class CompatibleAudioTests: XCTestCase {
    func testNativeSocketResumesSameRequestAndSequenceWithoutSecondSynthesis() async throws {
        let probe = ResumeSocketProbe(), socket = NativeWebSocketAudio(connectionFactory:{ probe.connect($0) })
        let wave = try await socket.audio(url:URL(string:"wss://speech.test/socket")!,key:nil,body:["input":"原创正文"])
        XCTAssertEqual(wave,AudioTestFixtures.wave())
        let messages = probe.payloads(); XCTAssertEqual(messages.count,2)
        XCTAssertEqual(messages[0]["type"] as? String,"synthesize"); XCTAssertEqual(messages[1]["type"] as? String,"resume")
        XCTAssertEqual(messages[0]["request_id"] as? String,messages[1]["request_id"] as? String)
        XCTAssertEqual(messages[1]["from_sequence"] as? Int,1)
    }
    func testUnsupportedSocketResumeFailsWithoutResubmittingOrRepeatedRetries() async throws {
        let probe = ResumeSocketProbe(); probe.rejectResume = true
        do { _ = try await NativeWebSocketAudio(connectionFactory:{ probe.connect($0) }).audio(url:URL(string:"wss://speech.test/socket")!,key:nil,body:["input":"正文"]); XCTFail("Resume unsupported") } catch {}
        XCTAssertEqual(probe.payloads().count,2)
        let missing = AudioSocketProbe(); var profile = AudioTestFixtures.profile(); profile.transport = .webSocket; profile.webSocketURL = "wss://speech.test/socket"
        do { _ = try await CompatibleAudioClient(profile:profile,key:nil,socket:missing).speech(text:"正文",voice:"reader",speed:1); XCTFail("Missing key") } catch {}
        let requests = await missing.requests; XCTAssertEqual(requests,0)
    }
    func testRoleFailedSaveRetriesWithoutChargingAndDamagedCacheRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let transport = AudioTransportProbe(), profile = AudioTestFixtures.profile(), doc = ChapterDocument(chapterID:"save-retry",paragraphs:["原创角色正文。"])
        let client = CompatibleAudioClient(profile:profile,key:"test-only",transport:transport), store = try RoleAnalysisStore(directory:root,writer:RoleWriteOnceFailure())
        do { _ = try await store.analyze(document:doc,client:client,maximumRequests:1); XCTFail("Write failure") } catch {}
        let (saved,cost) = try await store.analyze(document:doc,client:client,maximumRequests:0)
        XCTAssertEqual(cost,0); XCTAssertFalse(saved.assignments.isEmpty)
        let requests = await transport.requests; XCTAssertEqual(requests.count,1)
        try Data("broken index".utf8).write(to:root.appendingPathComponent("role-analysis.json"))
        let reopened = try RoleAnalysisStore(directory:root), result = await reopened.result(document:doc,profile:profile); XCTAssertNil(result)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("role-analysis.damaged-") })
        let cache = try AudioCache(directory:root.appendingPathComponent("audio")), key = StableContentID.make("test")
        try await cache.save(AudioTestFixtures.wave(),key:key)
        try Data("broken".utf8).write(to:root.appendingPathComponent("audio/audio-cache.json"))
        let fresh = try AudioCache(directory:root.appendingPathComponent("audio")), bytes = try await fresh.bytes(); XCTAssertEqual(bytes,0)
    }
    func testHTTPContractAndOriginalWAVDecodeWithoutReportingPlayback() async throws {
        let transport = AudioTransportProbe(), profile = AudioTestFixtures.profile(), client = CompatibleAudioClient(profile:profile,key:"test-only-key",transport:transport)
        let wave = try await client.speech(text:"原创测试正文。",voice:"reader",speed:1.2)
        try WAVAudio.validate(wave); let decoded = try AVAudioPlayer(data:wave); XCTAssertGreaterThan(decoded.duration,0)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path,"/v1/audio/speech"); XCTAssertEqual(requests[0].value(forHTTPHeaderField:"Authorization"),"Bearer test-only-key")
        let body = try JSONSerialization.jsonObject(with:requests[0].httpBody!) as! [String:Any]
        XCTAssertEqual(body["voice"] as? String,"reader"); XCTAssertEqual(body["response_format"] as? String,"wav")
        XCTAssertFalse(decoded.isPlaying)
    }
    func testMissingKeyAndJSONResponseCannotBecomePlayableAudio() async throws {
        let transport = AudioTransportProbe(), profile = AudioTestFixtures.profile()
        do { _ = try await CompatibleAudioClient(profile:profile,key:nil,transport:transport).speech(text:"正文",voice:"reader",speed:1); XCTFail("Missing key") } catch {}
        let empty = await transport.requests; XCTAssertTrue(empty.isEmpty)
        await transport.configure(invalid:true)
        do { _ = try await CompatibleAudioClient(profile:profile,key:"test-only",transport:transport).speech(text:"正文",voice:"reader",speed:1); XCTFail("JSON is not audio") } catch { XCTAssertTrue(error is NarrationError) }
    }
    func testSocketSelectionAndFrameOrderIdentityAndCompletionValidation() async throws {
        let socket = AudioSocketProbe(); var profile = AudioTestFixtures.profile(); profile.transport = .webSocket; profile.webSocketURL = "wss://speech.test/socket"
        let result = try await CompatibleAudioClient(profile:profile,key:"test-only",socket:socket).speech(text:"正文",voice:"reader",speed:1)
        XCTAssertEqual(result,AudioTestFixtures.wave()); let count = await socket.requests; XCTAssertEqual(count,1)
        var assembler = AudioSocketAssembler(requestID:"request")
        func frame(_ sequence: Int,_ data: Data,id: String = "request") throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:["type":"audio","request_id":id,"sequence":sequence,"audio":data.base64EncodedString()]),as:UTF8.self) }
        let wave = AudioTestFixtures.wave(), split = wave.count / 2
        try assembler.accept(frame(0,wave.prefix(split))); XCTAssertThrowsError(try assembler.accept(frame(0,wave.suffix(from:split))))
        XCTAssertThrowsError(try assembler.accept(frame(1,wave.suffix(from:split),id:"wrong")))
        try assembler.accept(frame(1,wave.suffix(from:split))); try assembler.accept("{\"type\":\"done\",\"request_id\":\"request\"}")
        XCTAssertTrue(assembler.finished); XCTAssertEqual(assembler.data,wave)
        XCTAssertThrowsError(try assembler.accept(frame(2,Data([1]))))
    }
    func testAudioCacheRestartTamperingAndFailedCommitPreserveOldContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let cache = try AudioCache(directory:root), key = StableContentID.make("voice","text"), first = AudioTestFixtures.wave(), second = AudioTestFixtures.wave(samples:900)
        try await cache.save(first,key:key)
        let failing = try AudioCache(directory:root,writer:AudioIndexFailure())
        do { try await failing.save(second,key:key); XCTFail("Manifest failure") } catch {}
        let retained = try await failing.data(key:key); XCTAssertEqual(retained,first)
        let restarted = try AudioCache(directory:root), saved = try await restarted.data(key:key); XCTAssertEqual(saved,first)
        let blob = root.appendingPathComponent(FileResourceStore.digest(first) + ".wav"); try Data("tampered".utf8).write(to:blob)
        let corrupt = try await restarted.data(key:key); XCTAssertNil(corrupt)
        let bytes = try await restarted.bytes(); XCTAssertEqual(bytes,0)
    }
    func testAudioCacheQuotaEvictionAndClearUseActualDiskBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let wave = AudioTestFixtures.wave(), cache = try AudioCache(directory:root,limit:wave.count + 10)
        let a = StableContentID.make("a"), b = StableContentID.make("b")
        try await cache.save(wave,key:a); try await cache.save(AudioTestFixtures.wave(samples:801),key:b)
        let evicted = try await cache.data(key:a); XCTAssertNil(evicted)
        let bytes = try await cache.bytes(); XCTAssertLessThanOrEqual(bytes,wave.count + 10)
        try await cache.clear(); let cleared = try await cache.bytes(); XCTAssertEqual(cleared,0)
    }
    func testRoleAnalysisCachesByChapterVersionAndModelAndAllowsEditedNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try RoleAnalysisStore(directory:root), transport = AudioTransportProbe(), profile = AudioTestFixtures.profile()
        let client = CompatibleAudioClient(profile:profile,key:"test-only",transport:transport), document = ChapterDocument(chapterID:"roles",paragraphs:["读者说：你好。","远处传来回声。"])
        let (initial,cost) = try await store.analyze(document:document,client:client,maximumRequests:2)
        XCTAssertEqual(cost,1); XCTAssertEqual(initial.assignments.count,2); XCTAssertEqual(initial.roles.count,2)
        let (_,cachedCost) = try await store.analyze(document:document,client:client,maximumRequests:2); XCTAssertEqual(cachedCost,0)
        var edited = initial; edited.roles[0].name = "修改后的角色"; try await store.save(edited)
        let restarted = try RoleAnalysisStore(directory:root), restored = await restarted.result(document:document,profile:profile)
        XCTAssertEqual(restored?.roles[0].name,"修改后的角色")
        let changed = await restarted.result(document:.init(chapterID:"roles",paragraphs:["正文发生变化。"]),profile:profile); XCTAssertNil(changed)
        var otherModel = profile; otherModel.analysisModel = "different-model"
        let modelChanged = await restarted.result(document:document,profile:otherModel); XCTAssertNil(modelChanged)
        do { _ = try await store.analyze(document:.init(chapterID:"other",paragraphs:["新章。"]),client:client,maximumRequests:0); XCTFail("Quota must prevent a request") } catch {}
        let requests = await transport.requests; XCTAssertEqual(requests.count,1)
    }
    func testForeignOrDuplicateRoleSegmentsAreRejectedAndUnknownRoleFallsBack() throws {
        let segments = try NarrationSegment.make(document:.init(chapterID:"c",paragraphs:["原创正文。"])), id = segments[0].id
        let fallback = Data("{\"roles\":[],\"segments\":[{\"id\":\"\(id)\",\"role\":\"unknown\"}]}".utf8)
        XCTAssertEqual(try RoleAnalysis.decodeBatch(fallback,segments:segments).assignments[id],"narrator")
        let foreign = Data("{\"roles\":[],\"segments\":[{\"id\":\"foreign\",\"role\":\"narrator\"}]}".utf8)
        XCTAssertThrowsError(try RoleAnalysis.decodeBatch(foreign,segments:segments))
        let repeated = Data("{\"roles\":[],\"segments\":[{\"id\":\"\(id)\",\"role\":\"narrator\"},{\"id\":\"\(id)\",\"role\":\"narrator\"}]}".utf8)
        XCTAssertThrowsError(try RoleAnalysis.decodeBatch(repeated,segments:segments))
    }
    func testCancelledRoleAnalysisDoesNotCommitPartialResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try RoleAnalysisStore(directory:root), transport = AudioTransportProbe(); await transport.configure(delay:true)
        let profile = AudioTestFixtures.profile(), client = CompatibleAudioClient(profile:profile,key:"test-only",transport:transport), document = ChapterDocument(chapterID:"cancelled",paragraphs:["取消中的正文。"])
        let task = Task { try await store.analyze(document:document,client:client,maximumRequests:1) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis") } catch is CancellationError {}
        let cached = await store.result(document:document,profile:profile); XCTAssertNil(cached)
    }
}
