import XCTest
@testable import Yueshan

private actor CommentTransportProbe: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        let json: Any
        if request.url!.path == "/catalog" { json = ["code":200,"data":[["title":"第一章","cid":0,"url":"item_id=901&other=1"]]] }
        else { json = ["code":0,"data":["list":[["paragraph_id":"0","comment_count":3,"hot":1],["paragraph_id":"1","comment_count":2]]]] }
        return (try JSONSerialization.data(withJSONObject:json),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
final class SourceCommentTests: XCTestCase {
    private let credential = ShushanCredential(host:URL(string:"https://source.test")!,apiKey:"synthetic-only",nickname:"test",deviceID:nil)
    private func book() -> LibraryBookRecord { .init(id:"remote-comment",title:"原创测试",author:"原创",summary:"",source:.init(sourceID:"shushan",nativeBookID:"local-binding",provider:"番茄小说",bookURL:"https://source.test/book",remoteBookID:"100",origin:"https://source.test"),addedAt:Date()) }
    func testBareCatalogQueryPreservesNativeChapterIDForContentAndComments() async throws {
        let transport = CommentTransportProbe(),source = ShushanBookSource(credential:credential,transport:transport),book = book()
        let chapters = try await source.chapters(for:book)
        XCTAssertEqual(chapters[0].requestParameters["item_id"],"901")
        let context = try XCTUnwrap(ShushanCommentContext(book:book,chapter:chapters[0]))
        XCTAssertEqual(context.chapterID,"901"); XCTAssertEqual(context.bookID,"100")
        let counts = try await ShushanCommentsClient(credential:credential,transport:transport).counts(context)
        XCTAssertEqual(counts.map(\.count),[3,2])
        let request = await transport.requests.last!
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-Api-Key"),credential.authenticationHeader)
        XCTAssertFalse(request.url!.absoluteString.contains("synthetic"))
    }
    func testParagraphMappingSkipsImagesAndRejectsPositionalCidAndWrongOrigins() async throws {
        let book = book(),chapter = ChapterRecord(id:"c",bookID:book.id,nativeChapterID:"item_id=901",title:"章",order:0,access:.readable,requestParameters:["cid":"0","item_id":"901"])
        let context = try XCTUnwrap(ShushanCommentContext(book:book,chapter:chapter))
        let document = ChapterDocument(chapterID:"c",paragraphs:["原始正文。","<img src='image.png'>","下一段正文。"])
        let rows: [SourceParagraphCount] = [.init(nativeID:"0",count:3,hot:false),.init(nativeID:"1",count:5,hot:true),.init(nativeID:"999",count:10,hot:false)]
        let mapped = ShushanCommentsClient.map(rows,context:context,document:document)
        XCTAssertEqual(mapped[document.paragraphs[2].id]?.count,5); XCTAssertEqual(mapped.count,2)
        let positional = ChapterRecord(id:"c2",bookID:book.id,nativeChapterID:"position-only",title:"章",order:0,access:.readable,requestParameters:["cid":"0"])
        XCTAssertNil(ShushanCommentContext(book:book,chapter:positional))
        let transport = CommentTransportProbe(),wrong = ShushanCredential(host:URL(string:"https://other.test")!,apiKey:"synthetic-only",nickname:"test",deviceID:nil)
        do { _ = try await ShushanCommentsClient(credential:wrong,transport:transport).counts(context); XCTFail("Origin changed") } catch ContentFailure.sourceDisabled {}
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testVerifiedPageContractCursorAndLiteralCommentText() throws {
        func response(cursor: String,hasMore: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject:["code":0,"data":["para_src_content":"原始正文。","data_list":[["comment":["comment_id":"900","common":["content":["text":"<script>literal text</script>"],"user_info":["base_info":["user_name":"原创读者"]],"create_timestamp":1700000000],"stat":["digg_count":3]]]]],"common_list_info":["cursor":cursor,"has_more":hasMore]])
        }
        let page = try ShushanCommentsClient.decodePage(response(cursor:"20",hasMore:true),currentCursor:"0")
        var direct = try JSONSerialization.jsonObject(with:response(cursor:"20",hasMore:true)) as! [String:Any]; direct.removeValue(forKey:"code")
        XCTAssertEqual(try ShushanCommentsClient.decodePage(JSONSerialization.data(withJSONObject:direct),currentCursor:"0"),page)
        XCTAssertEqual(page.nextCursor,"20"); XCTAssertEqual(page.comments.first?.text,"<script>literal text</script>"); XCTAssertEqual(page.comments.first?.likes,3)
        XCTAssertThrowsError(try ShushanCommentsClient.decodePage(response(cursor:"0",hasMore:true),currentCursor:"0"))
        XCTAssertNil(try ShushanCommentsClient.decodePage(response(cursor:"0",hasMore:false),currentCursor:"0").nextCursor)
        XCTAssertTrue(ShushanCommentsClient.sameParagraph("<p>原始&nbsp;正文。</p>","原始正文。"))
        XCTAssertFalse(ShushanCommentsClient.sameParagraph("另一段正文。","原始正文。"))
        XCTAssertThrowsError(try ShushanCommentsClient.decodePage(Data("<html>login</html>".utf8),currentCursor:"0"))
    }
    func testCommentCacheSeparatesAccountBodyVersionExpiresAndClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let cache = SourceCommentCache(directory:root),chapter = ChapterRecord(id:"c",bookID:book().id,nativeChapterID:"native",title:"章",order:0,access:.readable,requestParameters:["item_id":"901"])
        let context = try XCTUnwrap(ShushanCommentContext(book:book(),chapter:chapter)),client = ShushanCommentsClient(credential:credential)
        let key = SourceCommentCache.key(client:client,context:context,version:"body1"),date = Date()
        let rows = [SourceParagraphCount(nativeID:"0",count:4,hot:false)]
        do { try await cache.write(rows,key:key,now:date) } catch { XCTFail("Cache write: \(error)"); return }
        let saved = await cache.read([SourceParagraphCount].self,key:key,maximumAge:300,now:date.addingTimeInterval(200)); XCTAssertEqual(saved,rows)
        let expired = await cache.read([SourceParagraphCount].self,key:key,maximumAge:300,now:date.addingTimeInterval(400)); XCTAssertNil(expired)
        let other = ShushanCommentsClient(credential:.init(host:credential.host,apiKey:"another-synthetic-account",nickname:"test",deviceID:nil))
        XCTAssertNotEqual(key,SourceCommentCache.key(client:other,context:context,version:"body1")); XCTAssertNotEqual(key,SourceCommentCache.key(client:client,context:context,version:"body2"))
        do { try await cache.clear() } catch { XCTFail("Cache clear: \(error)"); return }
        let removed = await cache.read([SourceParagraphCount].self,key:key,maximumAge:300); XCTAssertNil(removed)
    }
    @MainActor func testRealBadgesKeepRawAnchorAndHaveNoInventedComments() throws {
        let book = try BookImporter.prepare(data:Data("第一章\n原始正文。\n下一段正文。".utf8),name:"原创.txt").book
        var settings = ReadingSettings(); settings.preferences.showCommentBubbles = true; settings.preferences.showGodComments = true
        let plain = ReaderDocument(book:book,chapter:0,settings:settings,isDemo:false),real = ReaderDocument(book:book,chapter:0,settings:settings,isDemo:false,commentCounts:[0:300])
        XCTAssertFalse(plain.text.string.contains("\u{fffc}")); XCTAssertEqual(real.text.string.filter{$0 == "\u{fffc}"}.count,1)
        XCTAssertEqual(real.anchor(at:real.index(for:.init(paragraph:1,offset:3))),.init(paragraph:1,offset:3))
        XCTAssertFalse(real.text.string.contains("这盏茶")); XCTAssertNotNil(ReaderCommentArtwork.bubble(settings:settings,count:300))
    }
}
