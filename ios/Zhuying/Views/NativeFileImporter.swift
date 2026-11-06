import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Import a materialized copy rather than keeping a provider's temporary URL.
/// The system picker downloads iCloud/provider files before reporting selection.
struct NativeFileImporter: UIViewControllerRepresentable {
    var allowedContentTypes: [UTType]
    var allowsMultipleSelection = false
    var dismiss: () -> Void = {}
    let completion: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss, completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Some providers label JSON, fonts and archives as generic data. Allow
        // those files to be selected; each importer validates the actual bytes.
        let types = allowedContentTypes.contains(.item) ? [.item] : allowedContentTypes + [.data]
        let picker = ImportDocumentPicker(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        let coordinator = context.coordinator
        picker.didDisappear = { coordinator.didDismiss() }
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: Coordinator) { coordinator.didDismiss() }

    private final class ImportDocumentPicker: UIDocumentPickerViewController {
        var didDisappear: (() -> Void)?
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            didDisappear?()
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let dismiss: () -> Void
        private let completion: (Result<[URL], Error>) -> Void
        private var pending: Result<[URL], Error>?
        private var selected = false
        private var dismissed = false
        private var completed = false
        init(dismiss: @escaping () -> Void = {}, completion: @escaping (Result<[URL], Error>) -> Void) {
            self.dismiss = dismiss; self.completion = completion
        }
        private func finish(_ result: Result<[URL], Error>) {
            guard !selected else { return }; selected = true
            pending = result
            dismiss()
            deliverIfReady()
        }
        func didDismiss() { dismissed = true; deliverIfReady() }
        private func deliverIfReady() {
            guard dismissed, !completed, let pending else { return }; completed = true
            self.pending = nil
            completion(pending)
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
    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            // The coordinator owns the handoff. UIKit may dismiss Files before
            // or after its selection callback; SwiftUI onDismiss is not a result
            // delivery mechanism for a picker that can dismiss itself.
            NativeFileImporter(allowedContentTypes: allowedContentTypes, allowsMultipleSelection: allowsMultipleSelection,
                               dismiss: { isPresented = false }, completion: completion).ignoresSafeArea()
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
