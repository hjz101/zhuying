import XCTest
@testable import Yueshan

private final class ImportDownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var observer: (() -> Void)?
    static func observeStart(_ value: (() -> Void)?) { lock.lock(); observer = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "import.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var headers = ["Content-Disposition": "attachment; filename=download.txt", "Content-Type": "text/plain; charset=utf-8"]
        if path == "/declared-oversize" { headers["Content-Length"] = "1000" }
        if path == "/html" { headers["Content-Type"] = "text/html" }
        if path == "/source.json" { headers["Content-Type"] = "application/json" }
        if path == "/book.epub" { headers["Content-Type"] = "application/epub+zip"; headers["Content-Disposition"] = "attachment; filename=book.epub" }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/error" ? 503 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/slow" {
            Self.lock.lock(); let observer = Self.observer; Self.lock.unlock(); observer?()
            return
        }
        var data = path == "/stream-oversize" ? Data(repeating: 65, count: 1000) : Data("第一章 下载\n来自真实 URLSession 字节流的正文。".utf8)
        if path == "/source.json" { data = Data("{\"name\":\"链接书源\",\"url\":\"https://source.test\"}".utf8) }
        if path == "/book.epub" { data = try! Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/reflow-story.epub")) }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BookImportDownloadTests: XCTestCase {
    func testSourceJSONAndEPUBDirectLinksUseTheirActualMIMETypesAndBoundedParser() async throws {
        let configuration: @Sendable () -> URLSessionConfiguration = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ImportDownloadProtocol.self]; return c }
        let json = try await BoundedBookDownloader(format:.sourceJSON,configuration:configuration).fetch(URL(string:"https://import.example.test/source.json")!)
        XCTAssertEqual(try SourcePackages.parse(json.data,existing:[]).sources.first?.name,"链接书源")
        XCTAssertEqual(BoundedBookDownloader(format:.sourceJSON).maximumBytes,5 * 1024 * 1024)
        let epub = try await BookImporter.load(.remote(URL(string:"https://import.example.test/book.epub")!),encoding:.automatic,downloader:BoundedBookDownloader(configuration:configuration))
        XCTAssertEqual(epub.book.title,"山间来信"); XCTAssertEqual(epub.book.chapters.count,2)
    }
    private func downloader(limit: Int = 256) -> BoundedBookDownloader {
        .init(maximumBytes: limit, configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImportDownloadProtocol.self]
            return configuration
        })
    }
    func testHTTPSResponseStreamsIntoActualParserAndRetainsSuggestedFilename() async throws {
        let prepared = try await BookImporter.load(.remote(URL(string: "https://import.example.test/book")!), encoding: .automatic, downloader: downloader())
        XCTAssertEqual(prepared.book.title, "download")
        XCTAssertEqual(prepared.book.chapters, ["第一章 下载"])
        XCTAssertEqual(prepared.book.content, [["来自真实 URLSession 字节流的正文。"]])
    }
    func testKnownAndStreamingOversizeAndHTTPFailureAreRejected() async throws {
        for path in ["declared-oversize", "stream-oversize", "error", "html"] {
            do { _ = try await downloader(limit: 128).fetch(URL(string: "https://import.example.test/\(path)")!); XCTFail("Must reject \(path)") }
            catch { XCTAssertTrue(error is BookImportError) }
        }
        XCTAssertThrowsError(try BookImporter.remoteURL("https://user:password@example.test/book.txt"))
    }
    func testCancellationStopsAnInFlightURLSessionStream() async throws {
        let started = expectation(description: "Response started")
        ImportDownloadProtocol.observeStart { started.fulfill() }
        defer { ImportDownloadProtocol.observeStart(nil) }
        let downloader = downloader()
        let task = Task { try await downloader.fetch(URL(string: "https://import.example.test/slow")!) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download cannot return content") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}
