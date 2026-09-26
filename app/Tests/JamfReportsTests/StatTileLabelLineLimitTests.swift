import AppKit
import SwiftUI
import XCTest
@testable import JamfReports

/// The Overview holds its score cards to one line with `.lineLimit(1)` and lets
/// only the title wrap through `labelLineLimit`, so a long title shows in full.
@MainActor
final class StatTileLabelLineLimitTests: XCTestCase {

    private func height(label: String, labelLineLimit: Int?) -> CGFloat {
        let tile = StatTile(label: label, value: "96.6%", sub: "Avg per title",
                            labelLineLimit: labelLineLimit)
            .lineLimit(1)
            .frame(width: 220)
        return NSHostingView(rootView: tile).fittingSize.height
    }

    func testLongLabelWrapsPastTheSurroundingLineLimit() {
        let label = "Security Score (Weighted)"
        XCTAssertGreaterThan(height(label: label, labelLineLimit: 2),
                             height(label: label, labelLineLimit: nil))
    }

    func testShortLabelKeepsItsHeight() {
        let label = "Patch Compliance"
        XCTAssertEqual(height(label: label, labelLineLimit: 2),
                       height(label: label, labelLineLimit: nil))
    }
}
