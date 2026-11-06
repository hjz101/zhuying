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
    var insets: UIEdgeInsets = UIEdgeInsets(top: 24, left: 25, bottom: 20, right: 25)
    var onComment: (Int) -> Void = { _ in }
    var onManualScroll: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = insets
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "continuousText"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false; tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.textContainerInset = insets
        if coordinator.layoutID != layoutID || coordinator.restoreID != restoreID || coordinator.displayedText !== document.text {
            coordinator.layoutID = layoutID
            coordinator.restoreID = restoreID
            coordinator.displayedText = document.text
            coordinator.restoring = true
            coordinator.textRevision += 1
            let revision = coordinator.textRevision
            view.attributedText = document.text
            DispatchQueue.main.async {
                guard coordinator.textRevision == revision else { return }
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

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ContinuousReaderText
        var layoutID = ""
        var restoreID = -1
        var lastTurn = 0
        var restoring = false
        var displayedText: NSAttributedString?
        var textRevision = 0
        init(_ parent: ContinuousReaderText) { self.parent = parent }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.onManualScroll() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !restoring, let view = scrollView as? UITextView, parent.document.text.length > 0 else { return }
            let point = CGPoint(x: 0, y: max(0, view.contentOffset.y - view.textContainerInset.top + 8))
            let glyph = view.layoutManager.glyphIndex(for: point, in: view.textContainer)
            guard glyph < view.layoutManager.numberOfGlyphs else { return }
            let index = view.layoutManager.characterIndexForGlyph(at: glyph)
            let anchor = parent.document.anchor(at: index)
            let generation = layoutID
            let revision = restoreID
            let textRevision = textRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.restoring, self.layoutID == generation, self.restoreID == revision, self.textRevision == textRevision else { return }
                self.parent.onAnchor(anchor)
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (gestureRecognizer.view as? UITextView)?.selectedRange.length == 0
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            if let textView = view as? UITextView {
                let location = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
                if let paragraph = ReaderDocument.comment(at: location, text: parent.document.text, size: textView.textContainer.size) {
                    parent.onComment(paragraph); return
                }
            }
            parent.onTap(point.x / max(1, view.bounds.width))
        }
    }
}

/// Text and gestures share one stable native canvas while the displayed page changes.
struct PagedReaderText: UIViewRepresentable {
    let text: NSAttributedString
    let onTap: (Double) -> Void
    let onSwipe: (Bool) -> Void
    var mode: ReadingMode = .paged
    var effect = "平移"
    var pageID = 0
    var layoutID = ""
    var paperColor: UIColor = .clear
    var onComment: (Int) -> Void = { _ in }
    var documentFrame: CGRect? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ReaderPageCanvas {
        let view = ReaderPageCanvas()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator; pan.delegate = context.coordinator
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap); view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: ReaderPageCanvas, context: Context) {
        context.coordinator.parent = self
        view.onTap = onTap; view.onSwipe = onSwipe
        view.documentFrame = documentFrame
        view.backgroundColor = paperColor
        view.textView.backgroundColor = paperColor
        guard !view.textView.attributedText.isEqual(to: text) else { return }
        let forward = pageID >= view.lastPageID
        let shouldAnimate = view.lastLayoutID == layoutID && pageID != view.lastPageID && view.hasText && !UIAccessibility.isReduceMotionEnabled
        view.lastLayoutID = layoutID; view.lastPageID = pageID; view.hasText = true
        view.textView.selectedRange = NSRange(location: 0, length: 0)
        if shouldAnimate && effect == "仿真" && mode == .paged {
            UIView.transition(with: view.textView, duration: 0.5, options: [forward ? .transitionCurlUp : .transitionCurlDown, .allowAnimatedContent, .allowUserInteraction, .beginFromCurrentState]) {
                view.textView.attributedText = text
            }
        } else {
            if shouldAnimate && effect != "无动画" {
                let transition = CATransition(); transition.duration = 0.28
                transition.type = effect == "覆盖" ? .moveIn : .push
                transition.subtype = mode == .verticalPaged ? (forward ? .fromBottom : .fromTop) : (forward ? .fromRight : .fromLeft)
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.textView.layer.add(transition, forKey: "reading-page")
            }
            view.textView.attributedText = text
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderPageCanvas, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 350, height: proposal.height ?? 500)
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PagedReaderText
        init(_ parent: PagedReaderText) { self.parent = parent }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let canvas = gestureRecognizer.view as? ReaderPageCanvas, canvas.textView.selectedRange.length == 0 else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let movement = pan.translation(in: canvas)
                return ReaderInteraction.acceptsPageDrag(movement, mode: parent.mode, selectedLength: canvas.textView.selectedRange.length)
            }
            return true
        }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            if let canvas = view as? ReaderPageCanvas {
                let local = CGPoint(x: point.x - canvas.textView.frame.minX, y: point.y - canvas.textView.frame.minY)
                if let paragraph = ReaderDocument.comment(at: local, text: parent.text, size: canvas.textView.bounds.size) { parent.onComment(paragraph); return }
            }
            parent.onTap(point.x / max(1, view.bounds.width))
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let movement = recognizer.translation(in: recognizer.view)
            if parent.mode == .verticalPaged {
                if abs(movement.y) > 45 && abs(movement.y) > abs(movement.x) { parent.onSwipe(movement.y < 0) }
            } else if abs(movement.x) > 45 && abs(movement.x) > abs(movement.y) { parent.onSwipe(movement.x < 0) }
        }
    }
}

final class ReaderPageCanvas: UIView {
    let textView = UITextView()
    var lastPageID = 0
    var lastLayoutID = ""
    var hasText = false
    var onTap: (Double) -> Void = { _ in }
    var onSwipe: (Bool) -> Void = { _ in }
    var documentFrame: CGRect? { didSet { if documentFrame != oldValue { setNeedsLayout() } } }
    private var zones: [ReaderTapAccessibilityElement] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "readerTouchSurface"
        isAccessibilityElement = false
        textView.accessibilityIdentifier = "pagedText"
        textView.isEditable = false; textView.isSelectable = true; textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = true
        textView.backgroundColor = .clear; textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        addSubview(textView)
        for (id, label, fraction) in [("readerTapLeft", "轻触左侧", 0.1), ("readerTapCenter", "显示或隐藏阅读工具栏", 0.5), ("readerTapRight", "轻触右侧", 0.9)] {
            let zone = ReaderTapAccessibilityElement(accessibilityContainer: self)
            zone.accessibilityIdentifier = id; zone.accessibilityLabel = label; zone.accessibilityTraits = .button
            zone.activate = { [weak self] in self?.onTap(fraction) }
            zones.append(zone)
        }
        accessibilityElements = zones.map { $0 as Any } + [textView]
        textView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "下一页") { [weak self] _ in self?.onSwipe(true); return true },
            UIAccessibilityCustomAction(name: "上一页") { [weak self] _ in self?.onSwipe(false); return true },
            UIAccessibilityCustomAction(name: "显示或隐藏阅读工具栏") { [weak self] _ in self?.onTap(0.5); return true }
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); textView.frame = documentFrame ?? bounds
        for (index, zone) in zones.enumerated() {
            let start: CGFloat = index == 0 ? 0 : index == 1 ? 0.3 : 0.7
            zone.accessibilityFrameInContainerSpace = CGRect(x: bounds.width * start, y: 0, width: bounds.width * (index == 1 ? 0.4 : 0.3), height: bounds.height)
        }
    }
}

final class ReaderTapAccessibilityElement: UIAccessibilityElement {
    var activate: () -> Void = {}
    override func accessibilityActivate() -> Bool { activate(); return true }
}
