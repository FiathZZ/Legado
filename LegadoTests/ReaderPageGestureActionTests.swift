import XCTest
@testable import Legado

final class ReaderPageGestureActionTests: XCTestCase {
    func testCentralTapStillTogglesControlsAfterHorizontalPageSwipe() {
        let size = CGSize(width: 300, height: 600)

        XCTAssertEqual(
            ReaderPageGestureAction.resolve(
                translation: CGSize(width: -90, height: 0),
                location: CGPoint(x: 150, y: 300),
                in: size
            ),
            .nextPage
        )
        XCTAssertEqual(
            ReaderPageGestureAction.resolve(
                translation: .zero,
                location: CGPoint(x: 150, y: 300),
                in: size
            ),
            .toggleControls
        )
    }

    func testScreenCenterTapUsesAbsoluteViewportCoordinates() {
        let size = CGSize(width: 360, height: 720)

        XCTAssertEqual(
            ReaderPageGestureAction.resolveTap(
                location: CGPoint(x: size.width / 2, y: size.height / 2),
                in: size
            ),
            .toggleControls
        )
    }
}
