import XCTest
import WebKit
@testable import Yueshan

final class SourceBrowserTests: XCTestCase {
    @MainActor func testActualWebKitStoresSeparateSourcesHostsAndPreserveScopeOnRestart() async throws {
        let domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!; defer { defaults.removePersistentDomain(forName:domain) }
        let sessions = SourceBrowserSessions(defaults:defaults),origin = URL(string:"https://source.test")!
        let a = sessions.store(sourceID:"A",origin:origin),b = sessions.store(sourceID:"B",origin:origin),otherHost = sessions.store(sourceID:"A",origin:URL(string:"https://other.test")!)
        XCTAssertNotEqual(a.identifier,b.identifier); XCTAssertNotEqual(a.identifier,otherHost.identifier)
        XCTAssertEqual(SourceBrowserSessions(defaults:defaults).store(sourceID:"A",origin:origin).identifier,a.identifier)
        let first = try XCTUnwrap(HTTPCookie(properties:[.domain:"source.test",.path:"/books",.name:"reader",.value:"synthetic-A",.secure:"TRUE"])),second = try XCTUnwrap(HTTPCookie(properties:[.domain:"source.test",.path:"/",.name:"reader",.value:"synthetic-B",.secure:"TRUE"]))
        await a.httpCookieStore.setCookie(first); await b.httpCookieStore.setCookie(second)
        sessions.setNativeCookies(true,sourceID:"A",origin:origin); sessions.setNativeCookies(true,sourceID:"B",origin:origin)
        let header = try await sessions.cookieHeader(sourceID:"A",origin:origin,url:origin.appendingPathComponent("books/1")),wrongPath = try await sessions.cookieHeader(sourceID:"A",origin:origin,url:origin.appendingPathComponent("bookshelf"))
        XCTAssertTrue(header?.contains("synthetic-A") == true); XCTAssertFalse(header?.contains("synthetic-B") == true); XCTAssertTrue(wrongPath?.isEmpty ?? true)
        let cross = try await sessions.cookieHeader(sourceID:"A",origin:origin,url:URL(string:"https://other.test/books/1")!); XCTAssertNil(cross)
        await sessions.clear(sourceID:"A",origin:origin)
        let cleared = await a.httpCookieStore.allCookies(),kept = await b.httpCookieStore.allCookies(); XCTAssertTrue(cleared.isEmpty); XCTAssertEqual(kept.count,1)
        sessions.setNativeCookies(true,sourceID:"shushan",origin:origin); XCTAssertFalse(sessions.usesNativeCookies(sourceID:"shushan",origin:origin))
    }
    func testBrowserOnlyAcceptsHTTPSAndDownloadDestinationUsesSupportedBasename() throws {
        XCTAssertEqual(try BrowserInput.url("https://source.test/books?q=1").host,"source.test")
        for url in ["http://source.test","javascript:alert(1)","file:///etc/passwd","https://user:password@source.test"] { XCTAssertThrowsError(try BrowserInput.url(url)) }
        XCTAssertEqual(try BrowserInput.filename("../../原创书.epub"),"原创书.epub")
        let url = URL(string:"https://source.test/book.txt")!
        XCTAssertThrowsError(try BrowserInput.downloadFilename(response:HTTPURLResponse(url:url,statusCode:404,httpVersion:nil,headerFields:nil)!,suggested:"book.txt"))
        XCTAssertThrowsError(try BrowserInput.downloadFilename(response:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Length":"20971521"])!,suggested:"book.txt"))
        XCTAssertEqual(try BrowserInput.downloadFilename(response:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,suggested:"book.txt"),"book.txt")
        for name in ["book.js","C:\\private\\book.pdf","book.pdf\n","book"] { XCTAssertThrowsError(try BrowserInput.filename(name)) }
    }
    @MainActor func testManualNavigationKeepsHistoryContainerAndSourceChangeReleasesIt() {
        let domain = UUID().uuidString,defaults = UserDefaults(suiteName:domain)!; defer { defaults.removePersistentDomain(forName:domain) }
        let sessions = SourceBrowserSessions(defaults:defaults),browser = NativeSourceBrowser(),origin = URL(string:"https://source.test")!
        browser.configure(sourceID:"A",origin:origin,sessions:sessions,javascript:true)
        let first = browser.webView
        browser.configure(sourceID:"A",origin:origin,sessions:sessions,javascript:true); XCTAssertTrue(first === browser.webView)
        browser.open("https://other.test/page"); XCTAssertEqual(browser.external?.host,"other.test")
        browser.configure(sourceID:"B",origin:origin,sessions:sessions,javascript:true); XCTAssertFalse(first === browser.webView)
        browser.close(); XCTAssertNil(browser.webView)
    }
    func testStartupReclaimsAbandonedBrowserFilesWithoutTouchingImportedOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let downloads = root.appendingPathComponent("BrowserDownloads"),original = root.appendingPathComponent("original.txt")
        try FileManager.default.createDirectory(at:downloads.appendingPathComponent("interrupted"),withIntermediateDirectories:true)
        try Data("partial".utf8).write(to:downloads.appendingPathComponent("interrupted/book.txt")); try Data("original".utf8).write(to:original)
        try BrowserDownloadFiles.discardAbandoned(directory:downloads); try BrowserDownloadFiles.discardAbandoned(directory:downloads)
        XCTAssertFalse(FileManager.default.fileExists(atPath:downloads.path)); XCTAssertEqual(try String(contentsOf:original,encoding:.utf8),"original")
    }

}
