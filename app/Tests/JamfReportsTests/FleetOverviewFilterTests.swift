import XCTest
@testable import JamfReports

final class FleetOverviewFilterTests: XCTestCase {

    // MARK: - hasIssue via fleetProfileHasIssue

    func testCleanSummaryHasNoIssue() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 98,
            compliancePct: 88,
            staleCount: 0,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 85
        )
        XCTAssertFalse(fleetProfileHasIssue(summary))
    }

    func testStaleSummaryHasIssue() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 98,
            compliancePct: 88,
            staleCount: 5,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 85
        )
        XCTAssertTrue(fleetProfileHasIssue(summary))
    }

    func testLowFileVaultHasIssue() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 82,
            compliancePct: 90,
            staleCount: 0,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 85
        )
        XCTAssertTrue(fleetProfileHasIssue(summary))
    }

    func testLowPatchComplianceHasIssue() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 98,
            compliancePct: 90,
            staleCount: 0,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 72
        )
        XCTAssertTrue(fleetProfileHasIssue(summary))
    }

    func testLowStabilityIndexHasIssue() {
        // stability = 0.4*50 + 0.4*75 + 0.2*(100-0) = 20+30+20 = 70 — at threshold,
        // use compliancePct that pulls it below 70
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 98,
            compliancePct: 40,     // drives stability below 70
            staleCount: 0,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 85
        )
        // stability = 0.4*40 + 0.4*85 + 0.2*100 = 16+34+20 = 70 — exactly at boundary
        // Lower compliance to confirm < 70 triggers
        let summary2 = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 98,
            compliancePct: 30,
            staleCount: 0,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 85
        )
        XCTAssertTrue(fleetProfileHasIssue(summary2))
        _ = summary  // silence unused warning
    }

    func testMissingSummaryHasIssue() {
        XCTAssertTrue(fleetProfileHasIssue(nil))
    }

    // MARK: - Filter helper

    func testFilterProducesCorrectCount() {
        let summaries: [DailySummary?] = [
            // clean
            DailySummary(
                date: "2026-05-01", totalDevices: 100, fileVaultPct: 98,
                compliancePct: 88, staleCount: 0, osCurrentPct: 75,
                crowdstrikePct: 95, patchPct: 85
            ),
            // issue: stale
            DailySummary(
                date: "2026-05-01", totalDevices: 100, fileVaultPct: 98,
                compliancePct: 88, staleCount: 3, osCurrentPct: 75,
                crowdstrikePct: 95, patchPct: 85
            ),
            // issue: no summary
            nil,
            // clean
            DailySummary(
                date: "2026-05-01", totalDevices: 50, fileVaultPct: 99,
                compliancePct: 92, staleCount: 0, osCurrentPct: 80,
                crowdstrikePct: 97, patchPct: 90
            ),
            // issue: low patch
            DailySummary(
                date: "2026-05-01", totalDevices: 80, fileVaultPct: 96,
                compliancePct: 85, staleCount: 0, osCurrentPct: 70,
                crowdstrikePct: 93, patchPct: 60
            ),
        ]

        let issueCount = summaries.filter { fleetProfileHasIssue($0) }.count
        let cleanCount = summaries.filter { !fleetProfileHasIssue($0) }.count

        XCTAssertEqual(issueCount, 3)
        XCTAssertEqual(cleanCount, 2)
    }

    // MARK: - Issue reasons (#184)

    func testIssueReasonsNameEveryTrippedCondition() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 82,
            compliancePct: 88,
            staleCount: 5,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 60
        )
        let reasons = fleetProfileIssueReasons(summary)
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.contains { $0.contains("5 stale devices") })
        XCTAssertTrue(reasons.contains { $0.contains("FileVault 82.0%") })
        XCTAssertTrue(reasons.contains { $0.contains("Patch 60.0%") })
    }

    func testIssueReasonsEmptyForCleanSummary() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 98,
            compliancePct: 88,
            staleCount: 0,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 85
        )
        XCTAssertTrue(fleetProfileIssueReasons(summary).isEmpty)
    }

    func testIssueReasonsForMissingSummary() {
        XCTAssertEqual(fleetProfileIssueReasons(nil), ["No summary collected yet"])
    }

    func testIssueDestinationsRouteToActionableTabs() {
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 82,
            compliancePct: 88,
            staleCount: 5,
            osCurrentPct: 75,
            crowdstrikePct: 95,
            patchPct: 60
        )
        XCTAssertEqual(fleetProfileIssues(summary).map(\.tab),
                       [.outreach, .securityPosture, .patch])
        XCTAssertEqual(fleetProfileIssues(nil).first?.tab, .overview)
    }

    // MARK: - Nil staleCount under-flag rule

    /// Unknown stale (nil) with otherwise-healthy metrics must not produce any issues.
    /// Under-flag rule: absent data is not a flag.
    func testNilStaleCountHealthyMetricsProducesNoIssues() {
        // stability = (88*0.4 + 85*0.4) / 0.8 = 86.5 — well above threshold
        let summary = DailySummary(
            date: "2026-06-01",
            totalDevices: 200,
            fileVaultPct: 95,
            compliancePct: 88,
            staleCount: nil,
            osCurrentPct: 80,
            crowdstrikePct: 97,
            patchPct: 85
        )
        XCTAssertTrue(fleetProfileIssues(summary).isEmpty,
                      "nil staleCount with healthy metrics must not trigger any issue")
    }

    /// nil stabilityIndex (both compliance and patch absent) must not flag a stability issue.
    func testNilStabilityIndexNotFlagged() {
        // No compliancePct, no patchPct → stabilityIndex == nil → no stability issue
        let summary = DailySummary(
            date: "2026-06-01",
            totalDevices: 100,
            fileVaultPct: 95,
            compliancePct: nil,
            staleCount: nil,
            osCurrentPct: 80,
            crowdstrikePct: 97,
            patchPct: nil
        )
        let issues = fleetProfileIssues(summary)
        XCTAssertFalse(issues.contains { $0.tab == .trends },
                       "nil stabilityIndex must not produce a Trends issue")
    }

    // MARK: - Stability below 70 routes to Trends

    /// Stability below 70 with no other conditions tripped must produce exactly one issue
    /// whose reason contains "Stability" and whose tab is .trends.
    func testLowStabilityAloneRoutesToTrends() throws {
        // stability = (30*0.4 + 85*0.4) / 0.8 = 57.5 < 70
        // staleCount=nil, fileVaultPct=95 (≥90), patchPct=85 (≥80) → only stability fires
        let summary = DailySummary(
            date: "2026-06-01",
            totalDevices: 100,
            fileVaultPct: 95,
            compliancePct: 30,
            staleCount: nil,
            osCurrentPct: 75,
            crowdstrikePct: 90,
            patchPct: 85
        )
        let issues = fleetProfileIssues(summary)
        XCTAssertEqual(issues.count, 1, "Only the stability issue should fire")
        let issue = try XCTUnwrap(issues.first)
        XCTAssertTrue(issue.reason.contains("Stability"),
                      "Reason must contain 'Stability', got: \(issue.reason)")
        XCTAssertEqual(issue.tab, .trends)
    }
}
