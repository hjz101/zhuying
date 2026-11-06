import XCTest
import UIKit
import CoreText
@testable import Zhuying

@MainActor
final class ReadingFontLibraryTests: XCTestCase {
    private struct FontFixture {
        let url: URL
        let data: Data
        let names: [String]
    }
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zhuying-font-tests-\(UUID().uuidString)", isDirectory: true)
    }
    private func readableSystemFont() throws -> FontFixture {
        for name in ["Georgia", "TimesNewRomanPSMT", "CourierNewPSMT", "Helvetica", "HelveticaNeue"] {
            guard UIFont(name: name, size: 18) != nil,
                  let url = CTFontCopyAttribute(CTFontCreateWithName(name as CFString, 18, nil), kCTFontURLAttribute) as? URL,
                  let data = try? Data(contentsOf: url), !data.isEmpty,
                  let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] else { continue }
            let names = Array(Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })).sorted()
            if !names.isEmpty && names.allSatisfy({ ReadingFontLibrary.usesFile($0, url: url) }) {
                return .init(url: url, data: data, names: names)
            }
        }
        throw XCTSkip("本运行时没有可读取并完整解析的公开系统字体文件。")
    }
    private func linkFixture(_ fixture: FontFixture, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(ReadingFontLibrary.filename(for: fixture.data))
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.url)
        return target
    }

    func testInvalidFontImportDoesNotCreateFilesOrEntries() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let fonts = ReadingFontLibrary(directory: path)
        XCTAssertThrowsError(try fonts.importFont(data: Data("invalid font".utf8), originalName: "invalid.ttf"))
        XCTAssertThrowsError(try fonts.importFont(data: Data(), originalName: "empty.ttf"))
        XCTAssertThrowsError(try fonts.importFont(data: Data(repeating: 0, count: 20 * 1024 * 1024 + 1), originalName: "huge.ttf"))
        XCTAssertTrue(fonts.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testOriginalFontImportsAppliesToBodyRestoresAndRejectsDuplicateWithoutChanges() throws {
        let bundle = Bundle(for: ReadingFontLibraryTests.self)
        let source = try XCTUnwrap(bundle.url(forResource: "ReaderTestFont", withExtension: "ttf")
                                  ?? bundle.url(forResource: "ReaderTestFont", withExtension: "ttf", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: source)
        let name = "ZhuyingReaderTest-Regular"
        let path = directory()
        let fontDirectory = path.appendingPathComponent("fonts", isDirectory: true)
        let domain = "reader-original-font-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let fonts = ReadingFontLibrary(directory: fontDirectory)
        defer {
            fonts.reload(reset: true)
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: path)
        }
        XCTAssertTrue(fonts.entries.isEmpty)
        let added = try fonts.importFont(at: source)
        XCTAssertEqual(added.map(\.postScriptName), [name])
        XCTAssertEqual(fonts.entries, added)
        let target = fontDirectory.appendingPathComponent(try XCTUnwrap(added.first).filename)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertNotEqual(target.resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
        XCTAssertEqual(try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        XCTAssertTrue(ReadingFontLibrary.usesFile(name, url: target))
        let loaded = try XCTUnwrap(UIFont(name: name, size: 27))
        XCTAssertEqual(loaded.fontName, name)
        let core = CTFontCreateWithName(loaded.fontName as CFString, 27, nil)
        let actualSource = try XCTUnwrap(CTFontCopyAttribute(core, kCTFontURLAttribute) as? URL)
        XCTAssertEqual(actualSource.standardizedFileURL.resolvingSymlinksInPath(), target.standardizedFileURL.resolvingSymlinksInPath())
        var characters = Array("A0123456789".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(core, &characters, &glyphs, characters.count))
        XCTAssertTrue(glyphs.allSatisfy { $0 != 0 && CTFontCreatePathForGlyph(core, $0, nil) != nil })

        let book = Book(id: "local-font-test", title: "Font Test", author: "Test", genre: "Test", category: "Test",
                        status: "Complete", words: "11", color: "green", subtitle: "", intro: "", tags: [],
                        chapters: ["A"], content: [["A0123456789"]])
        let imports = path.appendingPathComponent("books.json")
        let reader = LibraryStore(books: [book], defaults: defaults, importsURL: imports)
        reader.settings.fontSize = 27
        reader.settings.preferences.fontName = name
        let restoredFonts = ReadingFontLibrary(directory: fontDirectory)
        XCTAssertEqual(restoredFonts.entries, added)
        XCTAssertTrue(ReadingFontLibrary.usesFile(name, url: target))
        let restoredReader = LibraryStore(books: [book], defaults: defaults, importsURL: imports)
        XCTAssertEqual(restoredReader.settings.preferences.fontName, name)
        XCTAssertEqual(ReaderTypography.font(settings: restoredReader.settings).fontName, name)
        let document = ReaderDocument(book: book, chapter: 0, settings: restoredReader.settings)
        let paragraph = try XCTUnwrap(document.paragraphRanges.first)
        let bodyFont = try XCTUnwrap(document.text.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(document.text.attributedSubstring(from: paragraph).string, "A0123456789")
        XCTAssertEqual(bodyFont.fontName, name, "The actual rendered body must use the imported face rather than a system fallback")
        XCTAssertEqual(bodyFont.pointSize, 27)
        XCTAssertTrue(ReadingFontLibrary.usesFile(bodyFont.fontName, url: target))

        let manifest = fontDirectory.appendingPathComponent("fonts.json")
        let saved = try Data(contentsOf: manifest)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: fontDirectory.path).sorted()
        XCTAssertThrowsError(try restoredFonts.importFont(data: data, originalName: "duplicate.ttf"))
        XCTAssertEqual(restoredFonts.entries, added)
        XCTAssertEqual(try Data(contentsOf: manifest), saved)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fontDirectory.path).sorted(), filenames)
        XCTAssertEqual(restoredReader.settings.preferences.fontName, name)
    }

    func testUsableFontMustResolveFromRequestedFileRatherThanJustSharingItsName() throws {
        let fixture = try readableSystemFont()
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let copy = path.appendingPathComponent("different-location.ttf")
        try fixture.data.write(to: copy)
        XCTAssertTrue(ReadingFontLibrary.usesFile(fixture.names[0], url: fixture.url))
        XCTAssertFalse(ReadingFontLibrary.usesFile(fixture.names[0], url: copy), "A same-named already available system font cannot stand in for this file")
        XCTAssertFalse(ReadingFontLibrary.usesFile("zhuying-font-does-not-exist", url: fixture.url))
    }

    func testSameCanonicalFileCanBeReusedAndMetadataSurvivesReloadWithoutDuplicates() throws {
        let fixture = try readableSystemFont()
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let target = try linkFixture(fixture, to: path)
        let fonts = ReadingFontLibrary(directory: path)
        let added = try fonts.importFont(data: fixture.data, originalName: "阅读字体.ttf")
        XCTAssertFalse(added.isEmpty)
        XCTAssertEqual(Set(added.map(\.postScriptName)).count, added.count)
        XCTAssertTrue(added.allSatisfy { ReadingFontLibrary.usesFile($0.postScriptName, url: target) })
        let saved = try Data(contentsOf: path.appendingPathComponent("fonts.json"))
        XCTAssertThrowsError(try fonts.importFont(data: fixture.data, originalName: "重复导入.ttf"))
        XCTAssertEqual(fonts.entries, added)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("fonts.json")), saved)
        let restored = ReadingFontLibrary(directory: path)
        XCTAssertEqual(restored.entries, added)
        restored.reload(reset: true)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNotNil(UIFont(name: fixture.names[0], size: 18), "Resetting an app library must not unregister the system font through a symlink")
    }

    func testManifestWriteFailureDoesNotPublishEntriesOrDeleteExistingFontFile() throws {
        let fixture = try readableSystemFont()
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let target = try linkFixture(fixture, to: path)
        let manifest = path.appendingPathComponent("fonts.json", isDirectory: true)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        let sentinel = manifest.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let fonts = ReadingFontLibrary(directory: path)
        XCTAssertThrowsError(try fonts.importFont(data: fixture.data, originalName: "阅读字体.ttf"))
        XCTAssertTrue(fonts.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: target), fixture.data)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testRegistrationFailureCleansNewFileOrSuccessUsesTheActualImportedFile() throws {
        let fixture = try readableSystemFont()
        let path = directory()
        let target = path.appendingPathComponent(ReadingFontLibrary.filename(for: fixture.data))
        defer {
            if FileManager.default.fileExists(atPath: target.path) { _ = CTFontManagerUnregisterFontsForURL(target as CFURL, .process, nil) }
            try? FileManager.default.removeItem(at: path)
        }
        let fonts = ReadingFontLibrary(directory: path)
        do {
            let added = try fonts.importFont(data: fixture.data, originalName: "与系统同名.ttf")
            // Some CoreText runtimes permit process-local registration over a system
            // face; accepting it is correct only if the registered source really moved.
            XCTAssertFalse(added.isEmpty)
            XCTAssertTrue(added.allSatisfy { ReadingFontLibrary.usesFile($0.postScriptName, url: target) })
            XCTAssertEqual(fonts.entries, added)
        } catch {
            XCTAssertTrue(fonts.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("fonts.json").path))
            XCTAssertNotNil(UIFont(name: fixture.names[0], size: 18))
        }
    }

    func testRestoreRejectsUnrelatedFontNamesAndDuplicateManifestEntries() throws {
        let fixture = try readableSystemFont()
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let target = try linkFixture(fixture, to: path)
        let valid = ReadingFontEntry(postScriptName: fixture.names[0], displayName: "有效字体", filename: target.lastPathComponent)
        var saved = [valid, valid]
        if let different = ["Helvetica", "CourierNewPSMT", "Georgia", "TimesNewRomanPSMT"].first(where: { UIFont(name: $0, size: 18) != nil && !ReadingFontLibrary.usesFile($0, url: fixture.url) }) {
            saved.append(.init(postScriptName: different, displayName: "错误来源", filename: target.lastPathComponent))
        }
        saved.append(.init(postScriptName: fixture.names[0], displayName: "越界路径", filename: "../font.ttf"))
        try JSONEncoder().encode(saved).write(to: path.appendingPathComponent("fonts.json"))
        let fonts = ReadingFontLibrary(directory: path)
        XCTAssertEqual(fonts.entries, [valid])
    }
}
