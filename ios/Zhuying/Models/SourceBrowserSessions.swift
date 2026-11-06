import Foundation
import WebKit

@MainActor final class SourceBrowserSessions {
    private let defaults: UserDefaults
    private var stores: [String:WKWebsiteDataStore] = [:]
    private var order: [String] = []
    init(defaults: UserDefaults) { self.defaults = defaults }
    nonisolated static func accountScope(sourceID: String, accountID: String = "default") -> String {
        accountID.isEmpty || accountID == "default" ? sourceID : sourceID + ".account." + StableContentID.make(accountID)
    }
    nonisolated static func legadoScope(sourceID: String, accountID: String, libraryProfile: String) -> String {
        "legado." + StableContentID.make(libraryProfile, sourceID, accountID)
    }
    static func scope(sourceID: String,origin: URL) -> String { StableContentID.make("browser-v1",sourceID,origin.absoluteString) }
    func store(sourceID: String,origin: URL) -> WKWebsiteDataStore {
        let originsKey = "browser.origins." + StableContentID.make(sourceID)
        var origins = Set(defaults.stringArray(forKey: originsKey) ?? [])
        if origins.insert(origin.absoluteString).inserted { defaults.set(Array(origins).sorted(), forKey: originsKey) }
        let scope = Self.scope(sourceID:sourceID,origin:origin)
        if let store = stores[scope] { order.removeAll{$0 == scope}; order.append(scope); return store }
        let key = "browser.session." + scope,id = defaults.string(forKey:key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString,forKey:key)
        let store = WKWebsiteDataStore(forIdentifier:id); stores[scope] = store; order.append(scope)
        while order.count > 8 { stores.removeValue(forKey:order.removeFirst()) }; return store
    }
    func knownOrigins(sourceID: String) -> [URL] {
        (defaults.stringArray(forKey: "browser.origins." + StableContentID.make(sourceID)) ?? []).compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme ?? "") }
    }
    func usesNativeCookies(sourceID: String,origin: URL) -> Bool { sourceID != "shushan" && defaults.bool(forKey:"browser.native-cookies." + Self.scope(sourceID:sourceID,origin:origin)) }
    func setNativeCookies(_ value: Bool,sourceID: String,origin: URL) {
        defaults.set(value && sourceID != "shushan",forKey:"browser.native-cookies." + Self.scope(sourceID:sourceID,origin:origin))
        NotificationCenter.default.post(name:.sourceBrowserSessionsChanged,object:nil)
    }
    func clear(sourceID: String,origin: URL) async {
        await store(sourceID:sourceID,origin:origin).removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast)
        NotificationCenter.default.post(name:.sourceBrowserSessionsChanged,object:nil)
    }
    func cookieHeader(sourceID: String,origin: URL,url: URL) async throws -> String? {
        guard usesNativeCookies(sourceID:sourceID,origin:origin),Self.sameOrigin(url,origin) else { return nil }
        let cookies = await store(sourceID:sourceID,origin:origin).httpCookieStore.allCookies()
        let selected = Self.matching(cookies,url:url),header = HTTPCookie.requestHeaderFields(with:selected)["Cookie"]
        guard (header?.utf8.count ?? 0) <= 16 * 1024 else { throw ContentFailure.invalidResponse }; return header
    }
    nonisolated static func sameOrigin(_ first: URL,_ second: URL) -> Bool { ["http", "https"].contains(first.scheme ?? "") && first.scheme == second.scheme && first.host?.lowercased() == second.host?.lowercased() && (first.port ?? (first.scheme == "https" ? 443 : 80)) == (second.port ?? (second.scheme == "https" ? 443 : 80)) && first.user == nil && first.password == nil && second.user == nil && second.password == nil }
    nonisolated static func matching(_ cookies: [HTTPCookie],url: URL,now: Date = Date()) -> [HTTPCookie] {
        guard ["http", "https"].contains(url.scheme ?? ""),let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased(),plain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain,path = url.path.isEmpty ? "/" : url.path
            let domainMatches = host == plain || domain.hasPrefix(".") && host.hasSuffix("." + plain)
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))
            return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate.map{$0 > now} ?? true)
        }.sorted{ $0.path.count > $1.path.count }
    }
}
extension Notification.Name { static let sourceBrowserSessionsChanged = Notification.Name("sourceBrowserSessionsChanged") }

struct BrowserSessionTransport: HTTPTransport {
    let sourceID: String
    let origin: URL
    let sessions: SourceBrowserSessions
    var base: any HTTPTransport = BoundedAudioHTTPTransport(maximumBytes:4 * 1024 * 1024)
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard let url = request.url,SourceBrowserSessions.sameOrigin(url,origin) else { throw ContentFailure.sourceDisabled }
        var request = request
        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let header = try await sessions.cookieHeader(sourceID:sourceID,origin:origin,url:url) { request.setValue(header,forHTTPHeaderField:"Cookie") }
        try Task.checkCancellation(); return try await base.send(request)
    }
}
