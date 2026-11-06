import XCTest
import Network
@testable import Zhuying

private actor LegacyHTTPFixture: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let bodies = ["/health": "当前服务器可用", "/search": #"{"books":[{"title":"竹影原创","url":"/book/one"}]}"#,
                      "/book/one": #"{"name":"竹影原创","toc":"/toc/one"}"#,
                      "/toc/one": #"{"chapters":[{"name":"第一章","url":"/chapter/one"}]}"#,
                      "/chapter/one": #"{"text":"竹林的清晨。\n山间的新雨。"}"#]
        return (Data(try XCTUnwrap(bodies[url.path]).utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

private final class HTTPStateVault: LegadoSecretVault {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ data: Data, id: String) throws { lock.lock(); defer { lock.unlock() }; values[id] = data }
    func remove(id: String) throws { lock.lock(); defer { lock.unlock() }; values[id] = nil }
}

final class LegadoHTTPCompatibilityTests: XCTestCase {
    private func source() throws -> DemoSource {
        let row: [String: Any] = ["bookSourceUrl": "竹影原创HTTP聚合", "jsLib": "var server='http://127.0.0.1:51234';",
            "searchUrl": "@js:server+'/search?q='+java.encodeURI(key)",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.title", "bookUrl": "$.url"],
            "ruleBookInfo": ["name": "$.name", "tocUrl": "$.toc"],
            "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"],
            "ruleContent": ["content": "$.text"]]
        var source = DemoSource(id: "http-original", name: "竹影原创HTTP回归", detail: "原创离线fixture", url: "竹影原创HTTP聚合")
        source.configuration = try JSONSerialization.data(withJSONObject: row)
        return source
    }
    func testCurrentServerActionAndFullReadingPipelineUseDeclaredHTTPRoute() async throws {
        let transport = LegacyHTTPFixture(), adapter = try LegadoBookSource(source: source(), transport: transport)
        let login = try await adapter.login(action: "java.toast(java.ajax(server+'/health'))", values: [:])
        XCTAssertEqual(login.message, "当前服务器可用")
        let page = try await adapter.search(query: "竹影", page: 1)
        let book = try await adapter.details(for: XCTUnwrap(page.books.first))
        let catalog = try await adapter.chapters(for: book)
        let document = try await adapter.document(for: XCTUnwrap(catalog.first), book: book)
        XCTAssertEqual(book.title, "竹影原创")
        XCTAssertEqual(document.paragraphs.map(\.text), ["竹林的清晨。", "山间的新雨。"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "http" && $0.url?.port == 51234 })
    }
    func testHTTPOriginsKeepSchemePortAndCredentialsIsolated() throws {
        let policy = try LegadoSourceDefinition.decode(source()).policy
        XCTAssertTrue(policy.allows(URL(string: "http://127.0.0.1:51234/health")!))
        for address in ["https://127.0.0.1:51234/", "http://127.0.0.1:51235/", "http://other.test/", "http://reader:secret@127.0.0.1:51234/"] {
            XCTAssertThrowsError(try policy.requireOrigin(for: URL(string: address)!))
        }
        XCTAssertEqual(try LegadoSourcePolicy.canonicalOrigin(URL(string: "http://BOOKS.test:80/a")!).absoluteString, "http://books.test/")
        XCTAssertEqual(try LegadoBrowserRequest.origin(URL(string: "http://BOOKS.test:80/login")!).absoluteString, "http://books.test/")
        XCTAssertEqual(try LegadoBrowserRequest.origin(URL(string: "https://BOOKS.test:443/login")!).absoluteString, "https://books.test/")
        XCTAssertFalse(SourceBrowserSessions.sameOrigin(URL(string: "http://books.test")!, URL(string: "https://books.test")!))
        let secure = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "fixture", .domain: "books.test", .path: "/", .secure: "TRUE"]))
        XCTAssertTrue(SourceBrowserSessions.matching([secure], url: URL(string: "http://books.test/")!).isEmpty)
        XCTAssertEqual(SourceBrowserSessions.matching([secure], url: URL(string: "https://books.test/")!).count, 1)
    }
    func testPersistentCookiesRespectSecureFlagAndDoNotCrossProtocolOrPort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try LegadoPersistentState(sourceID: "http-cookie-fixture", directory: root, vault: HTTPStateVault())
        let url = URL(string: "http://books.test:51234/")!
        let plain = try XCTUnwrap(HTTPCookie(properties: [.name: "plain", .value: "fixture", .domain: "books.test", .path: "/"]))
        let secure = try XCTUnwrap(HTTPCookie(properties: [.name: "secure", .value: "fixture", .domain: "books.test", .path: "/", .secure: "TRUE"]))
        try state.setCookies([plain, secure], for: url)
        XCTAssertEqual(try state.cookies(for: url).map(\.name), ["plain"])
        XCTAssertTrue(try state.cookies(for: URL(string: "https://books.test:51234/")!).isEmpty)
        XCTAssertTrue(try state.cookies(for: URL(string: "http://books.test:51235/")!).isEmpty)
    }
    @MainActor func testDeclaredHTTPBrowserRouteDoesNotEnableTemporaryHTTPBrowsing() throws {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let origin = URL(string: "http://127.0.0.1:51234/")!, browser = NativeSourceBrowser()
        browser.configure(sourceID: "fixture", origin: origin, sessions: SourceBrowserSessions(defaults: defaults), javascript: true, allowedOrigins: [origin])
        XCTAssertTrue(browser.allowsSubframe(origin.appendingPathComponent("frame")))
        XCTAssertFalse(browser.allowsSubframe(URL(string: "http://unknown.test/frame")!))
        XCTAssertTrue(browser.allowsSubframe(URL(string: "https://public.test/frame")!))
        browser.open(origin.appendingPathComponent("login").absoluteString)
        XCTAssertNil(browser.message)
        browser.open("http://other.test/")
        XCTAssertEqual(browser.external?.host, "other.test")
        browser.close()
        XCTAssertThrowsError(try BrowserInput.url(origin.absoluteString))
        XCTAssertNoThrow(try LegadoBrowserRequest(sourceID: "fixture", url: origin, allowedOrigins: [origin]).validate())
    }
    func testNativeSystemTransportMakesActualHTTPConnection() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "com.zhuying.http-regression")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let origin = URL(string: "http://127.0.0.1:\(port)/")!, transport = try SourceNetworkTransport(origin: origin, profile: .init())
        let (body, response) = try await transport.send(URLRequest(url: origin.appendingPathComponent("health")))
        XCTAssertEqual(response.statusCode, 200); XCTAssertEqual(String(decoding: body, as: UTF8.self), "OK")
    }
}
