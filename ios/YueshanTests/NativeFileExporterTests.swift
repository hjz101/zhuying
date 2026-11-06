import XCTest
import UIKit
@testable import Yueshan

@MainActor final class NativeFileExporterTests: XCTestCase {
    func testCancellationRemovesOnlyExportStagingAndPreservesOriginalBytes() throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("原创正文与书签备份 👩🏽‍🚀".utf8)
        try bytes.write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let file = try ExportFile.prepare(Data(contentsOf: original), filename: "阅山.yueshanbackup")
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        var cancelled = false
        let coordinator = NativeFileExporter.Coordinator(file: file) { result in
            if case .failure(let error) = result { cancelled = (error as NSError).code == NSUserCancelledError }
        }
        coordinator.documentPickerWasCancelled(UIDocumentPickerViewController(forOpeningContentTypes: [.data]))
        XCTAssertTrue(cancelled)
        coordinator.clean()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertThrowsError(try ExportFile.prepare(bytes, filename: "../original"))
        XCTAssertThrowsError(try ExportFile.prepare(bytes, filename: "folder\\original"))
    }
}
