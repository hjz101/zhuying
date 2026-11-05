import XCTest
@testable import Yueshan

@MainActor final class ManagedFontLibraryTests: XCTestCase {
    private var root: URL!
    private let fontName = "YueshanReaderTest-Regular"
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws {
        ReadingFontLibrary(directory: root).reload(reset: true)
        try? FileManager.default.removeItem(at: root)
    }
    private func fontData() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReaderTestFont", withExtension: "ttf")))
    }
    func testLegacyFontManifestMigratesOnceWithoutMovingFontOrChangingOriginalBytes() throws {
        let bytes = try fontData(), filename = ReadingFontLibrary.filename(for: bytes)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(filename))
        let legacy = try JSONEncoder().encode([ReadingFontEntry(postScriptName: fontName, displayName: "原创字体", filename: filename)])
        try legacy.write(to: root.appendingPathComponent("fonts.json"))
        let fonts = ReadingFontLibrary(directory: root, managed: true)
        XCTAssertEqual(try fonts.prepareManagedStorage(), legacy)
        XCTAssertEqual(try fonts.prepareManagedStorage(), legacy)
        XCTAssertEqual(fonts.entries.count, 1)
        XCTAssertEqual(fonts.entries.first?.resource?.digest, FileResourceStore.digest(bytes))
        XCTAssertTrue(ReadingFontLibrary.usesFile(fontName, url: root.appendingPathComponent(filename)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("fonts.v1.original.json")), legacy)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(filename)), bytes)
    }
    func testMissingFontRemainsInManifestWhileNewImportDoesNotEraseItsMetadata() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = ReadingFontEntry(postScriptName: "MissingSavedFont", displayName: "未找到的旧字体", filename: String(repeating: "a", count: 64) + ".font")
        try JSONEncoder().encode([missing]).write(to: root.appendingPathComponent("fonts.json"))
        let fonts = ReadingFontLibrary(directory: root, managed: true)
        _ = try fonts.prepareManagedStorage()
        XCTAssertTrue(fonts.entries.isEmpty); XCTAssertNotNil(fonts.message)
        _ = try fonts.importFont(data: fontData(), originalName: "font.ttf")
        let manifest = try JSONDecoder().decode(FontLibraryManifest.self, from: Data(contentsOf: root.appendingPathComponent("fonts.json")))
        XCTAssertTrue(manifest.entries.contains { $0.postScriptName == missing.postScriptName })
        XCTAssertEqual(fonts.entries.map(\.postScriptName), [fontName])
    }
    func testCorruptOrUnsupportedManifestIsPreservedAndMigrationDoesNotSilentlyResetIt() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for bytes in [Data("broken".utf8), Data("{\"version\":99,\"entries\":[]}".utf8)] {
            try bytes.write(to: root.appendingPathComponent("fonts.json"))
            let fonts = ReadingFontLibrary(directory: root, managed: true)
            XCTAssertThrowsError(try fonts.prepareManagedStorage())
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("fonts.json")), bytes)
        }
    }
}
