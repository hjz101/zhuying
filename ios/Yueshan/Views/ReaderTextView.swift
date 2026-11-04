import SwiftUI
import UIKit

struct ContinuousReaderText: UIViewRepresentable {
    let document: ReaderDocument
    let anchor: ReaderAnchor
    let layoutID: String
    let restoreID: Int
    let turn: Int
    let onAnchor: (ReaderAnchor) -> Void
    let onTap: (Double) -> Void
    let onBoundary: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 25, left: 25, bottom: 45, right: 25)
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "continuousText"
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.layoutID != layoutID || coordinator.restoreID != restoreID {
            coordinator.layoutID = layoutID
            coordinator.restoreID = restoreID
            coordinator.restoring = true
            view.attributedText = document.text
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                let index = self.document.index(for: self.anchor)
                let glyph = view.layoutManager.glyphIndexForCharacter(at: min(index, max(0, self.document.text.length - 1)))
                let rect = view.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer)
                let target = self.anchor == ReaderAnchor() ? 0 : rect.minY + view.textContainerInset.top - 8
                view.setContentOffset(CGPoint(x: 0, y: max(0, min(target, view.contentSize.height - view.bounds.height))), animated: false)
                coordinator.restoring = false
            }
        }
        if coordinator.lastTurn != turn {
            let forward = turn > coordinator.lastTurn
            coordinator.lastTurn = turn
            let maxY = max(0, view.contentSize.height - view.bounds.height)
            if (forward && view.contentOffset.y >= maxY - 5) || (!forward && view.contentOffset.y <= 5) {
                DispatchQueue.main.async { onBoundary(forward) }
            } else {
                view.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, view.contentOffset.y + (forward ? 1 : -1) * view.bounds.height * 0.88))), animated: true)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 350, height: proposal.height ?? 500)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ContinuousReaderText
        var layoutID = ""
        var restoreID = -1
        var lastTurn = 0
        var restoring = false
        init(_ parent: ContinuousReaderText) { self.parent = parent }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !restoring, let view = scrollView as? UITextView, parent.document.text.length > 0 else { return }
            let point = CGPoint(x: 0, y: max(0, view.contentOffset.y - view.textContainerInset.top + 8))
            let glyph = view.layoutManager.glyphIndex(for: point, in: view.textContainer)
            guard glyph < view.layoutManager.numberOfGlyphs else { return }
            let index = view.layoutManager.characterIndexForGlyph(at: glyph)
            let anchor = parent.document.anchor(at: index)
            let generation = layoutID
            let revision = restoreID
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.restoring, self.layoutID == generation, self.restoreID == revision else { return }
                self.parent.onAnchor(anchor)
            }
        }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTap(recognizer.location(in: view).x / max(1, view.bounds.width))
        }
    }
}

/// Text and gestures share one stable native canvas while the displayed page changes.
struct PagedReaderText: UIViewRepresentable {
    let text: NSAttributedString
    let onTap: (Double) -> Void
    let onSwipe: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ReaderPageCanvas {
        let view = ReaderPageCanvas()
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        return view
    }
    func updateUIView(_ view: ReaderPageCanvas, context: Context) {
        context.coordinator.parent = self
        if !view.textView.attributedText.isEqual(to: text) { view.textView.attributedText = text }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderPageCanvas, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 350, height: proposal.height ?? 500)
    }
    final class Coordinator: NSObject {
        var parent: PagedReaderText
        init(_ parent: PagedReaderText) { self.parent = parent }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTap(recognizer.location(in: view).x / max(1, view.bounds.width))
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let movement = recognizer.translation(in: recognizer.view)
            if abs(movement.x) > 45 && abs(movement.x) > abs(movement.y) { parent.onSwipe(movement.x < 0) }
        }
    }
}

final class ReaderPageCanvas: UIView {
    let textView = UITextView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "readerTouchSurface"
        isAccessibilityElement = true
        accessibilityLabel = "阅读操作区域，轻触中间显示菜单，左右滑动翻页"
        textView.isEditable = false; textView.isSelectable = false; textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear; textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); textView.frame = bounds }
}
