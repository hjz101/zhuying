import XCTest
import UIKit
@testable import Zhuying

@MainActor
final class ReadingPreferencePresentationTests: XCTestCase {
    private var book: Book { try! Book.load(bundle: Bundle(for: LibraryStore.self))[0] }

    func testFollowingWithoutCSSShowsTheActualEmptyStyleWithoutCreatingAnOverride() throws {
        let settings = ReadingSettings(theme: .light)
        let editorCSS = ReadingPreferencePresentation.titleEditorCSS(settings: settings)
        XCTAssertEqual(editorCSS, ".chapter-title {}")
        let editorStyle = try ReaderTitleStyle.parse(css: editorCSS, accent: ReaderPalette(settings: settings).hexAccent)
        let effectiveStyle = try ReadingPreferencePresentation.titleStyle(settings: settings)
        XCTAssertEqual(editorStyle, effectiveStyle)
        XCTAssertNil(settings.preferences.titleCSS)
        XCTAssertNil(settings.preferences.themeTitleCSS)
        let document = ReaderDocument(book: book, chapter: 0, settings: settings)
        let nativeStyle = try XCTUnwrap(document.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(nativeStyle.alignment, .left)
        XCTAssertTrue(ReadingPreferencePresentation.titleColor(settings: settings).isEqual(ReaderPalette(settings: settings).ink))
    }

    func testTitleAccentUsesTheSameBuiltInPaletteInPreviewAndNativeText() throws {
        for theme in ReadingTheme.allCases {
            var settings = ReadingSettings(theme: theme)
            settings.preferences.titleCSS = ".chapter-title { color: var(--reader-accent); }"
            let palette = ReaderPalette(settings: settings)
            let uiColor = ReadingPreferencePresentation.titleColor(settings: settings)
            let document = ReaderDocument(book: book, chapter: 0, settings: settings)
            let actual = try XCTUnwrap(document.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
            assertSameColor(uiColor, actual)
            assertSameColor(uiColor, palette.accent)
            XCTAssertEqual(try ReadingPreferencePresentation.titleStyle(settings: settings).color, palette.hexAccent)
        }
    }

    func testCustomPaletteAccentAndInkRemainConsistentForBothTitleModes() throws {
        var settings = ReadingSettings(theme: .dark)
        settings.preferences.colors = .init(background: 0x182630, ink: 0xDAE8E9, accent: 0x79BBA0, name: "海雾", dark: true)
        settings.preferences.themeTitleCSS = ".chapter-title { color: var(--accent); text-align: center; }"
        let inherited = ReadingPreferencePresentation.titleEditorCSS(settings: settings)
        XCTAssertEqual(inherited, settings.preferences.themeTitleCSS)
        assertSameColor(ReadingPreferencePresentation.titleColor(settings: settings), UIColor(readerHex: 0x79BBA0))
        settings.preferences.titleCSS = ".chapter-title { color: #AABBCC; text-align: right; }"
        XCTAssertEqual(ReadingPreferencePresentation.titleEditorCSS(settings: settings), settings.preferences.titleCSS)
        assertSameColor(ReadingPreferencePresentation.titleColor(settings: settings), UIColor(readerHex: 0xAABBCC))
        settings.preferences.titleCSS = nil
        XCTAssertEqual(ReadingPreferencePresentation.titleEditorCSS(settings: settings), inherited)
        settings.preferences.themeTitleCSS = nil
        assertSameColor(ReadingPreferencePresentation.titleColor(settings: settings), UIColor(readerHex: 0xDAE8E9))
    }

    func testFontSummaryUsesHumanReadableNamesAndNeverDisplaysTheSentinel() {
        let imported = ReadingFontEntry(postScriptName: "ImportedText-Regular", displayName: "我的阅读字体", filename: "local.font")
        XCTAssertEqual(ReadingPreferencePresentation.fontDisplayName(nil, entries: []), "系统黑体")
        XCTAssertEqual(ReadingPreferencePresentation.fontDisplayName("__serif__", entries: []), "系统衬线")
        XCTAssertEqual(ReadingPreferencePresentation.fontDisplayName(imported.postScriptName, entries: [imported]), imported.displayName)
        XCTAssertEqual(ReadingPreferencePresentation.fontDisplayName("MissingPrivatePostScriptName", entries: []), "当前字体（待重新导入）")
    }

    func testBuiltInFontSamplesUseTheSelectedWeightLikeNativeParagraphs() throws {
        for name in [String?.none, "__serif__"] {
            for weight in ["细体", "常规", "中等", "粗体"] {
                var settings = ReadingSettings(fontSize: 22)
                settings.preferences.fontName = name
                settings.preferences.fontWeight = weight
                let sampleFont = ReadingPreferencePresentation.sampleFont(name, settings: settings)
                let document = ReaderDocument(book: book, chapter: 0, settings: settings)
                let firstParagraph = try XCTUnwrap(document.paragraphRanges.first)
                let actualFont = try XCTUnwrap(document.text.attribute(.font, at: firstParagraph.location, effectiveRange: nil) as? UIFont)
                XCTAssertEqual(sampleFont.fontDescriptor, actualFont.fontDescriptor)
                XCTAssertEqual(sampleFont.pointSize, actualFont.pointSize)
            }
        }
    }

    private func assertSameColor(_ lhs: UIColor, _ rhs: UIColor, file: StaticString = #filePath, line: UInt = #line) {
        var leftR: CGFloat = 0, leftG: CGFloat = 0, leftB: CGFloat = 0, leftA: CGFloat = 0
        var rightR: CGFloat = 0, rightG: CGFloat = 0, rightB: CGFloat = 0, rightA: CGFloat = 0
        XCTAssertTrue(lhs.getRed(&leftR, green: &leftG, blue: &leftB, alpha: &leftA), file: file, line: line)
        XCTAssertTrue(rhs.getRed(&rightR, green: &rightG, blue: &rightB, alpha: &rightA), file: file, line: line)
        XCTAssertEqual(leftR, rightR, accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(leftG, rightG, accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(leftB, rightB, accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(leftA, rightA, accuracy: 0.001, file: file, line: line)
    }
}
