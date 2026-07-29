import XCTest
@testable import Legado

final class DZMReaderLayoutTests: XCTestCase {
    func testPaperThemeUsesFlatLegacyReaderColours() {
        XCTAssertTrue(DZM_READ_BG_COLORS.first?.isEqual(ReaderThemePreset.paper.uiBackgroundColor) == true)
        XCTAssertTrue(DZMReadConfigure.shared().textColor.isEqual(ReaderThemePreset.paper.uiTextColor))
        XCTAssertTrue(DZMReadConfigure.shared().statusTextColor.isEqual(ReaderThemePreset.paper.uiTextColor))
    }

    func testMenuLayoutKeepsControlsInsideDynamicIslandAndHomeIndicatorSafeAreas() {
        let layout = DZMReadMenuLayout(
            contentBounds: CGRect(x: 0, y: 0, width: 402, height: 874),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        )

        let top = layout.topFrame(isShown: true)
        let bottom = layout.bottomFrame(isShown: true)
        let settings = layout.settingFrame(isShown: true)

        XCTAssertEqual(top.height, 103)
        XCTAssertEqual(bottom.maxY, 874)
        XCTAssertEqual(bottom.height, DZM_READ_MENU_PROGRESS_VIEW_HEIGHT + DZM_READ_MENU_FUNC_VIEW_HEIGHT + 34)
        XCTAssertEqual(settings.maxY, 874)
        XCTAssertEqual(settings.height, DZM_READ_MENU_SETTING_VIEW_HEIGHT + 34)
    }

    func testReadingBoundsUseFullScreenInsteadOfSafeArea() {
        _ = DZMReadLayoutMetrics.update(
            bounds: CGRect(x: 0, y: 0, width: 402, height: 874),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        )

        XCTAssertEqual(DZM_READ_RECT.minY, DZM_SPACE_SA_8)
        XCTAssertEqual(DZM_READ_RECT.maxY, 874 - DZM_SPACE_SA_8)
        XCTAssertEqual(DZM_READ_VIEW_RECT, DZM_READ_RECT)
    }
}
