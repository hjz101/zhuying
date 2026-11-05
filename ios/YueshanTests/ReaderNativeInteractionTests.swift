import XCTest
import UIKit
@testable import Yueshan

@MainActor final class ReaderNativeInteractionTests: XCTestCase {
    func testPageSupportsTextSelectionAndAccessibleTapActions() throws {
        let view = ReaderPageCanvas(frame: CGRect(x: 0, y: 0, width: 350, height: 600))
        let proseFrame = CGRect(x: 25, y: 60, width: 300, height: 480)
        view.documentFrame = proseFrame
        view.layoutIfNeeded()
        XCTAssertEqual(view.textView.frame, proseFrame)
        XCTAssertTrue(view.textView.isSelectable); XCTAssertFalse(view.textView.isEditable)
        XCTAssertTrue(view.textView.isUserInteractionEnabled)
        var taps: [Double] = []; view.onTap = { taps.append($0) }
        let elements = try XCTUnwrap(view.accessibilityElements?.compactMap { $0 as? ReaderTapAccessibilityElement })
        XCTAssertEqual(elements.map(\.accessibilityIdentifier), ["readerTapLeft", "readerTapCenter", "readerTapRight"])
        for element in elements {
            XCTAssertTrue(element.accessibilityActivate())
            XCTAssertTrue(element.accessibilityTraits.contains(.button))
            XCTAssertGreaterThan(element.accessibilityFrameInContainerSpace.width, 44)
            XCTAssertEqual(element.accessibilityFrameInContainerSpace.height, view.bounds.height, "Page margins remain tappable without covering selectable prose")
        }
        XCTAssertEqual(taps, [0.1, 0.5, 0.9])
        XCTAssertEqual(view.textView.accessibilityCustomActions?.map(\.name), ["下一页", "上一页", "显示或隐藏阅读工具栏"])
    }
    func testSelectionPreventsPageGesturesAndWrongAxisDoesNotTurnPages() {
        let page = PagedReaderText(text: NSAttributedString(string: "可选择的真实文字"), onTap: { _ in }, onSwipe: { _ in })
        let coordinator = page.makeCoordinator()
        let view = ReaderPageCanvas(frame: CGRect(x: 0, y: 0, width: 350, height: 600))
        view.textView.text = "可选择的真实文字"
        let pan = UIPanGestureRecognizer(); view.addGestureRecognizer(pan)
        XCTAssertTrue(ReaderInteraction.acceptsPageDrag(CGPoint(x: 80, y: 2), mode: .paged, selectedLength: 0))
        view.textView.selectedRange = NSRange(location: 1, length: 3)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
        view.textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(ReaderInteraction.acceptsPageDrag(CGPoint(x: 2, y: 80), mode: .paged, selectedLength: 0))
        coordinator.parent.mode = .verticalPaged
        XCTAssertTrue(ReaderInteraction.acceptsPageDrag(CGPoint(x: 2, y: 80), mode: .verticalPaged, selectedLength: 0))
    }
}
