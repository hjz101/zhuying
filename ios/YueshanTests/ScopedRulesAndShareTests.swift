import XCTest
import UIKit
@testable import Yueshan

final class ScopedRulesAndShareTests: XCTestCase {
    func testBookRulesOverrideGlobalOnlyForTheirOwnBookWithoutChangingTextOrOffsets() throws {
        let book = try BookImporter.prepare(data:Data("第一章 范围\n山海👩🏽‍🚀同一段正文。".utf8),name:"范围.txt").book
        let global = ReaderStyleRule(name:"全局",match:"关键词",pattern:"山海",color:0x112233,enabled:true)
        let local = ReaderStyleRule(name:"本书",match:"关键词",pattern:"山海",color:0x994455,enabled:true,scope:"当前书籍",bookID:book.id)
        var settings = ReadingSettings(); settings.preferences.rules = [global,local]; settings.preferences.showCommentBubbles = false
        let document = ReaderDocument(book:book,chapter:0,settings:settings,isDemo:false)
        var onlyGlobal = settings; onlyGlobal.preferences.rules = [global]
        let baseline = ReaderDocument(book:book,chapter:0,settings:onlyGlobal,isDemo:false)
        XCTAssertEqual(document.text.string,baseline.text.string); XCTAssertEqual(document.paragraphRanges,baseline.paragraphRanges)
        let range = (document.text.string as NSString).range(of:"山海")
        XCTAssertEqual(document.text.attribute(.foregroundColor,at:range.location,effectiveRange:nil) as? UIColor,UIColor(red:0x99/255.0,green:0x44/255.0,blue:0x55/255.0,alpha:1))
        XCTAssertEqual(ReaderStyleRule.effective([global,local],bookID:"another",sourceID:nil).map(\.id),[global.id])
    }
    func testBoundSourceScopeAndLegacyUnboundRulesSurviveNormalizationAndRestartSafely() throws {
        var settings = ReadingSettings()
        let bound = ReaderStyleRule(name:"来源",match:"关键词",pattern:"星光",enabled:true,scope:"当前书源",sourceID:"my-source")
        settings.preferences.rules = [bound,.init(name:"旧规则",enabled:true,scope:"当前书籍")]; settings.preferences.normalize()
        let reopened = try JSONDecoder().decode(ReadingSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertTrue(reopened.preferences.rules[0].enabled); XCTAssertFalse(reopened.preferences.rules[1].enabled)
        XCTAssertEqual(ReaderStyleRule.effective(reopened.preferences.rules,bookID:"book",sourceID:"my-source").map(\.id),[bound.id])
        XCTAssertTrue(ReaderStyleRule.effective([bound],bookID:"book",sourceID:"other-source").isEmpty)
        XCTAssertEqual(try bound.ranges(in:"星光👩🏽‍🚀星光").count,2)
    }
    func testSharingRoutingDecodesOnceSeparatesKindsAndNeverAcceptsCredentialsOrUnknownDialects() throws {
        for id in ["links","details","contents","reading"] { XCTAssertNil(ProductionCapabilities.badge(for:id)) }
        var url = URLComponents(); url.scheme = "yueshan"; url.host = "import"; url.queryItems = [.init(name:"kind",value:"source"),.init(name:"url",value:"https://reader.test/source.json?edition=1")]
        let first = try ShareImportRequest.parse(url.url!), second = try ShareImportRequest.parse(url.url!)
        XCTAssertEqual(first.id,second.id); XCTAssertEqual(first.kind,.source); XCTAssertEqual(first.url.query,"edition=1")
        for text in ["yuedu://booksource?url=https://reader.test","yueshan://import?kind=source&kind=theme&url=https://reader.test","yueshan://import?kind=script&url=https://reader.test","yueshan://import?kind=file&url=http://reader.test","yueshan://import?kind=file&url=https://user:pass@reader.test","yueshan://import?kind=theme&url=https://reader.test?token=secret"] {
            XCTAssertThrowsError(try ShareImportRequest.parse(URL(string:text)!))
        }
        XCTAssertEqual(try ShareImportRequest.parse(URL(fileURLWithPath:"/tmp/原创.epub")).kind,.file)
    }
}
