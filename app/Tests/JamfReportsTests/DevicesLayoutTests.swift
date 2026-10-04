import XCTest
@testable import JamfReports

final class DevicesLayoutTests: XCTestCase {

    /// The width the Devices view measures is the page's, padding included. The window is at
    /// least 960 wide; the sidebar is 232 above 1100 and 64 below it.
    private func pageWidth(window: CGFloat) -> CGFloat {
        window - (window < 1100 ? Theme.Metrics.sidebarWidthCompact
                                : Theme.Metrics.sidebarWidthExpanded)
    }

    func testTheNarrowestWindowsStackThePanelUnderTheTable() {
        for window: CGFloat in [960, 1099, 1100, 1200, 1300] {
            XCTAssertFalse(
                DevicesView.detailFitsBeside(pageWidth: pageWidth(window: window)), "\(window)")
        }
    }

    func testAWideWindowKeepsThePanelBesideTheTable() {
        for window: CGFloat in [1400, 1470, 1728, 2560] {
            XCTAssertTrue(
                DevicesView.detailFitsBeside(pageWidth: pageWidth(window: window)), "\(window)")
        }
    }

    /// 700 for the table, 360 for the panel, 14 between and the page padding on both sides.
    func testTheThresholdIsTheTableMinimumPlusThePanel() {
        let edge = DevicesView.minInventoryTableWidth + DevicesView.detailPanelWidth + 14
            + 2 * Theme.Metrics.pagePadH
        XCTAssertTrue(DevicesView.detailFitsBeside(pageWidth: edge))
        XCTAssertFalse(DevicesView.detailFitsBeside(pageWidth: edge - 1))
        XCTAssertEqual(edge, 1130)
    }
}
