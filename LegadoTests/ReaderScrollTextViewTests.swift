import XCTest
import UIKit
@testable import Legado

@MainActor
final class ReaderScrollTextViewTests: XCTestCase {
    func testScrollPositionReportsOffsetAfterDecelerating() {
        var reportedOffsets: [Int] = []
        let coordinator = ReaderScrollTextView.Coordinator(
            onVisibleUTF16OffsetChanged: { reportedOffsets.append($0) }
        )
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        textView.text = String(repeating: "滚动位置需要持续上报。\n", count: 200)
        textView.layoutIfNeeded()
        textView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)

        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)

        XCTAssertFalse(reportedOffsets.isEmpty)
    }

    func testTextViewInstallsCenterTapRecognizerWithoutCancellingTouches() {
        let hostView = ReaderScrollTextViewHostView(onCenterTap: {})

        XCTAssertTrue(hostView.textView.gestureRecognizers?.contains(hostView.centerTapRecognizer) == true)
        XCTAssertFalse(hostView.centerTapRecognizer.cancelsTouchesInView)
    }

    func testCenterTapRecognizerCoexistsWithTextViewPanRecognizer() {
        let hostView = ReaderScrollTextViewHostView(onCenterTap: {})

        XCTAssertTrue(
            hostView.gestureRecognizer(
                hostView.centerTapRecognizer,
                shouldRecognizeSimultaneouslyWith: hostView.textView.panGestureRecognizer
            )
        )
    }

    func testScrolledTextViewCenterTapRoutesToMenuAction() {
        var menuOpenCount = 0
        let hostView = ReaderScrollTextViewHostView(onCenterTap: { menuOpenCount += 1 })
        hostView.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        hostView.layoutIfNeeded()
        hostView.textView.bounds.origin = CGPoint(x: 0, y: 900)

        let visibleCenter = CGPoint(x: hostView.textView.bounds.midX, y: hostView.textView.bounds.midY)
        hostView.handleTap(at: visibleCenter)

        XCTAssertEqual(menuOpenCount, 1)
    }
}
