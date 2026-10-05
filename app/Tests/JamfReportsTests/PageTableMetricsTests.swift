import XCTest
@testable import JamfReports

final class PageTableMetricsTests: XCTestCase {

    func testAShortListStopsAtItsRows() {
        // 32 header + 5 * 28 = 172, well inside a 760 pt viewport.
        XCTAssertEqual(PageTableMetrics.height(rows: 5, viewport: 760), 172)
        XCTAssertEqual(PageTableMetrics.height(rows: 0, viewport: 760), 60, "one row's height")
    }

    /// A long list is one screenful, not the 200 pt (seven rows) it was before, and not the
    /// whole list.
    func testALongListFillsTheViewportLessWhatThePageKeepsBack() {
        XCTAssertEqual(PageTableMetrics.height(rows: 500, viewport: 760), 640)
        XCTAssertEqual(PageTableMetrics.height(rows: 500, viewport: 1000), 880)
        XCTAssertGreaterThan(PageTableMetrics.height(rows: 500, viewport: 760), 200)
    }

    func testAShortViewportStillShowsAFewRows() {
        XCTAssertEqual(PageTableMetrics.height(rows: 500, viewport: 100), 32 + 3 * 28)
    }

    func testAnUnusableViewportShowsEveryRow() {
        XCTAssertEqual(PageTableMetrics.height(rows: 10, viewport: 0), 312)
        XCTAssertEqual(PageTableMetrics.height(rows: 10, viewport: .infinity), 312)
        XCTAssertEqual(PageTableMetrics.height(rows: 10, viewport: .nan), 312)
    }

    /// The Health Audit's six findings sat in a 264 pt table (36 pt a row plus 48), which drew
    /// a seventh, empty striped row under them.
    func testAShortListOfRichRowsStopsAtItsRows() {
        let height = PageTableMetrics.height(
            rows: 6, rowHeight: PageTableMetrics.richRowHeight, viewport: 900)
        XCTAssertEqual(height, 32 + 6 * 30)
        XCTAssertLessThan(height, 264)
    }

    func testTallerRowsScaleTheContentHeight() {
        XCTAssertEqual(PageTableMetrics.contentHeight(rows: 4, rowHeight: 40), 192)
    }
}
