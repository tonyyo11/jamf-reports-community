import XCTest
@testable import JamfReports

final class PageTableMetricsTests: XCTestCase {

    func testAShortListStopsAtItsRows() {
        // 32 header + 14 insets + 5 * 28 = 186, well inside a 760 pt viewport.
        XCTAssertEqual(PageTableMetrics.height(rows: 5, viewport: 760), 186)
        XCTAssertEqual(PageTableMetrics.height(rows: 0, viewport: 760), 74, "one row's height")
    }

    /// A long list is one screenful, not the 200 pt (seven rows) it was before, and not the
    /// whole list.
    func testALongListFillsTheViewportLessWhatThePageKeepsBack() {
        XCTAssertEqual(PageTableMetrics.height(rows: 500, viewport: 760), 640)
        XCTAssertEqual(PageTableMetrics.height(rows: 500, viewport: 1000), 880)
        XCTAssertGreaterThan(PageTableMetrics.height(rows: 500, viewport: 760), 200)
    }

    func testAShortViewportStillShowsAFewRows() {
        XCTAssertEqual(PageTableMetrics.height(rows: 500, viewport: 100), 32 + 14 + 3 * 28)
    }

    func testAnUnusableViewportShowsEveryRow() {
        XCTAssertEqual(PageTableMetrics.height(rows: 10, viewport: 0), 326)
        XCTAssertEqual(PageTableMetrics.height(rows: 10, viewport: .infinity), 326)
        XCTAssertEqual(PageTableMetrics.height(rows: 10, viewport: .nan), 326)
    }

    /// The Health Audit's six findings sat in a 264 pt table (36 pt a row plus 48), which drew
    /// a seventh, empty striped row under them.
    func testAShortListOfRichRowsStopsAtItsRows() {
        let height = PageTableMetrics.height(
            rows: 6, rowHeight: PageTableMetrics.richRowHeight, viewport: 900)
        XCTAssertEqual(height, 32 + 14 + 6 * 30)
        XCTAssertLessThan(height, 264)
    }

    func testTallerRowsScaleTheContentHeight() {
        XCTAssertEqual(PageTableMetrics.contentHeight(rows: 4, rowHeight: 40), 206)
    }

    /// Mobile Devices' two-profile table scrolled and clipped its first row on macOS 27.3:
    /// measured, it needs a 27 pt header, 5 pt above the first row, two 23 pt rows and 9 pt
    /// below the last. The height it is given must hold all of it.
    func testATwoRowTableHoldsItsHeaderInsetsAndRows() {
        let needed: CGFloat = 27 + 5 + 2 * 23 + 9
        XCTAssertGreaterThanOrEqual(
            PageTableMetrics.contentHeight(rows: 2, rowHeight: MobileFleetView.profileRowHeight),
            needed)
        XCTAssertGreaterThanOrEqual(
            MobileFleetView.tableHeight(rows: 2, rowHeight: MobileFleetView.profileRowHeight,
                                        cap: 280), needed)
    }
}
