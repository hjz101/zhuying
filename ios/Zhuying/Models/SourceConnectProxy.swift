import Foundation
import Network

/// A loopback-only CONNECT tunnel. URLSession retains the original HTTPS URL,
/// SNI and certificate validation; this class never decrypts TLS or accepts trust.
final class SourceConnectProxy: @unchecked Sendable {
    private let listener: NWListener
    private let origin: URL
    private let profile: SourceNetworkProfile
    private let resolver = SourceDNSResolver()
    private let queue = DispatchQueue(label:"com.zhuying.source-connect")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var tunnels: [UUID:ConnectTunnel] = [:]
    private var accepted = 0
    init(origin: URL,profile: SourceNetworkProfile) throws {
        try profile.validate(); guard origin.scheme == "https",origin.host != nil,[.fixedIP,.dns].contains(profile.mode) else { throw SourceNetworkError.invalid }
        self.origin = origin; self.profile = profile
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener = try NWListener(using:parameters); queue.setSpecific(key:queueKey,value:true)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self,tunnels.count < 4 else { connection.cancel(); return }
            let id = UUID(),tunnel = ConnectTunnel(client:connection,origin:origin,profile:profile,resolver:resolver,queue:queue) { [weak self] in self?.tunnels.removeValue(forKey:id) }
            accepted += 1
            tunnels[id] = tunnel; tunnel.start()
        }
    }
    func start() async throws -> NWEndpoint.Port {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                var finished = false
                func finish(_ result: Result<NWEndpoint.Port,Error>) { guard !finished else { return }; finished = true; continuation.resume(with:result) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { finish(.failure(SourceNetworkError.unavailable)); return }
                    switch state { case .ready: if let port = listener.port { finish(.success(port)) } else { finish(.failure(SourceNetworkError.unavailable)) }
                    case .failed: finish(.failure(SourceNetworkError.unavailable))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break }
                }
                queue.asyncAfter(deadline:.now() + 3) { [weak self] in if !finished { self?.listener.cancel(); finish(.failure(SourceNetworkError.timedOut)) } }
                listener.start(queue:queue)
            }
        },onCancel:{self.listener.cancel()})
    }
    func stop() {
        listener.cancel()
        let body = { [self] in let values = Array(tunnels.values); tunnels = [:]; values.forEach{$0.close()} }
        if DispatchQueue.getSpecific(key:queueKey) == true { body() } else { queue.sync(execute:body) }
    }
    func connectionCount() -> Int { if DispatchQueue.getSpecific(key:queueKey) == true { return accepted }; return queue.sync { accepted } }
    deinit { listener.cancel() }
}

private final class ConnectTunnel: @unchecked Sendable {
    let client: NWConnection
    let origin: URL
    let profile: SourceNetworkProfile
    let resolver: SourceDNSResolver
    let queue: DispatchQueue
    let onClose: () -> Void
    private var remote: NWConnection?
    private var header = Data()
    private var lookup: Task<Void,Never>?
    private var deadline: DispatchWorkItem?
    private var closed = false
    private var total = 0
    private var ended = 0
    init(client: NWConnection,origin: URL,profile: SourceNetworkProfile,resolver: SourceDNSResolver,queue: DispatchQueue,onClose: @escaping () -> Void) { self.client = client; self.origin = origin; self.profile = profile; self.resolver = resolver; self.queue = queue; self.onClose = onClose }
    func start() {
        bump(15)
        client.stateUpdateHandler = { [weak self] state in guard let self else { return }; switch state { case .ready: receiveHeader(); case .failed,.cancelled: close(); default: break } }
        client.start(queue:queue)
    }
    private func receiveHeader() {
        client.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,complete,error in
            guard let self,!closed else { return }
            guard let data,error == nil,header.count + data.count <= 8192 else { close(); return }; header.append(data)
            guard let end = header.range(of:Data("\r\n\r\n".utf8)) else { if complete { close() } else { receiveHeader() }; return }
            let bytes = header.prefix(upTo:end.lowerBound),extra = header.suffix(from:end.upperBound)
            guard let text = String(data:bytes,encoding:.utf8),let line = text.components(separatedBy:"\r\n").first else { close(); return }
            let parts = line.split(separator:" ")
            guard parts.count == 3,parts[0] == "CONNECT",parts[2] == "HTTP/1.1",let target = URL(string:"https://" + parts[1]),target.host == origin.host,(target.port ?? 443) == (origin.port ?? 443),target.user == nil,target.password == nil else { close(); return }
            header = Data(); connect(extra:Data(extra))
        }
    }
    private func connect(extra: Data) {
        let hostname = origin.host!.trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        lookup = Task { [weak self] in
            guard let self else { return }
            do {
                let address: String
                if profile.mode == .fixedIP { address = profile.server } else { address = try await resolver.resolve(host:hostname,server:profile.server,port:UInt16(profile.port)) }
                try Task.checkCancellation()
                queue.async { [weak self] in self?.open(address,extra:extra) }
            } catch { queue.async { [weak self] in self?.close() } }
        }
    }
    private func open(_ address: String,extra: Data) {
        guard !closed else { return }
        let remote = NWConnection(host:.init(address),port:.init(rawValue:UInt16(origin.port ?? 443))!,using:.tcp); self.remote = remote
        remote.stateUpdateHandler = { [weak self] state in
            guard let self,!closed else { return }
            switch state {
            case .ready:
                client.send(content:Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),completion:.contentProcessed { [weak self] error in
                    guard let self,!closed,error == nil else { self?.close(); return }
                    if !extra.isEmpty { remote.send(content:extra,completion:.contentProcessed { [weak self] error in if error != nil { self?.close() } }) }
                    pipe(client,to:remote); pipe(remote,to:client)
                })
            case .failed,.cancelled: close()
            default: break
            }
        }
        remote.start(queue:queue)
    }
    private func pipe(_ from: NWConnection,to: NWConnection) {
        guard !closed else { return }
        from.receive(minimumIncompleteLength:1,maximumLength:64 * 1024) { [weak self] data,_,complete,error in
            guard let self,!closed else { return }
            if let data,!data.isEmpty {
                total += data.count; guard total <= 64 * 1024 * 1024 else { close(); return }; bump(30)
                to.send(content:data,completion:.contentProcessed { [weak self] sendError in guard let self else { return }; if sendError != nil || error != nil { close() } else if complete { finishDirection(to) } else { pipe(from,to:to) } })
            } else if error != nil { close() } else if complete { finishDirection(to) } else { pipe(from,to:to) }
        }
    }
    private func finishDirection(_ connection: NWConnection) {
        connection.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { [weak self] error in guard let self else { return }; ended += 1; if error != nil || ended >= 2 { close() } })
    }
    private func bump(_ seconds: Double) { deadline?.cancel(); let job = DispatchWorkItem { [weak self] in self?.close() }; deadline = job; queue.asyncAfter(deadline:.now() + seconds,execute:job) }
    func close() { guard !closed else { return }; closed = true; deadline?.cancel(); lookup?.cancel(); client.cancel(); remote?.cancel(); onClose() }
    deinit { client.cancel(); remote?.cancel(); deadline?.cancel(); lookup?.cancel() }
}

