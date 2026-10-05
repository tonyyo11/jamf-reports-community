import SwiftUI
import XCTest
@testable import JamfReports

/// The Overview's Top Failing Rules rows: a rule ID is one token with no break to wrap at.
@MainActor
final class FailingRuleLabelTests: XCTestCase {

    func testAnIDTakesOneLineAtOrdinarySizes() {
        let ordinary: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
        ]
        for size in ordinary {
            XCTAssertEqual(OverviewView.failingRuleLineLimit(for: size), 1, "\(size)")
        }
    }

    func testAnIDMayWrapAtAccessibilitySizes() {
        let accessibility: [DynamicTypeSize] = [
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ]
        for size in accessibility {
            XCTAssertEqual(OverviewView.failingRuleLineLimit(for: size), 2, "\(size)")
        }
    }
}
