import XCTest
import ZIPFoundation
import UIKit
@testable import Zhuying

@MainActor
final class GlobalThemeTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingThemes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        domain = "zhuying.themes.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }
    private func library() -> LibraryStore { LibraryStore(books: [], defaults: defaults, seedDemoData: false) }
    private func store(writer: any AtomicFileWriting = AtomicFileWriter()) -> GlobalThemeStore {
        let store = GlobalThemeStore(writer: writer); store.configure(directory: directory); return store
    }
    private func bundle() -> GlobalThemeBundle {
        var settings = ReadingSettings(fontSize: 24, lineSpacing: 14, mode: .paged, tapToTurn: true)
        settings.preferences.colors = .init(background: 0x151622, ink: 0xF4F2FA, accent: 0xC9B5FF, name: "夜航", dark: true)
        settings.preferences.leftMargin = 31; settings.preferences.rightMargin = 33
        settings.preferences.headerEnabled = true; settings.preferences.footerEnabled = true
        settings.preferences.showCommentBubbles = true; settings.preferences.showGodComments = true
        settings.preferences.godStyle = "画框"; settings.preferences.godFollowsTheme = false; settings.preferences.bubbleRadius = 19
        let css = ".chapter-title { font-size:28pt; text-align:center; color:#C9B5FF; }"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 44'><rect width='72' height='40' rx='12' fill='{{accent}}'/><text x='36' y='26' text-anchor='middle'>{{count}}</text></svg>"
        let reader = PortableReaderTheme(appearance: .init(settings), resources: ["title": .init(path: "assets/reader/title.css"), "bubble": .init(path: "assets/reader/bubble.svg")], optionalReadingBehavior: .init(mode: .paged, tapToTurn: true, haptics: false))
        return .init(manifest: .init(themeID: "zhuying.tests.night", name: "竹影测试夜航", packageKind: "full", scopes: ["app", "reader"], appearanceModes: ["dark"], requiredCapabilities: ["app.appearance.v1", "reader.appearance.v1"]), document: .init(app: .night, reader: reader), resources: ["assets/reader/title.css": Data(css.utf8), "assets/reader/bubble.svg": Data(svg.utf8)])
    }
    private func zip(_ files: [(String, Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, bytes) in files { try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in bytes.subdata(in: Int(offset)..<Int(offset) + count) } }
        return archive.data!
    }
    private func files(_ data: Data) throws -> [(String, Data)] {
        let archive = try Archive(data: data, accessMode: .read)
        return try archive.map { entry in var data = Data(); _ = try archive.extract(entry) { data.append($0) }; return (entry.path, data) }
    }
    func testPortablePackageRoundTripKeepsEffectiveReaderAppearanceAndActualHashes() throws {
        let original = bundle()
        let data = try GlobalThemePackage.encode(original)
        let decoded = try GlobalThemePackage.decode(data)
        XCTAssertEqual(decoded.document, original.document)
        XCTAssertEqual(decoded.resources, original.resources)
        XCTAssertEqual(decoded.manifest.packageKind, "full")
        for file in decoded.manifest.files {
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertTrue(file.bytes > 0)
            XCTAssertNotEqual(file.role, "image")
        }
        let theme = try XCTUnwrap(try files(data).first { $0.0 == "theme.json" }?.1)
        let text = String(decoding: theme, as: UTF8.self)
        for key in PortableReaderAppearance.excluded { XCTAssertFalse(text.contains("\"\(key)\""), key) }
        XCTAssertTrue(text.contains("#C9B5FF"))
        XCTAssertEqual(try GlobalThemePackage.decode(GlobalThemePackage.encode(decoded)).document, decoded.document)
    }
    func testTamperedMissingDuplicateAndUnlistedResourcesAreRejected() throws {
        let original = try files(GlobalThemePackage.encode(bundle()))
        let tampered = original.map { $0.0.hasSuffix("title.css") ? ($0.0, Data("changed".utf8)) : $0 }
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(tampered)))
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(original.filter { !$0.0.hasSuffix("bubble.svg") })))
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(original + [("hidden.txt", Data("unlisted".utf8))])))
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(original + [original[0]])))
    }
    func testUnsafeAndUnicodeConflictingPathsAreRejected() throws {
        for path in ["../escape.png", "/escape.png", "a\\b.png", "a//b.png", "C:escape.png"] { XCTAssertFalse(GlobalThemePackage.safePath(path), path) }
        let original = try files(GlobalThemePackage.encode(bundle()))
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(original + [("../escape.txt", Data("unsafe".utf8))])))
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(original + [("A.txt", Data([1])), ("a.txt", Data([2]))])))
        XCTAssertThrowsError(try GlobalThemePackage.decode(zip(original + [("é.txt", Data([1])), ("e\u{301}.txt", Data([2]))])))
    }
    func testUnsupportedCapabilitiesVersionsAndIncompleteFullPackagesAreRejected() throws {
        var value = bundle(); value.manifest.requiredCapabilities.append("unimplemented.web-css.v9")
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
        value = bundle(); value.document.reader = nil
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
        value = bundle(); value.manifest.formatVersion = 99
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
    }
    func testInvalidNativeCSSSVGAndUnlicensedFontsCannotBePackaged() throws {
        var value = bundle(); value.resources["assets/reader/title.css"] = Data(".chapter-title::after { content:'x'; }".utf8)
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
        value = bundle(); value.resources["assets/reader/bubble.svg"] = Data("<svg><script>run()</script></svg>".utf8)
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
        value = bundle(); value.document.fontBindings["reader.body"] = .init(path: "assets/fonts/a.ttf", postScriptName: "fake", licensePath: "licenses/font.txt")
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
    }
    func testReaderBoundsRejectSilentNormalizationInsteadOfClaimingPerfectImport() throws {
        var value = bundle(); value.document.reader!.appearance.preferences.leftMargin = 999
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
        value = bundle(); value.document.reader!.appearance.fontSize = .infinity
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
        value = bundle(); value.document.reader!.appearance.preferences.rules = [.init(name: "私人规则", scope: "当前书籍", bookID: "private")]
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
    }
    func testImageAndIconStateAssetsAreClosedAndBounded() throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        var value = bundle()
        value.resources["assets/icons/shelf.png"] = data
        value.document.app.icons["navigation.shelf"] = .init(symbol: "books.vertical", selected: "assets/icons/shelf.png")
        value.document.app.backgrounds["page"] = .init(path: "assets/icons/shelf.png", opacity: 0.2)
        value.document.reader!.background = .init(path: "assets/icons/shelf.png", mode: "tile", opacity: 0.1)
        for mode in ["fill", "fit", "tile"] {
            value.document.app.backgrounds["cover.default"] = .init(path: "assets/icons/shelf.png", mode: mode, opacity: 0.8, overlayOpacity: 0.25)
            let decoded = try GlobalThemePackage.decode(GlobalThemePackage.encode(value))
            XCTAssertEqual(decoded.document.app.backgrounds["cover.default"], value.document.app.backgrounds["cover.default"])
            XCTAssertEqual(decoded.document.reader?.background, value.document.reader?.background)
        }
        value.document.app.icons["navigation.shelf"]!.pressed = "missing.png"
        XCTAssertThrowsError(try GlobalThemePackage.encode(value))
    }
    func testImportOnlyKeepsCurrentAppearanceAndDeduplicatesWithoutTimestampDependence() throws {
        let store = store(); let library = library(); store.attach(library)
        let data = try GlobalThemePackage.encode(bundle())
        let value = try store.importPackage(data)
        XCTAssertEqual(store.active.manifest.themeID, "zhuying.builtin.original")
        XCTAssertNil(library.globalThemeSelection)
        XCTAssertEqual(try store.importPackage(GlobalThemePackage.encode(value)).id, value.id)
        XCTAssertEqual(store.bundles.count, 4)
        var changed = bundle(); changed.manifest.name = "同版本不同内容"
        XCTAssertThrowsError(try store.importPackage(GlobalThemePackage.encode(changed)))
    }
    func testApplyingFullPackageReplacesPersonalOverridesButPreservesReadingBehavior() async throws {
        let store = store(); let library = library(); store.attach(library)
        library.settings.mode = .scroll; library.settings.tapToTurn = false
        library.settings.preferences.titleCSS = ".chapter-title { text-align:right; }"
        library.settings.preferences.customBubbleSVG = ThemeStyleSamples.bubbleSVG[0]
        library.settings.preferences.bubbleFollowsTheme = false
        let old = library.settings
        let imported = try store.importPackage(GlobalThemePackage.encode(bundle()))
        try await store.apply(imported)
        XCTAssertEqual(store.active.id, imported.id)
        XCTAssertEqual(library.settings.fontSize, 24)
        XCTAssertEqual(library.settings.preferences.rightMargin, 33)
        XCTAssertNil(library.settings.preferences.titleCSS)
        XCTAssertTrue(library.settings.preferences.effectiveTitleCSS!.contains("28pt"))
        XCTAssertTrue(library.settings.preferences.bubbleFollowsTheme)
        XCTAssertTrue(library.settings.preferences.showGodComments)
        XCTAssertEqual(library.settings.preferences.effectiveGodStyle, "画框")
        XCTAssertEqual(library.settings.mode, old.mode); XCTAssertEqual(library.settings.tapToTurn, old.tapToTurn)
        try await store.restore()
        XCTAssertEqual(library.settings, old)
        XCTAssertEqual(store.active.manifest.themeID, "zhuying.builtin.original")
    }
    func testMixedInterfaceOnlyAndBehaviorOptInAreIndependent() async throws {
        let store = store(); let library = library(); store.attach(library)
        let old = library.settings
        let value = try store.importPackage(GlobalThemePackage.encode(bundle()))
        try await store.apply(value, options: .interfaceOnly)
        XCTAssertEqual(library.settings, old)
        XCTAssertNil(store.readerBundle)
        try await store.apply(value, options: .init(readingBehavior: true))
        XCTAssertEqual(library.settings.mode, .paged)
        XCTAssertTrue(library.settings.tapToTurn); XCTAssertFalse(library.settings.haptics)
    }
    func testMixedLayoutKeepsExistingDecorationsAndColors() throws {
        var current = ReadingSettings()
        current.preferences.titleCSS = ".chapter-title { text-align:right; }"
        current.preferences.bubbleColor = 0x123456
        current.preferences.godRadius = 3
        current.preferences.colors = .init(background: 0xFFFFFF, ink: 0, accent: 0x112233, name: "个人")
        let result = try GlobalThemeStore.settings(for: bundle(), current: current, options: .init(app: false, readerColors: false, readerLayout: true, readerDecorations: false))
        XCTAssertEqual(result.fontSize, 24)
        XCTAssertEqual(result.preferences.titleCSS, current.preferences.titleCSS)
        XCTAssertEqual(result.preferences.bubbleColor, current.preferences.bubbleColor)
        XCTAssertEqual(result.preferences.godRadius, current.preferences.godRadius)
        XCTAssertEqual(result.preferences.colors, current.preferences.colors)
    }
    func testPackageCatalogAndAppearanceSurviveReopeningWithNoExternalDependency() async throws {
        let store = store(); let library = library(); store.attach(library)
        let value = try store.importPackage(GlobalThemePackage.encode(bundle()))
        try await store.apply(value)
        let reloaded = self.store(); let reopenedLibrary = self.library(); reloaded.attach(reopenedLibrary)
        XCTAssertEqual(reloaded.active.id, value.id)
        XCTAssertEqual(reopenedLibrary.settings.fontSize, 24)
        XCTAssertEqual(reloaded.readerBundle?.resources, value.resources)
        XCTAssertThrowsError(try reloaded.remove(value))
    }
    func testExportCapturesPersonalCSSBubbleAndLayoutWithoutPrivateRulesOrCaches() throws {
        let store = store(); let library = library(); store.attach(library)
        library.settings.preferences.titleCSS = ".chapter-title { font-size:30pt; text-align:right; }"
        library.settings.preferences.customBubbleSVG = ThemeStyleSamples.bubbleSVG[1]
        library.settings.preferences.bubbleFollowsTheme = false
        library.settings.preferences.bubbleImageData = Data([1, 2, 3])
        library.settings.preferences.rules = [.init(name: "私有", scope: "当前书籍", bookID: "secret")]
        library.settings.preferences.footerEnabled = true
        let package = try GlobalThemePackage.decode(store.exportCurrent(name: "竹影分享测试"))
        XCTAssertEqual(try GlobalThemePackage.text(package.document.reader!.resources["title"]!.path, in: package), library.settings.preferences.titleCSS)
        XCTAssertEqual(try GlobalThemePackage.text(package.document.reader!.resources["bubble"]!.path, in: package), library.settings.preferences.customBubbleSVG)
        XCTAssertTrue(package.document.reader!.appearance.preferences.footerEnabled)
        XCTAssertTrue(package.document.reader!.appearance.preferences.rules.isEmpty)
        XCTAssertNil(package.document.reader!.appearance.preferences.bubbleImageData)
    }
    func testFailedCatalogWriteDoesNotInstallOrChangeTheme() throws {
        struct Failure: AtomicFileWriting { func write(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) } }
        let store = store(writer: Failure())
        XCTAssertThrowsError(try store.importPackage(GlobalThemePackage.encode(bundle())))
        XCTAssertEqual(store.bundles.count, 3)
        XCTAssertEqual(store.active.manifest.themeID, "zhuying.builtin.original")
    }
    func testProductionViewPreferencesRetainSelectionAndRestorePoint() throws {
        let settings = ReadingSettings(fontSize: 26)
        let selection = GlobalThemeSelection(appID: "theme", readerID: "reader", previous: .init(appID: nil, readerID: nil, settings: settings))
        let snapshot = LibrarySnapshot(favorites: [], progress: [:], globalThemeSelection: selection)
        let view = try JSONDecoder().decode(LibraryViewPreferences.self, from: JSONEncoder().encode(LibraryViewPreferences(snapshot)))
        XCTAssertEqual(view.globalThemeSelection, selection)
    }
    func testSystemSerifFontAndAuthoringKitRemainPortableWithoutFontLicense() throws {
        let store = store(); let library = library(); store.attach(library)
        library.settings.preferences.fontName = "__serif__"
        let data = try store.exportCurrent(name: "竹影宋体")
        let value = try GlobalThemePackage.decode(data)
        XCTAssertEqual(value.document.reader?.systemFont, "serif")
        let restored = try GlobalThemeStore.settings(for: value, current: .init(), options: .init())
        XCTAssertEqual(restored.preferences.fontName, "__serif__")
        let kit = try files(GlobalThemePackage.authoringKit(theme: data))
        XCTAssertEqual(Set(kit.map(\.0)), ["竹影-基础模板.zhuyingtheme", "theme-contract.json", "theme.schema.json", "manifest.schema.json", "给AI的制作要求.md"])
        XCTAssertEqual(try GlobalThemePackage.decode(XCTUnwrap(kit.first { $0.0.hasSuffix(".zhuyingtheme") }?.1)).document, value.document)
        let contract = try XCTUnwrap(kit.first { $0.0 == "theme-contract.json" }?.1)
        let object = try JSONSerialization.jsonObject(with: contract) as! [String: Any]
        XCTAssertEqual(Set(object["requiredColorRoles"] as! [String]), AppThemeAppearance.requiredColors)
    }
    func testProductionBackupKeepsGlobalThemeResourcesAcrossGenerationRestore() async throws {
        let root = directory.appendingPathComponent("production")
        let fonts = directory.appendingPathComponent("fonts")
        let workspace = LibraryWorkspace(root: root, legacyFonts: fonts)
        let library = LibraryStore(books: [], defaults: defaults, seedDemoData: false, productionFactory: { try ProductionLibraryPersistence(directory: root) }, workspace: workspace)
        await library.bootstrapProductionIfNeeded()
        XCTAssertEqual(library.loadState, .ready)
        let themes = store(); themes.attach(library)
        let imported = try themes.importPackage(GlobalThemePackage.encode(bundle()))
        try await themes.apply(imported)
        let backup = try LibraryBackup.decode(await library.createBackup())
        XCTAssertTrue(backup.resources.contains { $0.path == "global-themes/catalog.json" })
        let missingResources = LibraryBackup(createdAt: backup.createdAt, database: backup.database, documents: backup.documents, resources: backup.resources.filter { !$0.path.hasPrefix("global-themes/") })
        XCTAssertThrowsError(try missingResources.validate(), "A backup must not silently lose the selected global theme")
        try await library.restoreBackup(backup)
        themes.attach(library)
        XCTAssertEqual(themes.active.id, imported.id)
        XCTAssertEqual(themes.readerBundle?.resources, imported.resources)
        XCTAssertEqual(library.settings.fontSize, 24)
    }
    func testClearingRestorePointAllowsDeletingOnlyUnusedThemeResources() async throws {
        let store = store(); let library = library(); store.attach(library)
        let imported = try store.importPackage(GlobalThemePackage.encode(bundle()))
        try await store.apply(imported, options: .interfaceOnly)
        try await store.apply(GlobalThemeBundle.originals[1], options: .interfaceOnly)
        XCTAssertThrowsError(try store.remove(imported))
        try await store.clearRestorePoint()
        XCTAssertNil(library.globalThemeSelection?.previous)
        XCTAssertNoThrow(try store.remove(imported))
        XCTAssertEqual(store.active.manifest.themeID, "zhuying.builtin.green")
    }
    func testLicensedOriginalFontTravelsWithPackageAndInstallsWithoutCreatorFiles() async throws {
        let fixtures = Bundle(for: GlobalThemeTests.self)
        let source = try XCTUnwrap(fixtures.url(forResource: "ReaderTestFont", withExtension: "ttf") ?? fixtures.url(forResource: "ReaderTestFont", withExtension: "ttf", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: source)
        let fonts = ReadingFontLibrary.shared, original = fonts.directory
        fonts.useDirectory(directory.appendingPathComponent("fonts"))
        defer { fonts.reload(reset: true); fonts.useDirectory(original) }
        let face = try XCTUnwrap(fonts.importFont(data: bytes, originalName: "ReaderTestFont.ttf").first)
        let store = store(); let library = library(); store.attach(library)
        library.settings.preferences.fontName = face.postScriptName
        XCTAssertThrowsError(try store.exportCurrent(name: "缺少许可"))
        let data = try store.exportCurrent(name: "竹影原创字体", fontLicense: "Original test font: redistribution is permitted for this test fixture.")
        fonts.reload(reset: true)
        let imported = try store.importPackage(data)
        try await store.apply(imported)
        XCTAssertEqual(library.settings.preferences.fontName, face.postScriptName)
        XCTAssertEqual(library.settings.preferences.fontResourceHash, FileResourceStore.digest(bytes))
        let installed = try XCTUnwrap(fonts.entries.first { $0.postScriptName == face.postScriptName })
        XCTAssertEqual(try Data(contentsOf: fonts.directory.appendingPathComponent(installed.filename)), bytes)
    }
    func testNightAccentAndLegacySecondaryTextRemainReadable() {
        let palette = AppThemePalette(appearance: .night)
        var white: CGFloat = 1, alpha: CGFloat = 0
        XCTAssertTrue(UIColor(palette.onAccent).getWhite(&white, alpha: &alpha))
        XCTAssertEqual(white, 0); XCTAssertEqual(alpha, 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(palette.legacyColor(0x7A856F, role: "text.secondary")).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(red, 182.0 / 255, accuracy: 0.001)
        XCTAssertEqual(green, 177.0 / 255, accuracy: 0.001)
        XCTAssertEqual(blue, 201.0 / 255, accuracy: 0.001)
    }
    func testNativePreviewTaskIdentityIsStableAcrossRendersAndChangesWithAppearance() throws {
        var settings = try GlobalThemeStore.settings(for: bundle(), current: .init(), options: .init())
        let identities = Set((0..<100).map { _ in GlobalThemePreview.fingerprint(settings) })
        XCTAssertEqual(identities.count, 1, "State updates must not restart SVG rendering indefinitely")
        settings.preferences.colors?.accent = 0x123456
        XCTAssertFalse(identities.contains(GlobalThemePreview.fingerprint(settings)))
    }
}
