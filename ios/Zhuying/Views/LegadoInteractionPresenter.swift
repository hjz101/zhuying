import SwiftUI
import UIKit

extension View {
    /// Install once on the root. UIKit presents from the active top controller,
    /// including an existing reader cover or a sheet containing a login form.
    func legadoInteractionPresenter() -> some View { modifier(LegadoInteractionPresenterModifier()) }
}

private struct LegadoInteractionPresenterModifier: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var interactions = LegadoInteractionCoordinator.shared
    func body(content: Content) -> some View {
        content.background(LegadoInteractionPresentationHost(request: interactions.request, library: library).frame(width: 0, height: 0))
    }
}

private struct LegadoInteractionPresentationHost: UIViewControllerRepresentable {
    let request: LegadoBrowserRequest?
    let library: LibraryStore
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController(); controller.view.backgroundColor = .clear; controller.view.isUserInteractionEnabled = false
        context.coordinator.anchor = controller
        return controller
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { context.coordinator.update(request: request, library: library) }
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var anchor: UIViewController?
        private var hosted: UIViewController?
        private var hostedID: UUID?
        private var pending: Task<Void, Never>?
        func update(request: LegadoBrowserRequest?, library: LibraryStore) {
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                guard let self else { return }
                if let hosted, hostedID != request?.id {
                    while hosted.isBeingPresented {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    }
                    if hosted.presentingViewController != nil {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in hosted.dismiss(animated: true) { continuation.resume() } }
                    }
                    self.hosted = nil; hostedID = nil
                }
                guard let request, LegadoInteractionCoordinator.shared.request?.id == request.id else { return }
                if hostedID == request.id { return }
                while !Task.isCancelled, LegadoInteractionCoordinator.shared.request?.id == request.id {
                    guard let controller = topmost(), controller.viewIfLoaded?.window != nil, !controller.isBeingPresented, !controller.isBeingDismissed,
                          !(controller is UIAlertController) else {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        continue
                    }
                    let browser = UIHostingController(rootView: LegadoBrowserInteractionView(request: request).environmentObject(library))
                    browser.modalPresentationStyle = .pageSheet
                    hosted = browser; hostedID = request.id
                    controller.present(browser, animated: true) { [weak self, weak browser] in browser?.presentationController?.delegate = self }
                    return
                }
            }
        }
        private func topmost() -> UIViewController? {
            let window = anchor?.viewIfLoaded?.window ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first { $0.isKeyWindow }
            var current = window?.rootViewController
            while let next = current?.presentedViewController, !next.isBeingDismissed { current = next }
            return current
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === hosted else { return }
            if let hostedID { LegadoInteractionCoordinator.shared.dismiss(id: hostedID) }
            hosted = nil; hostedID = nil
        }
        func close() {
            pending?.cancel(); pending = nil
            if let hostedID { LegadoInteractionCoordinator.shared.dismiss(id: hostedID) }
            hosted?.dismiss(animated: false); hosted = nil; hostedID = nil
        }
    }
}
