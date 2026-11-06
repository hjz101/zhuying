import XCTest
@testable import Zhuying

final class ReaderPreferencesTests: XCTestCase {
    func testOldSettingsMigrateWithUnchangedReaderDefaults() throws {
        let old = Data("{\"fontSize\":22,\"lineSpacing\":18,\"theme\":\"dark\",\"mode\":\"paged\",\"tapToTurn\":true,\"haptics\":false}".utf8)
        let settings = try JSONDecoder().decode(ReadingSettings.self, from: old)
        XCTAssertEqual(settings.fontSize, 22)
        XCTAssertEqual(settings.mode, .paged)
        XCTAssertTrue(settings.tapToTurn)
        XCTAssertFalse(settings.haptics)
        XCTAssertEqual(settings.preferences, ReaderPreferences())
        XCTAssertEqual(settings.preferences.leftMargin, 25)
        XCTAssertEqual(settings.preferences.paragraphSpacing, 22)
        XCTAssertFalse(settings.preferences.headerEnabled)
        XCTAssertFalse(settings.preferences.showCommentBubbles)
    }

    func testExpandedSettingsRoundTripIndependentLayoutAndTitleOverrides() throws {
        var prefs = ReaderPreferences(paragraphSpacing: 17, leftMargin: 40, rightMargin: 12, marginsLinked: false,
                                      fontName: "CustomFont", colors: .init(background: 0xE7EEEA, ink: 0x365449, accent: 0x637C69, name: "远山"),
                                      titleCSS: ".chapter-title { font-size: 31px; text-align: right; }", themeTitleCSS: ".chapter-title { color: #334455; }",
                                      headerEnabled: true, footerEnabled: true, horizontalEffect: "仿真", verticalEffect: "覆盖")
        prefs.pageElements.append(.init(zone: "footer", kind: "自定义文字", text: "我的阅读空间", x: 60, y: 50))
        prefs.rules[0].enabled = true
        prefs.bubbleImageData = Data([1, 2, 3])
        let original = ReadingSettings(fontSize: 21, lineSpacing: 9, theme: .paper, mode: .verticalPaged, preferences: prefs)
        let restored = try JSONDecoder().decode(ReadingSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.preferences.effectiveTitleCSS, prefs.titleCSS)
        XCTAssertEqual(restored.preferences.effect(for: .paged), "仿真")
        XCTAssertEqual(restored.preferences.effect(for: .verticalPaged), "覆盖")
        XCTAssertTrue(restored.mode.isPaged)
        XCTAssertFalse(ReadingMode.scroll.isPaged)
    }

    func testPartialPreferenceSnapshotsReceiveDefaults() throws {
        let data = Data("{\"paragraphSpacing\":7,\"leftMargin\":44,\"headerEnabled\":true}".utf8)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        XCTAssertEqual(decoded.paragraphSpacing, 7)
        XCTAssertEqual(decoded.leftMargin, 44)
        XCTAssertEqual(decoded.rightMargin, 25)
        XCTAssertEqual(decoded.pageElements.count, 4)
        XCTAssertEqual(decoded.rules.map(\.id), ["dialogue", "system", "poetry", "drop-cap"])
        XCTAssertFalse(decoded.rules.contains(where: \.enabled))
        XCTAssertTrue(decoded.headerEnabled)
        XCTAssertFalse(decoded.footerEnabled)
    }

    func testNormalizingBoundsKeepsElementIdentitiesUniqueAndScopesDisabled() {
        var prefs = ReaderPreferences(paragraphSpacing: .infinity, leftMargin: -30, rightMargin: 500, topMargin: .nan,
                                      headerHeight: 0, footerHeight: 400, horizontalEffect: "unknown", verticalEffect: "仿真")
        prefs.pageElements = [.init(id: "duplicate", x: -300, y: 400, width: 180, fontSize: 40), .init(id: "duplicate", zone: "footer", x: 120)]
        prefs.rules = [.init(id: "local", name: "本书规则", enabled: true, scope: "当前书籍"),
                       .init(id: "invalid", name: "不完整正则", match: "正则表达式", pattern: "[", enabled: true)]
        prefs.normalize()
        XCTAssertEqual(prefs.paragraphSpacing, 22)
        XCTAssertEqual(prefs.leftMargin, 0)
        XCTAssertEqual(prefs.rightMargin, 80)
        XCTAssertEqual(prefs.topMargin, 24)
        XCTAssertEqual(prefs.headerHeight, 48)
        XCTAssertEqual(prefs.footerHeight, 140)
        XCTAssertEqual(Set(prefs.pageElements.map(\.id)).count, 2)
        XCTAssertEqual(prefs.pageElements[0].x, 45)
        XCTAssertEqual(prefs.pageElements[0].width, 90)
        XCTAssertEqual(prefs.pageElements[0].fontSize, 22)
        XCTAssertFalse(prefs.rules.contains(where: \.enabled))
        XCTAssertEqual(prefs.effect(for: .scroll), "连续滚动")
        XCTAssertEqual(prefs.effect(for: .verticalPaged), "平移")
        XCTAssertEqual(prefs.effect(for: .paged), "平移")
    }

