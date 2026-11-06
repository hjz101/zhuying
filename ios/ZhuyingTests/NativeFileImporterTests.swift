import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import Zhuying

@MainActor final class NativeFileImporterTests: XCTestCase {
    func testSelectionDeliversAllProviderCopiesExactlyOnce() throws {
        let urls = [URL(fileURLWithPath: "/tmp/竹影导入.txt"), URL(fileURLWithPath: "/tmp/竹影套装.json")]
        var results: [Result<[URL], Error>] = []
        let coordinator = NativeFileImporter.Coordinator { results.append($0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        coordinator.documentPicker(picker, didPickDocumentsAt: urls)
        coordinator.documentPickerWasCancelled(picker)
        coordinator.documentPicker(picker, didPickDocumentsAt: urls)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results.first?.get(), urls)
    }

    func testCancellationAndEmptySelectionCannotSilentlySucceed() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        var cancellations: [NSError] = []
        let cancelled = NativeFileImporter.Coordinator { if case .failure(let error) = $0 { cancellations.append(error as NSError) } }
        cancelled.documentPickerWasCancelled(picker)
        cancelled.documentPicker(picker, didPickDocumentsAt: [])
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertEqual(cancellations.first?.code, NSUserCancelledError)
        var emptyFailed = false
        let empty = NativeFileImporter.Coordinator { if case .failure = $0 { emptyFailed = true } }
        empty.documentPicker(picker, didPickDocumentsAt: [])
        XCTAssertTrue(emptyFailed)
    }

    func testCoordinatedReadPreservesUnicodeNameAndOriginalBytesAtExactLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("竹影 阅读样本👩🏽‍🚀.txt")
        let data = Data("第一章 山海\n这是实际从文件读取的正文。👩🏽‍🚀".utf8)
        try data.write(to: url)
        XCTAssertEqual(try ImportedFileReader.read(url, maximumBytes: data.count), data)
        XCTAssertThrowsError(try ImportedFileReader.read(url, maximumBytes: data.count - 1))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertThrowsError(try ImportedFileReader.read(directory, maximumBytes: 1024))
        XCTAssertThrowsError(try ImportedFileReader.read(directory.appendingPathComponent("不存在.txt"), maximumBytes: 1024))
        try Data().write(to: url)
        XCTAssertThrowsError(try ImportedFileReader.read(url, maximumBytes: 1024))
        XCTAssertThrowsError(try ImportedFileReader.read(URL(string: "https://example.invalid/file.json")!, maximumBytes: 1024))
    }

    func testSelectedLocalFileBecomesRealBookWithoutNeedingOriginalURLLater() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("竹影本地文件.txt")
        try Data("第一章 来信\n正文来自本地文件，不是演示样本。\n第二章 远山\n山间来信。".utf8).write(to: url)
        let prepared = try await BookImporter.load(.file(url), encoding: .automatic)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(prepared.book.title, "竹影本地文件")
        XCTAssertEqual(prepared.book.chapters, ["第一章 来信", "第二章 远山"])
        XCTAssertEqual(prepared.book.content[1], ["山间来信。"])
    }
}
