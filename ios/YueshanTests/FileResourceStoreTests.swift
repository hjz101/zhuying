import XCTest
@testable import Yueshan

final class FileResourceStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testNewNestedDirectoryWithoutDirectoryURLHintCanStageResources() throws {
        let path = root.appendingPathComponent("Application Support/resources/themes").path
        let directory = URL(fileURLWithPath: path, isDirectory: false)
        let store = FileResourceStore(directory: directory)
        let bytes = Data(".chapter-title {}".utf8)
        let staged = try store.stage(bytes, kind: .css)
        XCTAssertEqual(try store.read(staged.reference), bytes)
        XCTAssertEqual(try store.url(for: staged.reference).deletingLastPathComponent().path, path)
    }
    func testHashReferenceSurvivesReopenAndDetectsByteCorruption() throws {
        let store = FileResourceStore(directory: root)
        let data = Data(".chapter-title { color: #123456; }".utf8)
        let staged = try store.stage(data, kind: .css)
        XCTAssertTrue(staged.created)
        XCTAssertFalse(try store.stage(data, kind: .css).created)
        XCTAssertEqual(try FileResourceStore(directory: root).read(staged.reference), data)
        try Data("damaged".utf8).write(to: store.url(for: staged.reference))
        XCTAssertThrowsError(try store.read(staged.reference))
        XCTAssertThrowsError(try store.stage(data, kind: .css))
        _ = try store.stage(data, kind: .css, repairingCorruptFile: true)
        XCTAssertEqual(try store.read(staged.reference), data)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains(".damaged-") })
    }
    func testStartupCollectionReclaimsInterruptedStagingAndPreservesReferencesAndOriginalFiles() throws {
        let store = FileResourceStore(directory: root)
        let referenced = try store.stage(Data("kept".utf8), kind: .svg).reference
        let orphan = try store.stage(Data("interrupted".utf8), kind: .svg).reference
        let original = root.appendingPathComponent("fonts.v1.original.json")
        try Data("original".utf8).write(to: original)
        try store.collect(referenced: [referenced])
        XCTAssertEqual(try store.read(referenced), Data("kept".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: orphan).path))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }
    func testInvalidReferenceOrSymlinkCannotEscapeResourceDirectory() throws {
        let store = FileResourceStore(directory: root)
        XCTAssertThrowsError(try store.read(.init(digest: "../outside", bytes: 10, kind: .font)))
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        let data = Data("external".utf8); try data.write(to: external)
        let ref = ResourceFileReference(digest: FileResourceStore.digest(data), bytes: data.count, kind: .font)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(ref.filename), withDestinationURL: external)
        XCTAssertThrowsError(try store.read(ref))
        XCTAssertThrowsError(try store.stage(data, kind: .font))
        XCTAssertEqual(try Data(contentsOf: external), data)
    }
    private struct DenyWrite: AtomicFileWriting {
        func write(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    }
    func testReadOnlyFailureLeavesExistingCommittedBlobUsableAndRejectsOversizeInput() throws {
        let valid = FileResourceStore(directory: root)
        let old = try valid.stage(Data("old".utf8), kind: .css).reference
        let denied = FileResourceStore(directory: root, writer: DenyWrite())
        XCTAssertThrowsError(try denied.stage(Data("new".utf8), kind: .css))
        XCTAssertEqual(try denied.read(old), Data("old".utf8))
        XCTAssertThrowsError(try valid.stage(Data(repeating: 1, count: 60_001), kind: .css))
    }
}
