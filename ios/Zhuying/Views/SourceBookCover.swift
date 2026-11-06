import SwiftUI

/// Uses the selected source's route and isolated cookies, with the existing
/// native cover as a fallback for missing or invalid remote images.
struct SourceBookCover: View {
    let record: LibraryBookRecord
    let width: CGFloat
    let height: CGFloat
    @EnvironmentObject private var library: LibraryStore
    @State private var image: UIImage?
    var body: some View {
        BookCover(book: record.presentation(chapters: []), width: width)
            .frame(width: width, height: height)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: width, height: height).clipped().accessibilityHidden(true)
                }
            }
            .clipShape(.rect(cornerRadius: 5))
            .task(id: record.id + (record.coverURL ?? "") + String(library.onlineRevision)) {
                image = nil
                do {
                    let (request, transport) = try library.sourceCoverRequest(record)
                    let bytes = try await SourceCoverLoader.load(request, transport: transport)
                    try Task.checkCancellation(); image = UIImage(data: bytes)
                } catch { }
            }
    }
}

enum SourceCoverLoader {
    static func load(_ request: URLRequest, transport: any HTTPTransport) async throws -> Data {
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode), let requested = request.url, let returned = response.url,
              SourceBrowserSessions.sameOrigin(requested, returned), data.count <= 2 * 1024 * 1024 else { throw ContentFailure.invalidResponse }
        return try await Task.detached { try CoverSearchClient.normalized(data) }.value
    }
}

@MainActor extension LibraryStore {
    func sourceCoverRequest(_ book: LibraryBookRecord) throws -> (URLRequest, any HTTPTransport) {
        guard let value = book.coverURL, let url = URL(string: value), url.user == nil, url.password == nil,
              ["http", "https"].contains(url.scheme ?? ""), url.host?.isEmpty == false else { throw ContentFailure.invalidResponse }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        if let reference = book.source {
            guard var source = sources.first(where: { $0.id == reference.sourceID && $0.enabled }) else { throw ContentFailure.sourceDisabled }
            if let definition = try? SourcePackages.legadoDefinition(source) {
                let state = try legadoLoginState(for: source)
                let policy = try LegadoSourcePolicy(sourceID: source.id, declaredOrigins: definition.policy.allowedOrigins, additionalOrigins: state.allowedOrigins())
                let origin = try policy.requireOrigin(for: url)
                let cookies = try state.cookies(for: url)
                request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
                source.url = origin.absoluteString
                return (request, try requestTransport(for: source, maximumBytes: 2 * 1024 * 1024))
            }
            if let origin = try? ShushanClient.host(source.url), SourceBrowserSessions.sameOrigin(url, origin) {
                return (request, try sourceTransport(for: source, maximumBytes: 2 * 1024 * 1024))
            }
        }
        // Public artwork outside a configured source never inherits login headers.
        guard url.scheme == "https" else { throw ContentFailure.sourceDisabled }
        return (request, SourceHTTPTransport(maximumResponseBytes: 2 * 1024 * 1024))
    }
}
