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
}
