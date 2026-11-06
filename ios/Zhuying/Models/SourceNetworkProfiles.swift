import Foundation
import Network

enum SourceNetworkError: LocalizedError, Equatable {
    case invalid, unavailable, timedOut, response
    var errorDescription: String? { switch self {
    case .invalid: "网络配置无效，请检查地址、端口与所选模式。"
    case .unavailable: "当前书源网络不可用，可重试或恢复系统网络。"
    case .timedOut: "当前书源的代理或 DNS 响应超时。"
    case .response: "代理或 DNS 返回无法识别的响应。"
    } }
}
struct SourceNetworkProfile: Codable, Equatable, Sendable {
    enum Mode: String,Codable,CaseIterable,Sendable { case system = "系统网络",proxy = "HTTP CONNECT 代理",fixedIP = "指定 IP",dns = "指定 DNS" }
    var version = 1
    var mode: Mode = .system
    var server = ""
    var port = 7890
    static func supportedModes(for origin: URL) -> [Mode] {
        switch origin.scheme?.lowercased() {
        case "http": return [.system, .proxy]
        case "https": return Mode.allCases
        default: return []
        }
    }
    func validate(origin: URL) throws {
        try validate()
        guard let canonical = try? LegadoSourcePolicy.canonicalOrigin(origin),
              Self.supportedModes(for: canonical).contains(mode) else { throw SourceNetworkError.invalid }
    }
    func validate() throws {
        guard version == 1,(1...65535).contains(port),server.utf8.count <= 253 else { throw SourceNetworkError.invalid }
        switch mode {
        case .system: break
        case .fixedIP,.dns: guard IPv4Address(server) != nil || IPv6Address(server) != nil else { throw SourceNetworkError.invalid }
        case .proxy: guard !server.isEmpty,IPv6Address(server) != nil || server.range(of:"^[A-Za-z0-9][A-Za-z0-9.-]*$",options:.regularExpression) != nil else { throw SourceNetworkError.invalid }
        }
    }
}
@MainActor final class SourceNetworkProfiles {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ sourceID: String,_ origin: URL) -> String { "source.network.v1." + StableContentID.make(sourceID,origin.absoluteString) }
    func profile(sourceID: String,origin: URL) throws -> SourceNetworkProfile {
        guard let data = defaults.data(forKey:key(sourceID,origin)) else { return .init() }
        let profile = try JSONDecoder().decode(SourceNetworkProfile.self,from:data); try profile.validate(origin: origin); return profile
    }
    func save(_ profile: SourceNetworkProfile,sourceID: String,origin: URL) throws { try profile.validate(origin: origin); defaults.set(try JSONEncoder().encode(profile),forKey:key(sourceID,origin)); NotificationCenter.default.post(name:.sourceNetworkChanged,object:nil) }
    func reset(sourceID: String,origin: URL) { defaults.removeObject(forKey:key(sourceID,origin)); NotificationCenter.default.post(name:.sourceNetworkChanged,object:nil) }
}
extension Notification.Name { static let sourceNetworkChanged = Notification.Name("sourceNetworkChanged") }

