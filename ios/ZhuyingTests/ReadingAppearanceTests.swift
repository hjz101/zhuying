import XCTest
import UIKit
@testable import Zhuying

@MainActor final class ReadingAppearanceTests: XCTestCase {
    func testProductionThemeApplicationUpdatesActualReaderAndSurvivesRelaunch() async throws {
        let domain = "production-theme-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let demo = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                   productionPersistence: try ProductionLibraryPersistence(directory: root))
        await library.bootstrapProductionIfNeeded(prepareAppearance: {
            .init(fallbackThemeLibrary: demo.themeSnapshot, originalFontManifest: nil, fontHashes: [:])
        })
        demo.connectReader(library)
        library.settings.fontSize = 25
        library.settings.preferences.titleCSS = ".chapter-title{font-size:33px}"
        library.settings.preferences.customBubbleSVG = ThemeStyleSamples.bubbleSVG[1]
        library.settings.preferences.bubbleFollowsTheme = false
        let theme = try XCTUnwrap(demo.themes.first { $0.id == "night" })
        XCTAssertTrue(demo.applyThemeMix(themeID: theme.id, titleID: theme.titleStyleIDs.first, bubbleID: theme.bubbleStyleIDs.first))
        let palette = ReaderPalette(settings: library.settings)
        XCTAssertEqual(palette.background, UIColor(readerHex: theme.background))
        XCTAssertEqual(palette.ink, UIColor(readerHex: theme.ink))
        XCTAssertEqual(palette.hexAccent, theme.accent)
        XCTAssertEqual(library.settings.preferences.colors?.dark, true)
        XCTAssertEqual(library.settings.fontSize, 25)
        XCTAssertEqual(library.settings.preferences.titleCSS, ".chapter-title{font-size:33px}")
        XCTAssertFalse(library.settings.preferences.bubbleFollowsTheme)
        XCTAssertEqual(library.settings.preferences.customBubbleSVG, ThemeStyleSamples.bubbleSVG[1])
        XCTAssertNotNil(library.settings.preferences.themeTitleCSS)
        XCTAssertEqual(library.settings.preferences.bubbleSVG, demo.themeAssets.first { $0.id == theme.bubbleStyleIDs.first }?.content)
        let saved = await library.flushPendingWrites()
        XCTAssertTrue(saved)

        let restored = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                    productionPersistence: try ProductionLibraryPersistence(directory: root))
        await restored.bootstrapProductionIfNeeded()
        let restoredThemes = FeatureDemoStore(defaults: defaults, seedDemoData: false)
        restoredThemes.connectReader(restored)
        XCTAssertEqual(restoredThemes.activeThemeID, "night")
        XCTAssertEqual(restored.settings.preferences.colors, library.settings.preferences.colors)
        XCTAssertEqual(ReaderPalette(settings: restored.settings).background, palette.background)
        XCTAssertEqual(restored.settings.preferences.titleCSS, library.settings.preferences.titleCSS)
        XCTAssertEqual(restored.settings.preferences.customBubbleSVG, library.settings.preferences.customBubbleSVG)
    }

    func testNormalizedProductionAppearanceStillSavesAndMarksUserChanges() async throws {
        let domain = "normalized-appearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                   productionPersistence: try ProductionLibraryPersistence(directory: root))
        await library.bootstrapProductionIfNeeded()
        var next = library.settings
        next.fontSize = 99
        next.preferences.colors = ReaderColors(background: 0x26382E, ink: 0xC5CCB5, accent: 0xD3A16F, name: "夜读深林", dark: true)
        next.preferences.titleCSS = ".chapter-title{unsupported: value}"
        library.settings = next
        XCTAssertEqual(library.settings.fontSize, 30)
        XCTAssertNil(library.settings.preferences.titleCSS)
        XCTAssertTrue(defaults.bool(forKey: "reader.user-settings-edited.v1"))
        let saved = await library.flushPendingWrites()
        XCTAssertTrue(saved)
        let restored = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                    productionPersistence: try ProductionLibraryPersistence(directory: root))
        await restored.bootstrapProductionIfNeeded()
        XCTAssertEqual(restored.settings, library.settings)
    }

    func testFirstProductionThemeIsPersistedWhenNoLibrarySnapshotWasSeeded() async throws {
        let domain = "first-production-theme-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                   productionPersistence: try ProductionLibraryPersistence(directory: root))
        await library.bootstrapProductionIfNeeded()
        XCTAssertNil(library.themeLibrary)
        let demo = FeatureDemoStore(seedDemoData: false)
        demo.connectReader(library)
        demo.applyTheme("night")
        XCTAssertEqual(library.themeLibrary?.themeID, "night")
        let saved = await library.flushPendingWrites()
        XCTAssertTrue(saved)
        let restored = LibraryStore(books: [], defaults: defaults, seedDemoData: false,
                                    productionPersistence: try ProductionLibraryPersistence(directory: root))
        await restored.bootstrapProductionIfNeeded()
        XCTAssertEqual(restored.themeLibrary?.themeID, "night")
        XCTAssertEqual(restored.settings.preferences.colors?.name, "夜读深林")
    }

    func testThemeLibrarySurvivesRelaunchAndApplicationsKeepPersonalOverrides() throws {
        let domain = "reader-themes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let demo = FeatureDemoStore(defaults: defaults)
        let result = try demo.importThemeData(ThemeStyleSamples.importData)
        XCTAssertGreaterThan(result.added, 0)
        demo.applyTheme("aurora")
        demo.toggleThemeFavorite("aurora")
        let restored = FeatureDemoStore(defaults: defaults)
        XCTAssertEqual(restored.activeThemeID, "aurora")
        XCTAssertEqual(restored.themes, demo.themes)
        XCTAssertEqual(restored.themeAssets, demo.themeAssets)
        var settings = ReadingSettings(fontSize: 23, lineSpacing: 17)
        settings.preferences.titleCSS = ".chapter-title{font-size:31px}"
        settings.preferences.bubbleFollowsTheme = false
        settings.preferences.bubbleStyle = "描边"
        settings.preferences.godFollowsTheme = false
        settings.preferences.godStyle = "画框"
        let theme = try XCTUnwrap(restored.themes.first { $0.id == "aurora" })
        let next = ThemeReaderBridge.apply(theme: theme, title: restored.themeAssets(theme, kind: .title).first, bubble: restored.themeAssets(theme, kind: .bubble).first, to: settings)
        XCTAssertEqual(next.preferences.titleCSS, settings.preferences.titleCSS)
        XCTAssertFalse(next.preferences.bubbleFollowsTheme)
        XCTAssertEqual(next.preferences.bubbleStyle, "描边")
        XCTAssertEqual(next.preferences.godStyle, "画框")
        XCTAssertEqual(next.fontSize, 23)
        XCTAssertEqual(next.lineSpacing, 17)
        XCTAssertEqual(next.preferences.colors?.name, theme.name)
        XCTAssertNoThrow(try ReaderTitleStyle.parse(css: next.preferences.themeTitleCSS, accent: theme.accent))
    }
    func testNativeThemeCompatibilityIsExplicitAndColorOnlyKeepsComponentCaches() {
        let raw = ThemeStyleSamples.titleCSS[0]
        let result = ThemeReaderBridge.nativeTitle(raw, accent: 0x123456)
        XCTAssertTrue(result.simplified)
        XCTAssertNoThrow(try ReaderTitleStyle.parse(css: result.css, accent: 0x123456))
        let demo = FeatureDemoStore()
        var settings = ReadingSettings()
        settings.preferences.themeTitleCSS = ".chapter-title{font-size:22px}"
        settings.preferences.bubbleSVG = "cached-bubble"
        settings.preferences.bubbleImageData = Data([1, 2, 3])
        let next = ThemeReaderBridge.apply(theme: demo.themes[2], title: nil, bubble: nil, to: settings, colorsOnly: true)
        XCTAssertEqual(next.preferences.themeTitleCSS, settings.preferences.themeTitleCSS)
        XCTAssertEqual(next.preferences.bubbleImageData, settings.preferences.bubbleImageData)
        XCTAssertEqual(next.preferences.bubbleSVG, settings.preferences.bubbleSVG)
    }
    func testExplicitDefaultMixClearsThemeComponentsAndKeepsPersonalStyles() {
        let domain = "reader-default-mix-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let demo = FeatureDemoStore()
        let library = LibraryStore(books: [], defaults: defaults)
        demo.connectReader(library)
        library.settings.preferences.themeTitleCSS = ".chapter-title{font-size:30px}"
        library.settings.preferences.bubbleSVG = "old-theme-svg"
        library.settings.preferences.bubbleImageData = Data([1, 2])
        library.settings.preferences.titleCSS = ".chapter-title{font-size:33px}"
        library.settings.preferences.customBubbleSVG = "personal-svg"
        library.settings.preferences.bubbleFollowsTheme = false
        XCTAssertTrue(demo.applyThemeMix(themeID: demo.themes[0].id, titleID: nil, bubbleID: nil))
        XCTAssertNil(library.settings.preferences.themeTitleCSS)
        XCTAssertNil(library.settings.preferences.bubbleSVG)
        XCTAssertNil(library.settings.preferences.bubbleImageData)
        XCTAssertEqual(library.settings.preferences.titleCSS, ".chapter-title{font-size:33px}")
        XCTAssertEqual(library.settings.preferences.customBubbleSVG, "personal-svg")
        XCTAssertFalse(library.settings.preferences.bubbleFollowsTheme)
    }
    func testThemeRestoreKeepsDistinctSameNamedThemeAndStandaloneBubble() throws {
        let domain = "reader-identity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let demo = FeatureDemoStore(defaults: defaults)
        var first = demo.themes[0], second = demo.themes[1]
        first.name = "同名主题"; second.name = "同名主题"
        demo.themes = [first, second]
        demo.activeThemeID = second.id
        let library = LibraryStore(books: [], defaults: defaults)
        library.settings.preferences.colors = ReaderColors(background: second.background, ink: second.ink, accent: second.accent, name: second.name)
        demo.connectReader(library)
        XCTAssertEqual(demo.activeThemeID, second.id)
        var settings = library.settings
        settings.preferences.bubbleFollowsTheme = false
        settings.preferences.customBubbleSVG = "personal"
        settings.preferences.customBubbleImageData = Data([1, 2])
        let changed = ThemeReaderBridge.apply(theme: first, title: nil, bubble: nil, to: settings)
        XCTAssertFalse(changed.preferences.bubbleFollowsTheme)
        XCTAssertEqual(changed.preferences.customBubbleSVG, "personal")
        XCTAssertEqual(changed.preferences.customBubbleImageData, Data([1, 2]))
        let extracted = ThemeReaderBridge.nativeTitle("/* .chapter-title{font-size:40px} */ .chapter-title{font-size:31px;border-left:2px solid red}", accent: 0)
        XCTAssertEqual(try ReaderTitleStyle.parse(css: extracted.css, accent: 0).fontSize, 31)
    }

    func testMalformedFontDoesNotChangeLibraryOrCreateFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fonts = ReadingFontLibrary(directory: directory)
        XCTAssertThrowsError(try fonts.importFont(data: Data("invalid font".utf8), originalName: "broken.ttf"))
        XCTAssertTrue(fonts.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testThemeBubbleCreatesNativeImage() async throws {
        let demo = FeatureDemoStore()
        let data = try await ThemeBubbleRasterizer.render(ThemeStyleSamples.bubbleSVG[0], theme: demo.themes[0])
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 4, "SVG snapshot must contain the rendered shape, not a blank bitmap")
    }
    func testNativeThemePreviewRendersSelectedSVGWithoutChangingReaderSettings() async throws {
        let demo = FeatureDemoStore()
        let theme = demo.themes[0]
        var settings = ReadingSettings()
        settings.preferences.showCommentBubbles = true
        settings.preferences.bubbleSVG = ThemeStyleSamples.bubbleSVG[0]
        let preview = try await ThemeReaderBridge.renderedPreview(settings, theme: theme)
        XCTAssertNil(settings.preferences.bubbleImageData)
        XCTAssertNotNil(preview.preferences.bubbleImageData.flatMap(UIImage.init(data:)))
        settings.preferences.bubbleFollowsTheme = false
        settings.preferences.customBubbleSVG = ThemeStyleSamples.bubbleSVG[1]
        let personal = try await ThemeReaderBridge.renderedPreview(settings, theme: theme)
        XCTAssertNil(personal.preferences.bubbleImageData)
        XCTAssertNotNil(personal.preferences.customBubbleImageData.flatMap(UIImage.init(data:)))
        XCTAssertEqual(personal.preferences.customBubbleSVG, settings.preferences.customBubbleSVG)
    }
}