    func testCommentSkinsKeepPersonalOverridesWhenThemeAttachmentsChange() throws {
        var prefs = ReaderPreferences()
        prefs.themeGodStyle = "画框"
        XCTAssertEqual(prefs.effectiveGodStyle, "画框")
        prefs.godFollowsTheme = false
        prefs.godStyle = "液态玻璃"
        prefs.themeGodStyle = "纯色"
        XCTAssertEqual(prefs.effectiveGodStyle, "液态玻璃")
        prefs.bubbleFollowsTheme = false
        prefs.bubbleStyle = "自定义"
        prefs.bubbleColor = 0x445566
        prefs.bubbleRadius = 80
        prefs.godRadius = -4
        prefs.godBackground = 0xE7EEEA
        prefs.godBorder = 0x637C69
        prefs.bubbleSVG = "<svg><rect width=\"72\" height=\"44\"/></svg>"
        prefs.bubbleImageData = Data([1, 2, 3])
        prefs.customBubbleSVG = "<svg><circle r=\"12\"/></svg>"
        prefs.customBubbleImageData = Data([4, 5, 6])
        prefs.normalize()
        XCTAssertEqual(prefs.bubbleRadius, 30)
        XCTAssertEqual(prefs.godRadius, 0)
        let restored = try JSONDecoder().decode(ReaderPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored, prefs)
        XCTAssertFalse(restored.bubbleFollowsTheme)
        XCTAssertEqual(restored.bubbleColor, 0x445566)
        XCTAssertEqual(restored.godBackground, 0xE7EEEA)
        XCTAssertEqual(restored.godBorder, 0x637C69)
        XCTAssertEqual(restored.themeGodStyle, "纯色")
        XCTAssertEqual(restored.bubbleSVG, prefs.bubbleSVG)
        XCTAssertEqual(restored.bubbleImageData, Data([1, 2, 3]))
        XCTAssertEqual(restored.customBubbleSVG, prefs.customBubbleSVG)
        XCTAssertEqual(restored.customBubbleImageData, Data([4, 5, 6]))
        prefs.godFollowsTheme = true
        XCTAssertEqual(prefs.effectiveGodStyle, "纯色")
    }

    func testPositionConstraintsUseEachElementsDimensionsAndZoneHeight() {
        let element = ReaderPageElement(zone: "header", x: -100, y: 300, width: 40, fontSize: 22)
        let top = element.constrained(headerHeight: 64, footerHeight: 120)
        XCTAssertEqual(top.x, 20)
        XCTAssertEqual(top.y, 100 - 34.0 / 64 * 50, accuracy: 0.001)
        var footer = element
        footer.zone = "footer"
        let bottom = footer.constrained(headerHeight: 64, footerHeight: 120)
        XCTAssertGreaterThan(bottom.y, top.y)
        XCTAssertEqual(element.x, -100, "Computing display constraints must not edit unrelated stored elements")
        XCTAssertEqual(bottom.zone, "footer")
    }

    func testNativeChapterCSSParsesSameTypographyUsedByEditorAndReader() throws {
        let css = """
        /* 自定义章首 */
        .chapter-title { font-size: 31pt; text-align: center; color: var(--reader-accent);
            background-color: #abc; letter-spacing: 3px; padding-top: 8px; padding-bottom: 21px;
            font-weight: 700; border-bottom: 1px solid currentColor; }
        """
        let style = try ReaderTitleStyle.parse(css: css, accent: 0x637C69)
        XCTAssertEqual(style.fontSize, 31)
        XCTAssertEqual(style.alignment, "center")
        XCTAssertEqual(style.color, 0x637C69)
        XCTAssertEqual(style.background, 0xAABBCC)
        XCTAssertEqual(style.tracking, 3)
        XCTAssertEqual(style.spacingBefore, 8)
        XCTAssertEqual(style.spacingAfter, 21)
        XCTAssertEqual(style.fontWeight, "700")
        XCTAssertTrue(style.underline)
        let follow = try ReaderTitleStyle.parse(css: ".chapter-title { color: var(--ink); background-color: var(--background); border-bottom: none; }", accent: 0x112233)
        XCTAssertNil(follow.color)
        XCTAssertNil(follow.background)
        XCTAssertFalse(follow.underline)
        XCTAssertEqual(try ReaderTitleStyle.parse(css: nil, accent: 0), ReaderTitleStyle())
    }