enum DNSWire {
    struct Answer: Equatable { let address: String; let ttl: Int }
    static func query(host: String,type: UInt16,id: UInt16) throws -> Data {
        guard [1,28].contains(type),!host.isEmpty,host.utf8.count <= 253,host.split(separator:".").allSatisfy({!$0.isEmpty && $0.utf8.count <= 63 && $0.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")})}) else { throw SourceNetworkError.invalid }
        var bytes = Data(); append(id,to:&bytes); append(0x0100,to:&bytes); append(1,to:&bytes); for _ in 0..<3 { append(0,to:&bytes) }
        for label in host.split(separator:".") { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf:label.utf8) }; bytes.append(0); append(type,to:&bytes); append(1,to:&bytes); return bytes
    }
    static func append(_ value: UInt16,to bytes: inout Data) { bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 255)) }
    static func answers(_ data: Data,host: String,type: UInt16,id: UInt16) throws -> [Answer] {
        let bytes = [UInt8](data); guard bytes.count >= 12,bytes.count <= 4096 else { throw SourceNetworkError.response }
        func u16(_ offset: Int) throws -> UInt16 { guard offset + 1 < bytes.count else { throw SourceNetworkError.response }; return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        guard try u16(0) == id,try u16(2) & 0xf80f == 0x8000,try u16(2) & 0x0200 == 0,try u16(4) == 1,try u16(6) <= 64 else { throw SourceNetworkError.response }
        func name(_ start: Int) throws -> (String,Int) {
            var position = start,end: Int?,labels: [String] = [],visited = Set<Int>()
            for _ in 0..<128 {
                guard position < bytes.count,visited.insert(position).inserted else { throw SourceNetworkError.response }
                let size = Int(bytes[position])
                if size == 0 { return (labels.joined(separator:".").lowercased(),end ?? position + 1) }
                if size & 0xc0 == 0xc0 { guard position + 1 < bytes.count else { throw SourceNetworkError.response }; if end == nil { end = position + 2 }; position = (size & 0x3f) << 8 | Int(bytes[position + 1]); continue }
                guard size <= 63,position + size < bytes.count,let text = String(bytes:bytes[(position + 1)...(position + size)],encoding:.ascii) else { throw SourceNetworkError.response }; labels.append(text); position += size + 1
            }
            throw SourceNetworkError.response
        }
        let question = try name(12); guard question.0 == host.lowercased(),try u16(question.1) == type,try u16(question.1 + 2) == 1 else { throw SourceNetworkError.response }
        var offset = question.1 + 4,aliases: [(String,String)] = [],values: [(String,Answer)] = []
        for _ in 0..<(try Int(u16(6))) {
            let owner = try name(offset); offset = owner.1
            let recordType = try u16(offset),recordClass = try u16(offset + 2); guard offset + 9 < bytes.count else { throw SourceNetworkError.response }
            let ttl = bytes[(offset + 4)...(offset + 7)].reduce(UInt32(0)){($0 << 8) | UInt32($1)},length = try Int(u16(offset + 8)); offset += 10
            guard offset + length <= bytes.count else { throw SourceNetworkError.response }
            if recordClass == 1,recordType == 5 { aliases.append((owner.0,try name(offset).0)) }
            if recordClass == 1,recordType == type {
                let raw = Data(bytes[offset..<(offset + length)]),address: String?
                if type == 1,length == 4 { address = IPv4Address(raw)?.debugDescription }
                else if type == 28,length == 16 { address = IPv6Address(raw)?.debugDescription } else { address = nil }
                if let address { values.append((owner.0,.init(address:address,ttl:min(600,Int(ttl))))) }
            }
            offset += length
        }
        var owners: Set<String> = [host.lowercased()]
        for _ in 0..<8 { let next = aliases.filter{owners.contains($0.0)}.map(\.1); let previous = owners.count; owners.formUnion(next); if owners.count == previous { break } }
        return values.filter{owners.contains($0.0)}.map(\.1)
    }
}

private final class DNSDatagram: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label:"com.zhuying.dns")
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<Data,Error>?
    init(server: String,port: UInt16) { connection = NWConnection(host:.init(server),port:.init(rawValue:port)!,using:.udp) }
    func exchange(_ packet: Data) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); if done { lock.unlock(); continuation.resume(throwing:CancellationError()); return }; self.continuation = continuation; lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        connection.send(content:packet,completion:.contentProcessed { [weak self] error in
                            guard let self else { return }; if error != nil { finish(.failure(SourceNetworkError.unavailable)); return }
                            connection.receiveMessage { [weak self] data,_,_,error in guard let self else { return }; if let data,error == nil { finish(.success(data)) } else { finish(.failure(SourceNetworkError.response)) } }
                        })
                    case .failed: finish(.failure(SourceNetworkError.unavailable))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                queue.asyncAfter(deadline:.now() + 2) { [weak self] in self?.finish(.failure(SourceNetworkError.timedOut)) }
                connection.start(queue:queue)
            }
        },onCancel:{self.finish(.failure(CancellationError()))})
    }
    private func finish(_ result: Result<Data,Error>) {
        lock.lock(); guard !done else { lock.unlock(); return }; done = true; let continuation = continuation; self.continuation = nil; lock.unlock()
        connection.cancel(); continuation?.resume(with:result)
    }
}
actor SourceDNSResolver {
    private var cache: [String:(String,Date)] = [:]
    func resolve(host: String,server: String,port: UInt16) async throws -> String {
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return host }
        let key = host + ":" + server + ":" + String(port)
        if let entry = cache[key],entry.1 > Date() { return entry.0 }
        var last: Error = SourceNetworkError.response
        for type: UInt16 in [1,28] {
            do {
                try Task.checkCancellation(); let id = UInt16.random(in:0...UInt16.max),query = try DNSWire.query(host:host,type:type,id:id)
                let bytes = try await DNSDatagram(server:server,port:port).exchange(query); try Task.checkCancellation()
                let answers = try DNSWire.answers(bytes,host:host,type:type,id:id)
                if let answer = answers.first { cache[key] = (answer.address,Date().addingTimeInterval(Double(answer.ttl))); if cache.count > 100 { cache = [key:cache[key]!] }; return answer.address }
            } catch is CancellationError { throw CancellationError() } catch { last = error }
        }
        throw last
    }
}
