import Foundation

enum AudioServiceError: LocalizedError {
    case rejected(Int), oversized, invalidResponse
    var errorDescription: String? {
        switch self {
        case .rejected(let status): [401,403].contains(status) ? "服务未授权，请检查访问密钥。" : status == 429 ? "服务已限流或额度不足，请稍后重试。" : "服务请求失败（HTTP \(status)），请检查接口配置。"
        case .oversized: "服务响应超过允许大小，已停止接收。"
        case .invalidResponse: "服务返回格式无法识别，请检查兼容接口。"
        }
    }
}

struct BoundedAudioHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration:configuration,delegate:SourceRedirectPolicy(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (stream,response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse else { throw AudioServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AudioServiceError.rejected(response.statusCode) }
        guard response.expectedContentLength <= 12 * 1024 * 1024 else { throw AudioServiceError.oversized }
        var bytes = Data()
        for try await byte in stream {
            if bytes.count % 65536 == 0 { try Task.checkCancellation() }
            guard bytes.count < 12 * 1024 * 1024 else { throw AudioServiceError.oversized }; bytes.append(byte)
        }
        try Task.checkCancellation(); return (bytes,response)
    }
}

struct AudioSocketAssembler {
    let requestID: String
    private(set) var sequence = 0
    private(set) var data = Data()
    private(set) var finished = false
    mutating func accept(_ message: String) throws {
        guard !finished,message.utf8.count <= 18 * 1024 * 1024,let bytes = message.data(using:.utf8),let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],object["request_id"] as? String == requestID else { throw AudioServiceError.invalidResponse }
        if object["type"] as? String == "done" { try WAVAudio.validate(data); finished = true; return }
        guard object["type"] as? String == "audio",object["sequence"] as? Int == sequence,sequence < 256,
              let encoded = object["audio"] as? String,let chunk = Data(base64Encoded:encoded),!chunk.isEmpty,data.count + chunk.count <= 12 * 1024 * 1024 else { throw AudioServiceError.invalidResponse }
        data.append(chunk); sequence += 1
    }
}
protocol WebSocketAudioFetching: Sendable { func audio(url: URL,key: String?,body: [String:String]) async throws -> Data }
protocol AudioSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> String
    func cancel()
}
private struct NativeAudioSocketConnection: AudioSocketConnection {
    let socket: URLSessionWebSocketTask
    func send(_ data: Data) async throws { try await socket.send(.data(data)) }
    func receive() async throws -> String {
        switch try await socket.receive() {
        case .string(let value): return value
        case .data(let bytes): guard let value = String(data:bytes,encoding:.utf8) else { throw AudioServiceError.invalidResponse }; return value
        @unknown default: throw AudioServiceError.invalidResponse
        }
    }
    func cancel() { socket.cancel(with:.goingAway,reason:nil) }
}
private final class AudioSocketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: (any AudioSocketConnection)?
    func replace(_ value: any AudioSocketConnection) { lock.lock(); let old = connection; connection = value; lock.unlock(); old?.cancel() }
    func cancel() { lock.lock(); let old = connection; connection = nil; lock.unlock(); old?.cancel() }
}
struct NativeWebSocketAudio: WebSocketAudioFetching {
    var connectionFactory: (@Sendable (URLRequest) -> any AudioSocketConnection)? = nil
    func audio(url: URL,key: String?,body: [String:String]) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration:configuration,delegate:SourceRedirectPolicy(),delegateQueue:nil), holder = AudioSocketHolder()
        var request = URLRequest(url:url); request.timeoutInterval = 30
        if let key { request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
        let fixedRequest = request
        let id = UUID().uuidString; var payload = body; payload["request_id"] = id; payload["type"] = "synthesize"
        let encodedPayload = try JSONEncoder().encode(payload), factory = connectionFactory
        defer { holder.cancel(); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await AsyncOperationDeadline.run(seconds:60) {
                try await withTaskCancellationHandler {
                    var assembler = AudioSocketAssembler(requestID:id)
                    for attempt in 0...1 {
                        try Task.checkCancellation()
                        let connection: any AudioSocketConnection
                        if let factory { connection = factory(fixedRequest) }
                        else {
                            let socket = session.webSocketTask(with:fixedRequest); socket.maximumMessageSize = 18 * 1024 * 1024; socket.resume()
                            connection = NativeAudioSocketConnection(socket:socket)
                        }
                        holder.replace(connection)
                        do {
                            let message: Data
                            if attempt == 0 { message = encodedPayload }
                            else { message = try JSONSerialization.data(withJSONObject:["type":"resume","request_id":id,"from_sequence":assembler.sequence]) }
                            try await connection.send(message)
                            while !assembler.finished { try Task.checkCancellation(); try assembler.accept(await connection.receive()) }
                            return assembler.data
                        } catch {
                            try Task.checkCancellation(); connection.cancel()
                            guard attempt == 0, error is URLError else { throw error }
                            // Resume the same synthesis request once. Never silently
                            // submit a second billable synthesis after a disconnect.
                        }
                    }
                    throw AudioServiceError.invalidResponse
                } onCancel: { holder.cancel() }
            }
        } onCancel: { holder.cancel() }
    }
}

