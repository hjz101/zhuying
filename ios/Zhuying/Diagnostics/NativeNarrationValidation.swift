#if DEBUG
import Foundation
import AVFoundation

/// Offline speech rendering verifies the installed native synthesis engine.
/// It never claims a physical speaker, interruption or lock-screen test passed.
@MainActor enum NativeNarrationValidation {
    struct Sample: Codable {
        let language: String
        let status: String
        let frames: UInt64
        let nonSilentSamples: UInt64
        let file: String?
    }
    private struct Report: Codable {
        let schemaVersion: Int
        let sampleKind: String
        let physicalDeviceAccepted: Bool
        let samples: [Sample]
    }
    static func run() async throws {
        let directory = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("DevelopmentValidation")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var samples: [Sample] = []
        for (language,text) in [("zh-CN","竹影原生朗读验证。山间的来信，来自远方。"),("en-US","Native narration validation. A letter from the mountains.")] {
            guard let voice = AVSpeechSynthesisVoice(language:language) else { samples.append(.init(language:language,status:"voice-unavailable",frames:0,nonSilentSamples:0,file:nil)); continue }
            let name = "native-speech-" + language + ".caf", url = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at:url)
            let context = NativeSpeechRenderContext(language:language,url:url)
            samples.append(await context.render(text,voice:voice))
        }
        let report = Report(schemaVersion:1,sampleKind:"simulator-native-speech-to-pcm",physicalDeviceAccepted:false,samples:samples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:directory.appendingPathComponent("native-narration.json"),options:.atomic)
    }
}

@MainActor private final class NativeSpeechRenderContext {
    private let speech = AVSpeechSynthesizer()
    private let sink: NativeSpeechRenderSink
    init(language: String,url: URL) { sink = .init(language:language,url:url) }
    func render(_ text: String,voice: AVSpeechSynthesisVoice) async -> NativeNarrationValidation.Sample {
        let utterance = AVSpeechUtterance(string:text); utterance.voice = voice
        let sink = sink
        let timeout = Task { do { try await Task.sleep(for:.seconds(12)); sink.finish(completed:false) } catch {} }
        let result = await withCheckedContinuation { continuation in
            sink.begin(continuation)
            speech.write(utterance) { buffer in
                guard let buffer = buffer as? AVAudioPCMBuffer else { sink.finish(completed:false); return }
                if buffer.frameLength == 0 { sink.finish(completed:true) } else { sink.append(buffer) }
            }
        }
        timeout.cancel(); speech.stopSpeaking(at:.immediate); return result
    }
}
private final class NativeSpeechRenderSink: @unchecked Sendable {
    private let lock = NSLock()
    private let language: String
    private let url: URL
    private var writer: AVAudioFile?
    private var frames: UInt64 = 0, signal: UInt64 = 0
    private var failed = false
    private var continuation: CheckedContinuation<NativeNarrationValidation.Sample,Never>?
    init(language: String,url: URL) { self.language = language; self.url = url }
    func begin(_ value: CheckedContinuation<NativeNarrationValidation.Sample,Never>) { lock.lock(); defer { lock.unlock() }; continuation = value }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; guard continuation != nil else { return }
        do {
            guard frames + UInt64(buffer.frameLength) <= 1_000_000 else { failed = true; return }
            if writer == nil { writer = try AVAudioFile(forWriting:url,settings:buffer.format.settings) }
            try writer?.write(from:buffer); frames += UInt64(buffer.frameLength)
            if let channel = buffer.floatChannelData?[0] { for index in 0..<Int(buffer.frameLength) where abs(channel[index]) > 0.00001 { signal += 1 } }
            else if let channel = buffer.int16ChannelData?[0] { for index in 0..<Int(buffer.frameLength) where channel[index] != 0 { signal += 1 } }
            else if let channel = buffer.int32ChannelData?[0] { for index in 0..<Int(buffer.frameLength) where channel[index] != 0 { signal += 1 } }
        } catch { failed = true }
    }
    func finish(completed: Bool) {
        lock.lock(); guard let continuation else { lock.unlock(); return }
        self.continuation = nil; writer = nil
        let passed = completed && !failed && frames > 0 && signal > 0
        let sample = NativeNarrationValidation.Sample(language:language,status:passed ? "passed" : completed ? "invalid-audio" : "render-unavailable-or-timed-out",frames:frames,nonSilentSamples:signal,file:frames > 0 ? url.lastPathComponent : nil)
        lock.unlock(); continuation.resume(returning:sample)
    }
}
#endif
