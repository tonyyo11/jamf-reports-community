import Foundation
import SwiftUI
import XCTest
@testable import JamfReports

final class WrappingRowMetricsTests: XCTestCase {

    func testItemsStayOnOneLineWhileTheyFit() {
        // 100 + 8 + 100 + 8 + 100 = 316
        XCTAssertEqual(
            WrappingRowMetrics.lines(widths: [100, 100, 100], spacing: 8, maxWidth: 316), [0..<3])
        XCTAssertEqual(
            WrappingRowMetrics.lines(widths: [100, 100, 100], spacing: 8, maxWidth: 315),
            [0..<2, 2..<3])
    }

    func testAnUnproposedWidthIsOneLine() {
        XCTAssertEqual(
            WrappingRowMetrics.lines(widths: [400, 400, 400], spacing: 8, maxWidth: .infinity),
            [0..<3])
    }

    func testAnItemWiderThanTheLineGetsALineToItself() {
        XCTAssertEqual(
            WrappingRowMetrics.lines(widths: [50, 500, 50], spacing: 8, maxWidth: 200),
            [0..<1, 1..<2, 2..<3])
    }

    func testNoItemsMakeNoLines() {
        XCTAssertEqual(WrappingRowMetrics.lines(widths: [], spacing: 8, maxWidth: 200), [])
    }

    /// The Reports header's five buttons (about 730 pt) at the narrowest content width the
    /// app opens at (812) share one line; at PageScaffold.minSupportedWidth less its padding
    /// (584) they take two.
    func testTheReportsHeaderButtonsWrapAtTheMinimumSupportedWidth() {
        let buttons: [CGFloat] = [140, 130, 120, 120, 190]
        func lineCount(_ width: CGFloat) -> Int {
            WrappingRowMetrics.lines(widths: buttons, spacing: 8, maxWidth: width).count
        }
        XCTAssertEqual(lineCount(812), 1)
        XCTAssertEqual(
            lineCount(PageScaffold<EmptyView>.minSupportedWidth - 2 * Theme.Metrics.pagePadH), 2)
    }
}