    func testUnsupportedOrInvalidChapterCSSIsReported() {
        let unsupported = [
            "body { font-size: 20px; }", ".chapter-title:before { content: '✦'; }",
            ".chapter-title { font-size: 3px; }", ".chapter-title { text-align: diagonal; }",
            ".chapter-title { color: broken; }", ".chapter-title { background-color: url(https://example.com/a); }",
            ".chapter-title { font-family: external; }", ".chapter-title { position: fixed; }",
            ".chapter-title { font-size 20px; }", ".chapter-title { border-bottom: nonsense; }",
            "@import 'https://example.com/a'; .chapter-title { color: #333; }"
        ]
        for css in unsupported { XCTAssertThrowsError(try ReaderTitleStyle.parse(css: css, accent: 0x334455), css) }
    }

    func testDialogueRulesReturnUTF16RangesAndKeywordsAreLiteral() throws {
        let source = "🌄她说：「山海有相逢。」又说：“长风自有归处。”"
        let dialogue = ReaderStyleRule(name: "人物对话")
        let ranges = try dialogue.ranges(in: source)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map { (source as NSString).substring(with: $0) }, ["「山海有相逢。」", "“长风自有归处。”"])
        XCTAssertEqual(ranges[0].location, 5)
        let literal = ReaderStyleRule(name: "特殊符号", match: "关键词", pattern: "[系统]")
        XCTAssertEqual(try literal.ranges(in: "[系统] 系统").map { ("[系统] 系统" as NSString).substring(with: $0) }, ["[系统]"])
        let emoji = "👩‍🚀故事开始"
        let first = try ReaderStyleRule(name: "首字下沉", match: "章节首段", presentation: "首字下沉").ranges(in: emoji)
        XCTAssertEqual(first.first, (emoji as NSString).rangeOfComposedCharacterSequence(at: 0))
        XCTAssertTrue(try dialogue.ranges(in: "没有对话").isEmpty)
    }

    func testRuleTemplatesMatchExamplesAndInvalidOrUnboundScopesCannotMatch() throws {
        let system = ReaderStyleRule.templates[1]
        XCTAssertEqual(try system.ranges(in: "【系统提示：图鉴已解锁】").count, 1)
        let poem = "长风破浪会有时，直挂云帆济沧海。"
        XCTAssertEqual(try ReaderStyleRule.templates[2].ranges(in: poem).first?.length, (poem as NSString).length)
        let local = ReaderStyleRule(name: "未绑定本书", match: "关键词", pattern: "山海", enabled: true, scope: "当前书籍")
        XCTAssertTrue(try local.ranges(in: "山海").isEmpty)
        XCTAssertThrowsError(try ReaderStyleRule(name: "错误正则", match: "正则表达式", pattern: "[").validate())
        XCTAssertThrowsError(try ReaderStyleRule(name: "空内容", match: "关键词").validate())
        XCTAssertThrowsError(try ReaderStyleRule(name: "过长", match: "正则表达式", pattern: String(repeating: "a", count: 513)).validate())
    }

    func testCustomRegexStopsInsteadOfBlockingReaderForPathologicalInput() {
        let rule = ReaderStyleRule(name: "过度回溯", match: "正则表达式", pattern: "(a+)+$")
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try rule.ranges(in: String(repeating: "a", count: 400) + "!"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    @MainActor
    func testLibraryReloadPreservesContinuousTypographyValuesAndExpandedSettings() throws {
        let domain = "com.zhuying.reader-preferences-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let books = try Book.load(bundle: Bundle(for: LibraryStore.self))
        let store = LibraryStore(books: books, defaults: defaults)
        let preferences = ReaderPreferences(paragraphSpacing: 13, leftMargin: 36, rightMargin: 12, marginsLinked: false,
                                            titleCSS: ".chapter-title { text-align: right; }", headerEnabled: true)
        store.settings = ReadingSettings(fontSize: 21, lineSpacing: 9, mode: .verticalPaged, preferences: preferences)
        let restored = LibraryStore(books: books, defaults: defaults)
        XCTAssertEqual(restored.settings, store.settings)
        XCTAssertNil(restored.storageMessage)
        XCTAssertEqual(restored.settings.preferences.leftMargin, 36)
        XCTAssertEqual(restored.settings.preferences.rightMargin, 12)
        XCTAssertEqual(restored.settings.fontSize, 21)
        XCTAssertEqual(restored.settings.lineSpacing, 9)
    }
}