actor SourceNetworkTransport: HTTPTransport {
    let origin: URL
    let profile: SourceNetworkProfile
    private var proxy: SourceConnectProxy?
    private var transport: SourceHTTPTransport?
    private var setup: Task<SourceHTTPTransport,Error>?
    private var routing: [ProxyConfiguration] = []
    private let maximumBytes: Int
    init(origin: URL,profile: SourceNetworkProfile,maximumBytes: Int = 20 * 1024 * 1024) throws {
        try profile.validate(); guard ["http", "https"].contains(origin.scheme ?? ""),
              (origin.scheme == "https" || profile.mode == .system || profile.mode == .proxy),origin.host?.isEmpty == false,origin.user == nil,origin.password == nil,(1...20 * 1024 * 1024).contains(maximumBytes) else { throw SourceNetworkError.invalid }
        self.origin = origin; self.profile = profile; self.maximumBytes = maximumBytes
    }
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard let url = request.url,SourceBrowserSessions.sameOrigin(url,origin) else { throw ContentFailure.sourceDisabled }
        let transport = try await configured(); return try await transport.send(request)
    }
    func proxyConfigurations() async throws -> [ProxyConfiguration] { _ = try await configured(); return routing }
    func tunnelCount() -> Int { proxy?.connectionCount() ?? 0 }
    private func configured() async throws -> SourceHTTPTransport {
        if let transport { return transport }; if let setup { return try await setup.value }
        let origin = origin,profile = profile
        let work = Task { () throws -> SourceHTTPTransport in
            let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
            switch profile.mode {
            case .system: break
            case .proxy: configuration.proxyConfigurations = [.init(httpCONNECTProxy:.hostPort(host:.init(profile.server),port:.init(rawValue:UInt16(profile.port))!))]
            case .fixedIP,.dns:
                let proxy = try SourceConnectProxy(origin:origin,profile:profile); self.proxy = proxy
                let port = try await proxy.start(); configuration.proxyConfigurations = [.init(httpCONNECTProxy:.hostPort(host:"127.0.0.1",port:port))]
            }
            if !configuration.proxyConfigurations.isEmpty {
                var route = configuration.proxyConfigurations[0]; route.allowFailover = false; route.matchDomains = [origin.host!]; configuration.proxyConfigurations = [route]
            }
            routing = configuration.proxyConfigurations
            return SourceHTTPTransport(makeSession:{ URLSession(configuration:configuration,delegate:SourceRedirectPolicy(),delegateQueue:nil) },maximumResponseBytes:maximumBytes)
        }
        setup = work
        do { let value = try await work.value; transport = value; setup = nil; return value }
        catch { proxy?.stop(); proxy = nil; setup = nil; throw error }
    }
    deinit { proxy?.stop(); setup?.cancel() }
}
actor ProfiledAccountTransport: HTTPTransport {
    let profiles: SourceNetworkProfiles
    private var saved: (String,SourceNetworkTransport)?
    init(profiles: SourceNetworkProfiles) { self.profiles = profiles }
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard let url = request.url,var parts = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw SourceNetworkError.invalid }; parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let origin = parts.url else { throw SourceNetworkError.invalid }
        let profile = try await profiles.profile(sourceID:"shushan",origin:origin),key = origin.absoluteString + FileResourceStore.digest(try JSONEncoder().encode(profile))
        let transport: SourceNetworkTransport
        if let saved,saved.0 == key { transport = saved.1 } else { transport = try SourceNetworkTransport(origin:origin,profile:profile,maximumBytes:2 * 1024 * 1024); saved = (key,transport) }
        return try await transport.send(request)
    }
}
