import XCTest
import WebKit
@testable import Zhuying

@MainActor
final class ThemeAssetsTests: XCTestCase {
    private var demo: FeatureDemoStore!
    override func setUp() async throws { demo = FeatureDemoStore() }

    func testBundledResourcesHaveActualCSSAndSVGAndCorrectAssociations() {
        let paper = demo.themes.first { $0.id == "paper" }!
        XCTAssertEqual(demo.themeAssets(paper, kind: .title).count, 2)
        XCTAssertEqual(demo.themeAssets(paper, kind: .bubble).count, 2)
        XCTAssertTrue(demo.themes.first { $0.id == "white" }!.titleStyleIDs.isEmpty)
        for asset in demo.themeAssets { XCTAssertTrue(ThemeAssetValidator.isValid(asset.content, kind: asset.kind), asset.id) }
        for theme in demo.themes {
            for id in theme.titleStyleIDs { XCTAssertEqual(demo.themeAssets.first { $0.id == id }?.sourceThemeID, theme.id) }
            for id in theme.bubbleStyleIDs { XCTAssertEqual(demo.themeAssets.first { $0.id == id }?.kind, .bubble) }
        }
    }

    func testImportCountsBundleAssetsAndStandaloneAssetsAndDeduplicates() throws {
        let first = try demo.importThemeData(ThemeStyleSamples.importData)
        XCTAssertEqual(first, .init(added: 2, duplicates: 1, invalid: 1, titlesAdded: 3, bubblesAdded: 3))
        let cinnamon = demo.themes.first { $0.id == "cinnamon" }!
        XCTAssertEqual(cinnamon.titleStyleIDs, ["cinnamon:title:main"])
        XCTAssertEqual(cinnamon.bubbleStyleIDs, ["cinnamon:bubble:main"])
        XCTAssertTrue(demo.themeAssets.contains { $0.sourceThemeID == nil && $0.kind == .bubble })
        XCTAssertEqual(demo.activeThemeID, "paper")
        let count = demo.themeAssets.count
        XCTAssertEqual(try demo.importThemeData(ThemeStyleSamples.importData), .init(added: 0, duplicates: 5, invalid: 1))
        XCTAssertEqual(demo.themeAssets.count, count)
    }

    func testAssetsAreNamespacedAndInvalidAttachmentsDoNotBecomeNormalPreviews() throws {
        let data = try JSONSerialization.data(withJSONObject: ["themes": [
            ["id": "one", "name": "一号", "background": "#FFFFFF", "ink": "#000000", "accent": "#112233",
             "chapterTitles": [["id": "main", "name": "标题", "css": ThemeStyleSamples.titleCSS[0]]],
             "commentBubbles": [["name": "缺失资源", "svg": "<svg><image href='https://example.com/a.png'/></svg>"]]],
            ["id": "two", "name": "二号", "background": "#FFFFFF", "ink": "#000000", "accent": "#112233",
             "chapterTitles": [["id": "main", "name": "同名标题", "css": ThemeStyleSamples.titleCSS[1]]]]
        ]])
        let result = try demo.importThemeData(data)
        XCTAssertEqual(result.added, 2); XCTAssertEqual(result.titlesAdded, 2); XCTAssertEqual(result.bubblesAdded, 0); XCTAssertEqual(result.invalid, 1)
        XCTAssertNotEqual(demo.themes.first { $0.id == "one" }!.titleStyleIDs, demo.themes.first { $0.id == "two" }!.titleStyleIDs)
        XCTAssertTrue(demo.themes.first { $0.id == "one" }!.bubbleStyleIDs.isEmpty)
        XCTAssertEqual(demo.themes.first { $0.id == "one" }!.assetIssues, ["缺失资源"])
        XCTAssertTrue(demo.themeImportMessage!.contains("无法预览：缺失资源"))
    }

    func testApplyingMissingAttachmentsPreservesCurrentStylesAndInvalidMixIsAtomic() {
        demo.applyTheme("night")
        let title = demo.activeTitleStyleID, bubble = demo.activeBubbleStyleID
        demo.applyTheme("white")
        XCTAssertEqual(demo.activeThemeID, "white")
        XCTAssertEqual(demo.activeTitleStyleID, title); XCTAssertEqual(demo.activeBubbleStyleID, bubble)
        XCTAssertTrue(demo.applyThemeMix(themeID: "ocean", titleID: "paper:title:line", bubbleID: bubble))
        XCTAssertEqual(demo.activeTitleStyleID, "paper:title:line")
        XCTAssertFalse(demo.applyThemeMix(themeID: "night", titleID: bubble, bubbleID: title))
        XCTAssertEqual(demo.activeThemeID, "ocean"); XCTAssertEqual(demo.activeTitleStyleID, "paper:title:line")
        XCTAssertTrue(demo.applyThemeMix(themeID: "paper", titleID: nil, bubbleID: nil))
        XCTAssertNil(demo.activeTitleStyleID); XCTAssertNil(demo.activeBubbleStyleID)
    }

