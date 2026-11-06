import SwiftUI
import UniformTypeIdentifiers

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
    static func prepare(_ data: Data, filename: String) throws -> ExportFile {
        guard !data.isEmpty, !filename.contains("/"), !filename.contains("\\") else { throw ContentFailure.invalidResponse }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        do { try data.write(to: url, options: .atomic); return .init(url: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

/// Uses the system Files export picker, preserving the source archive and
/// deleting only our private staging directory when the sheet closes.
struct NativeFileExporter: UIViewControllerRepresentable {
    let file: ExportFile
    let completion: (Result<URL, Error>) -> Void
    func makeCoordinator() -> Coordinator { .init(file: file, completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: UIDocumentPickerViewController, coordinator: Coordinator) { coordinator.clean() }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let file: ExportFile
        let completion: (Result<URL, Error>) -> Void
        init(file: ExportFile, completion: @escaping (Result<URL, Error>) -> Void) { self.file = file; self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { completion(.failure(ContentFailure.storageFailure)); return }
            completion(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(.failure(CocoaError(.userCancelled))) }
        func clean() { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    }
}
