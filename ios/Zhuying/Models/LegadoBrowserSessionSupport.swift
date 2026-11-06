import Foundation
import WebKit

@MainActor extension LibraryStore {
    func seedLegadoBrowserCookies(source: DemoSource, state: LegadoPersistentState, url: URL) async throws {
        let origin = try LegadoSourcePolicy.canonicalOrigin(url)
        let scope = SourceBrowserSessions.legadoScope(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile)
        let store = browserSessions.store(sourceID: scope, origin: origin).httpCookieStore
        // The protected source state is authoritative. Never resurrect an old
        // WebKit login after logout or an account switch.
        for cookie in await store.allCookies() {
            var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false); parts?.path = cookie.path
            if parts?.url.map({ !SourceBrowserSessions.matching([cookie], url: $0).isEmpty }) == true { await store.deleteCookie(cookie) }
        }
        var seeded = Set<String>()
        for cookie in try state.cookies(for: url) + state.cookies(for: origin) {
            let key = StableContentID.make(cookie.domain, cookie.path, cookie.name)
            if seeded.insert(key).inserted { await store.setCookie(cookie) }
        }
        try Task.checkCancellation()
    }
    func clearLegadoBrowserSessions(source: DemoSource, state: LegadoPersistentState) async throws {
        let scope = SourceBrowserSessions.legadoScope(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile)
        let declared = try LegadoSourceDefinition.decode(source).policy.allowedOrigins
        let origins = Set(try declared + state.allowedOrigins() + browserSessions.knownOrigins(sourceID: scope))
        for origin in origins { await browserSessions.clear(sourceID: scope, origin: origin); try Task.checkCancellation() }
    }
}
