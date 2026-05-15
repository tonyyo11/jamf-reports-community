import Foundation
import XCTest
@testable import JamfReports

// Tests for M-02 from review/REPORT.md: AgentCardView previously hardcoded
// a fleet size of 502 in six locations (lines 365, 716, 973, 983, 1025,
// 1028 of OverviewView.swift), producing wrong percentages on any fleet
// that is not ~500 devices. The fix threads a `fleetCount` value into the
// card so coverage math is computed against the actual snapshot total.
//
// These tests exercise the pure functions that AgentCardView and the
// "Top Failing Rules" subtitle now call to build their displayed strings.
// A future regression that hardcodes a denominator will fail these tests
// rather than silently shipping a wrong number to demo or live tenants.
final class OverviewViewFleetCountTests: XCTestCase {

    // MARK: - Inline installed-of-total label

    func testInstalledLabelUsesProvidedFleetCount() {
        let label = agentInstalledOverTotalLabel(installed: 47, fleetCount: 100)
        XCTAssertEqual(label, "47 / 100",
                       "Inline progress label must use the provided fleetCount, not a hardcoded value")
    }

    func testInstalledLabelHandlesDemoFleetSize() {
        // DemoData.totalDevicesTrend ends at 524; that is the canonical
        // demo fleet total. AgentCardView previously rendered "/ 502" for
        // every agent which is internally inconsistent with the rest of
        // demo mode (Recent Activity card line 478 shows "of 524").
        let label = agentInstalledOverTotalLabel(installed: 488, fleetCount: 524)
        XCTAssertEqual(label, "488 / 524")
        XCTAssertFalse(label.contains("502"),
                       "Demo-mode label must reflect the actual demo fleet total (524), not a stale 502")
    }

    func testInstalledLabelDoesNotContainHardcoded502() {
        // Regression guard: regardless of input, no internal hardcode of
        // 502 should leak through.
        for fleet in [10, 100, 250, 1000] {
            let label = agentInstalledOverTotalLabel(installed: 5, fleetCount: fleet)
            XCTAssertFalse(label.contains("502"),
                           "Label for fleetCount=\(fleet) must not contain a stale 502 literal: '\(label)'")
        }
    }

    // MARK: - Accessibility label

    func testAccessibilityLabelUsesProvidedFleetCount() {
        let agent = SecurityAgent(
            name: "Test Agent",
            installed: 47,
            pct: 47.0,
            column: "Test - Status",
            trend: .flat
        )
        let label = agentCardAccessibilityLabel(agent: agent, fleetCount: 100)
        XCTAssertTrue(label.contains("47 of 100 installed"),
                      "Accessibility label must announce coverage against the provided fleetCount: '\(label)'")
        XCTAssertFalse(label.contains("502"),
                       "Accessibility label must not contain a stale 502 literal: '\(label)'")
    }

    func testAccessibilityLabelGapUsesFleetCount() {
        // Gap = max(0, fleetCount - installed). For 47/100, gap=53.
        let agent = SecurityAgent(
            name: "Test Agent",
            installed: 47,
            pct: 47.0,
            column: "Test - Status",
            trend: .flat
        )
        let label = agentCardAccessibilityLabel(agent: agent, fleetCount: 100)
        XCTAssertTrue(label.contains("53 not installed"),
                      "Gap text must be (fleetCount - installed), not (502 - installed): '\(label)'")
    }

    func testAccessibilityLabelGapZeroWhenInstalledExceedsFleet() {
        // Edge case: if installed > fleetCount (shouldn't happen, but
        // protect against negative gap).
        let agent = SecurityAgent(
            name: "Test Agent",
            installed: 110,
            pct: 100.0,
            column: "Test - Status",
            trend: .flat
        )
        let label = agentCardAccessibilityLabel(agent: agent, fleetCount: 100)
        XCTAssertFalse(label.contains("not installed"),
                       "When installed >= fleetCount, gap clauses must be omitted: '\(label)'")
    }

    // MARK: - Failing-rules subtitle

    func testFailingRulesSubtitleUsesProvidedFleetCount() {
        let subtitle = failingRulesSubtitle(baseline: "NIST 800-53r5 Moderate", fleetCount: 100)
        XCTAssertEqual(subtitle, "NIST 800-53r5 Moderate · across 100 active devices")
        XCTAssertFalse(subtitle.contains("502"),
                       "Subtitle must reflect the live fleet count, not a stale 502")
    }
}
