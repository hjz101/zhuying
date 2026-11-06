import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Import a materialized copy rather than keeping a provider's temporary URL.
/// The system picker downloads iCloud/provider files before reporting selection.
struct NativeFileImporter: UIViewControllerRepresentable {
    var allowedContentTypes: [UTType]
    var allowsMultipleSelection = false
    let completion: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Some providers label JSON, fonts and archives as generic data. Allow
        // those files to be selected; each importer validates the actual bytes.
        let types = allowedContentTypes.contains(.item) ? [.item] : allowedContentTypes + [.data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Result<[URL], Error>) -> Void
        private var completed = false
        init(completion: @escaping (Result<[URL], Error>) -> Void) { self.completion = completion }
        private func finish(_ result: Result<[URL], Error>) {
            guard !completed else { return }; completed = true
            completion(result)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { finish(.failure(CocoaError(.fileReadUnknown))); return }
            finish(.success(urls))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.failure(CocoaError(.userCancelled)))
        }
    }
}

private struct NativeFileImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let completion: (Result<[URL], Error>) -> Void
    @State private var pending: Result<[URL], Error>?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            // Process only after Files has closed. Import results may themselves
            // present alerts or confirmation dialogs, which otherwise get lost.
            let result = pending; pending = nil
            if let result { completion(result) }
        }) {
            NativeFileImporter(allowedContentTypes: allowedContentTypes, allowsMultipleSelection: allowsMultipleSelection) { result in
                pending = result; isPresented = false
            }.ignoresSafeArea()
        }
    }
}

extension View {
    func nativeFileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool,
                            onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View {
        modifier(NativeFileImportModifier(isPresented: isPresented, allowedContentTypes: allowedContentTypes,
                                         allowsMultipleSelection: allowsMultipleSelection, completion: onCompletion))
    }
    func nativeFileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                            onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        nativeFileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, allowsMultipleSelection: false) { result in
            onCompletion(result.flatMap { urls in
                guard let url = urls.first else { return .failure(CocoaError(.fileReadUnknown)) }
                return .success(url)
            })
        }
    }
}