    func testAssetApplicationAndDeletionPreserveOtherComponentsAndActiveResources() {
        demo.applyThemeAsset("night:bubble:main")
        XCTAssertEqual(demo.activeThemeID, "paper"); XCTAssertEqual(demo.activeTitleStyleID, "paper:title:main")
        demo.removeThemeAssets(["night:bubble:main", "paper:title:line"])
        XCTAssertTrue(demo.themeAssets.contains { $0.id == "night:bubble:main" })
        XCTAssertFalse(demo.themeAssets.contains { $0.id == "paper:title:line" })
        XCTAssertFalse(demo.themes.first { $0.id == "paper" }!.titleStyleIDs.contains("paper:title:line"))
        demo.removeThemes(["night"])
        XCTAssertTrue(demo.themeAssets.contains { $0.id == demo.activeBubbleStyleID })
        demo.toggleThemeAssetFavorite("night:bubble:main")
        XCTAssertTrue(demo.themeAssets.first { $0.id == "night:bubble:main" }!.favorite)
    }

    func testReimportingRemovedBundleReusesItsRetainedAssets() throws {
        _ = try demo.importThemeData(ThemeStyleSamples.importData)
        demo.removeThemes(["cinnamon"])
        let result = try demo.importThemeData(ThemeStyleSamples.importData)
        XCTAssertEqual(result.added, 1); XCTAssertEqual(result.titlesAdded, 0); XCTAssertEqual(result.bubblesAdded, 0)
        XCTAssertEqual(demo.themes.first { $0.id == "cinnamon" }!.titleStyleIDs, ["cinnamon:title:main"])
    }

    func testMalformedAndOversizedInputDoNotMutateStore() {
        let themes = demo.themes, assets = demo.themeAssets
        for data in [Data("bad".utf8), Data("42".utf8), Data(repeating: 32, count: 3 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try demo.importThemeData(data))
        }
        XCTAssertEqual(demo.themes, themes); XCTAssertEqual(demo.themeAssets, assets)
    }

    func testInvalidResourcesAreRejectedAndLocalSVGDefinitionsAreSupported() {
        for svg in ["<svg>", "<svg/>", "<html/>", "<svg><script>1</script></svg>", "<svg onload='1'/>", "<svg><use href='https://example.com'/></svg>",
                    "<!DOCTYPE svg [<!ENTITY a 'bad'>]><svg>&a;</svg>", "<svg><foreignObject/></svg>", "<svg><use href='#missing'/></svg>"] {
            XCTAssertFalse(ThemeAssetValidator.isValid(svg, kind: .bubble), svg)
        }
        XCTAssertTrue(ThemeAssetValidator.isValid("<svg><defs><linearGradient id='g'/></defs><rect fill='url( #g )' width='20' height='20'/></svg>", kind: .bubble))
        XCTAssertTrue(ThemeAssetValidator.isValid("<svg><style>.shape{fill:red}</style><rect class='shape'/></svg>", kind: .bubble))
        for css in ["missing rules", ".chapter-title{background:url(https://example.com/a)}", "@import 'x';.chapter-title{}", "</style><p>bad</p>"] {
            XCTAssertFalse(ThemeAssetValidator.isValid(css, kind: .title))
        }
    }

    func testWebPreviewActuallyRendersCSSAndSVGNumbers() async throws {
        let paper = demo.themes[0]
        let title = demo.themeAssets.first { $0.id == "paper:title:line" }!
        let bubble = demo.themeAssets.first { $0.id == "paper:bubble:main" }!
        let html = ThemePreviewDocument.html(theme: paper, title: title, bubble: bubble)
        XCTAssertFalse(html.contains("{{count}}")); XCTAssertFalse(html.contains("{{accent}}"))
        let graphic = ThemeAsset(id: "graphic", name: "纯图形", kind: .bubble, content: "<svg viewBox='0 0 72 44'><rect width='72' height='40' fill='{{accent}}'/></svg>", sourceThemeID: nil, sourceName: "测试")
        let graphicHTML = ThemePreviewDocument.html(theme: paper, title: nil, bubble: graphic, assetOnly: .bubble)
        for count in [3, 28, 128] { XCTAssertTrue(graphicHTML.contains("class='bubble-count'>\(count)</span>")) }
        let loaded = expectation(description: "Theme document loaded")
        let delegate = ThemeWebTestDelegate(loaded)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        web.navigationDelegate = delegate; web.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let border = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.chapter-title')).borderLeftWidth") as? String
        XCTAssertEqual(border, "4px")
        let counts = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.bubble svg text')).map(x=>x.textContent).join(',')") as? String
        XCTAssertEqual(counts, "12,128")
        let fill = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.bubble svg path')).fill") as? String
        XCTAssertEqual(fill, "rgb(183, 129, 90)")
        web.stopLoading(); web.navigationDelegate = nil
    }
}

private final class ThemeWebTestDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
