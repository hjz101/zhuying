import XCTest
@testable import Yueshan

private actor ExtractionSourceTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        let html: String
        switch request.url!.path {
        case "/search": html = "<article data-id='book1'><h2>原创山海</h2><em>原创作者</em></article><span class='next'>2</span>"
        case "/books/book1": html = "<h1>原创山海</h1><div class='summary'>真实解析流程的原创样本。</div>"
        case "/books/book1/chapters": html = "<a data-cid='cA'>第一章</a><a data-cid='cB'>第二章</a>"
        default: html = "<main><p>从真实解析器得到的原创正文。</p><p>星光照进山谷。</p></main>"
        }
        return (Data(html.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/html; charset=utf-8"])!)
    }
}
final class ExtractionSourceTests: XCTestCase {
    func testVersionedHTMLSourceExecutesSearchDetailsCatalogAndBodyWithStableIDs() async throws {
        let search = NativeExtractionSet.Items(rows:.init(kind:.css,expression:"article",projection:.html),id:.init(kind:.css,expression:"article",projection:.attribute,attribute:"data-id"),title:.init(kind:.css,expression:"h2"),author:.init(kind:.css,expression:"em"))
        let catalog = NativeExtractionSet.Items(rows:.init(kind:.css,expression:"a",projection:.html),id:.init(kind:.css,expression:"a",projection:.attribute,attribute:"data-cid"),title:.init(kind:.css,expression:"a"))
        let extraction = NativeExtractionSet(search:search,nextPage:.init(kind:.css,expression:".next"),detailTitle:.init(kind:.xpath,expression:"//h1"),detailSummary:.init(kind:.css,expression:".summary"),catalog:catalog,paragraphs:.init(kind:.css,expression:"main p"))
        var routes = NativeSourceRules.example; routes.extraction = extraction
        let json: [String:Any] = ["adapter":"extract-v1","endpoints":try JSONSerialization.jsonObject(with:JSONEncoder().encode(routes)),"name":"原创 HTML","url":"https://html.test"]
        let imported = try SourcePackages.parse(JSONSerialization.data(withJSONObject:json),existing:[])
        let source = try XCTUnwrap(imported.sources.first),transport = ExtractionSourceTransport(),adapter = try ExtractionBookSource(source:source,transport:transport)
        XCTAssertTrue(source.detail.contains("解析规则"))
        let page = try await adapter.search(query:"山海&原创",page:1); XCTAssertEqual(page.nextPage,2); XCTAssertEqual(page.books.first?.title,"原创山海")
        let book = try await adapter.details(for:page.books[0]); XCTAssertEqual(book.summary,"真实解析流程的原创样本。")
        let chapters = try await adapter.chapters(for:book); XCTAssertEqual(chapters.map(\.nativeChapterID),["cA","cB"])
        let document = try await adapter.document(for:chapters[1],book:book); XCTAssertEqual(document.paragraphs.map(\.text),["从真实解析器得到的原创正文。","星光照进山谷。"])
        let requests = await transport.requests; XCTAssertEqual(requests.count,4); XCTAssertTrue(requests.allSatisfy{$0.url?.host == "html.test" && $0.httpMethod == "GET" && $0.value(forHTTPHeaderField:"X-Api-Key") == nil})
        let query = URLComponents(url:requests[0].url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "q"})?.value; XCTAssertEqual(query,"山海&原创")
        let saved = try SourcePackages.parse(SourcePackages.export([source]),existing:[]); XCTAssertEqual(try SourcePackages.rules(saved.sources[0]).extraction,extraction)
    }
}