enum AsyncOperationDeadline {
    static func run<T: Sendable>(seconds: Double,operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of:T.self) { group in
            group.addTask(operation:operation)
            group.addTask { try await Task.sleep(for:.seconds(seconds)); throw ContentFailure.timedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }; return result
        }
    }
}

struct CompatibleAudioClient: Sendable {
    let profile: AudioServiceProfile
    let key: String?
    var transport: any HTTPTransport = BoundedAudioHTTPTransport()
    var socket: any WebSocketAudioFetching = NativeWebSocketAudio()
    func speech(text: String,voice: String,speed: Double) async throws -> Data {
        guard !profile.ttsModel.isEmpty,!voice.isEmpty,!text.isEmpty,text.utf16.count <= 4096 else { throw NarrationError.serviceNotConfigured }
        if profile.usesKey { guard let key,!key.isEmpty else { throw ServiceCredentialError.missing } }
        let bytes: Data
        if profile.transport == .http {
            bytes = try await post("audio/speech",body:["model":profile.ttsModel,"input":text,"voice":voice,"speed":min(2,max(0.5,speed)),"response_format":"wav"])
        } else {
            guard let url = URL(string:profile.webSocketURL),url.scheme == "wss" else { throw NarrationError.serviceNotConfigured }
            bytes = try await socket.audio(url:url,key:profile.usesKey ? key : nil,body:["model":profile.ttsModel,"input":text,"voice":voice,"speed":String(speed),"response_format":"wav"])
        }
        try Task.checkCancellation(); try WAVAudio.validate(bytes); return bytes
    }
    func roleResponse(segments: [NarrationSegment]) async throws -> Data {
        guard !profile.analysisModel.isEmpty else { throw NarrationError.serviceNotConfigured }
        let input = try JSONSerialization.data(withJSONObject:segments.map { ["id":$0.id,"text":$0.text] },options:.sortedKeys)
        let system = "分析给定原创或用户授权的小说片段，为每个片段分配发言角色。只返回 JSON 对象：{\"roles\":[{\"id\":\"narrator\",\"name\":\"旁白\"}],\"segments\":[{\"id\":\"输入的原始id\",\"role\":\"narrator\"}]}。不要修改、添加片段 id；无法识别时使用 narrator。roles 最多64个。"
        let data = try await post("chat/completions",body:["model":profile.analysisModel,"messages":[["role":"system","content":system],["role":"user","content":String(decoding:input,as:UTF8.self)]],"response_format":["type":"json_object"],"stream":false])
        guard data.count <= 1024 * 1024,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],let choices = object["choices"] as? [[String:Any]],let message = choices.first?["message"] as? [String:Any],let text = message["content"] as? String,let bytes = text.data(using:.utf8) else { throw AudioServiceError.invalidResponse }; return bytes
    }
    private func post(_ path: String,body: [String:Any]) async throws -> Data {
        try Task.checkCancellation(); let base = try profile.validatedBaseURL()
        var request = URLRequest(url:base.appendingPathComponent(path)); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject:body); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if profile.usesKey { guard let key,!key.isEmpty else { throw ServiceCredentialError.missing }; request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
        let (data,response) = try await transport.send(request); try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw AudioServiceError.rejected(response.statusCode) }
        guard data.count <= 12 * 1024 * 1024 else { throw AudioServiceError.oversized }; return data
    }
}
