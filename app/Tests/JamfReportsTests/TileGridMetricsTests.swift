import Foundation
import XCTest
@testable import JamfReports

final class TileGridMetricsTests: XCTestCase {

    func testColumnsFollowTheAdaptiveGridRule() {
        // (width + spacing) / (min + spacing), floored, never below one.
        XCTAssertEqual(
            TileGridMetrics.columns(width: 916, minTileWidth: 220, spacing: 12, count: 8), 4)
        XCTAssertEqual(
            TileGridMetrics.columns(width: 915, minTileWidth: 220, spacing: 12, count: 8), 3)
        XCTAssertEqual(
            TileGridMetrics.columns(width: 100, minTileWidth: 220, spacing: 12, count: 8), 1)
    }

    func testColumnsNeverOutnumberTheTiles() {
        // Room for six, but four tiles stretch across the row rather than
        // leaving two empty columns — what the Fleet Overview HStack did.
        XCTAssertEqual(
            TileGridMetrics.columns(width: 1400, minTileWidth: 200, spacing: 12, count: 4), 4)
    }

    func testColumnsSurviveUnusableWidths() {
        XCTAssertEqual(
            TileGridMetrics.columns(width: 0, minTileWidth: 220, spacing: 12, count: 4), 1)
        XCTAssertEqual(
            TileGridMetrics.columns(width: .infinity, minTileWidth: 220, spacing: 12, count: 4), 1)
        XCTAssertEqual(
            TileGridMetrics.columns(width: .nan, minTileWidth: 220, spacing: 12, count: 4), 1)
    }

    func testTileWidthSharesWhatIsLeftAfterTheGutters() {
        XCTAssertEqual(TileGridMetrics.tileWidth(width: 924, columns: 4, spacing: 12), 222)
        XCTAssertEqual(TileGridMetrics.tileWidth(width: 300, columns: 1, spacing: 12), 300)
    }

    func testIdealWidthCapsTheColumnCount() {
        XCTAssertEqual(
            TileGridMetrics.idealWidth(count: 8, minTileWidth: 200, spacing: 10, idealColumns: 4),
            830)
        XCTAssertEqual(
            TileGridMetrics.idealWidth(count: 2, minTileWidth: 200, spacing: 10, idealColumns: 4),
            410)
    }

    func testEachRowTakesItsTallestTile() {
        let heights: [CGFloat] = [100, 130, 90, 118, 80]
        XCTAssertEqual(TileGridMetrics.rowHeights(heights, columns: 3), [130, 118])
        XCTAssertEqual(TileGridMetrics.rowHeights([], columns: 3), [])
    }
}
