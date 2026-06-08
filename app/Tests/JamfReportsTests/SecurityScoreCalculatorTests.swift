import Foundation
import XCTest
@testable import JamfReports

final class SecurityScoreCalculatorTests: XCTestCase {

    // Spot-check anchored to the latest entry of the real legacy
    // fleet_health_metrics_history.json (2026-05-11). v3.5 reported 97.2 for
    // this snapshot; our Swift port should agree within ±0.5 points.
    func testWeightedScoreMatchesLegacyAnchor() {
        let input = SecurityScoreCalculator.Input(
            totalDevices: 655,
            compliantCounts: [
                .fileVault: 647,
                .sip: 655,
                .firewall: 655,
                .edrAgent: 635,
                .mscp: 625,           // ≈ 95.4% mscp_score_pct × 655
                .xprotect: 566,
                .cve: 636,
                .secureBoot: 608
            ]
        )

        let score = SecurityScoreCalculator.score(input: input, weights: .defaultWeights)

        XCTAssertEqual(score.value, 97.2, accuracy: 0.5,
                       "Swift score should match v3.5 anchor (±0.5)")
        XCTAssertEqual(score.grade, .aPlus)
        XCTAssertEqual(score.available.count, 8)
        XCTAssertTrue(score.missing.isEmpty)
    }

    func testMissingMetricsRenormalizeWeights() {
        // Tenant without CrowdStrike or mSCP — drop those metrics entirely
        // and the score should still scale to 0–100 across the remaining
        // weights.
        let input = SecurityScoreCalculator.Input(
            totalDevices: 100,
            compliantCounts: [
                .fileVault: 100,
                .sip: 100,
                .firewall: 100,
                .xprotect: 100,
                .cve: 100,
                .secureBoot: 100
            ]
        )

        let score = SecurityScoreCalculator.score(input: input)

        XCTAssertEqual(score.value, 100.0, accuracy: 0.01)
        XCTAssertEqual(score.grade, .aPlus)
        XCTAssertEqual(Set(score.missing), Set([.edrAgent, .mscp]))
        XCTAssertNil(score.appliedWeights[.edrAgent])
        XCTAssertNil(score.appliedWeights[.mscp])
    }

    func testZeroTotalDevicesYieldsFGradeNotCrash() {
        let input = SecurityScoreCalculator.Input(
            totalDevices: 0,
            compliantCounts: [.fileVault: 0]
        )

        let score = SecurityScoreCalculator.score(input: input)

        XCTAssertEqual(score.value, 0)
        XCTAssertEqual(score.grade, .f)
        XCTAssertTrue(score.available.isEmpty)
    }

    func testZeroWeightMetricIsExcludedFromScoreAndMissingList() {
        let weights = SecurityScoreWeights(
            fileVault: 15, sip: 15, firewall: 15,
            edrAgent: 0,                       // explicitly disabled
            mscp: 20, xprotect: 5, cve: 15, secureBoot: 5
        )
        let input = SecurityScoreCalculator.Input(
            totalDevices: 100,
            compliantCounts: [
                .fileVault: 100, .sip: 100, .firewall: 100,
                .edrAgent: 0,                  // operator disabled it
                .mscp: 100, .xprotect: 100, .cve: 100, .secureBoot: 100
            ]
        )

        let score = SecurityScoreCalculator.score(input: input, weights: weights)

        XCTAssertEqual(score.value, 100.0, accuracy: 0.01)
        XCTAssertFalse(score.available.contains(.edrAgent))
        XCTAssertFalse(score.missing.contains(.edrAgent))
    }

    func testInputFromSummaryReversesPercentagesIntoCounts() {
        let summary = DailySummary(
            date: "2026-05-11",
            totalDevices: 655,
            fileVaultPct: 98.78,
            compliancePct: nil,
            staleCount: 8,
            osCurrentPct: 91.0,
            crowdstrikePct: 96.95,
            patchPct: 88.0,
            source: "swift",
            sipPct: 100.0,
            firewallPct: 100.0,
            secureBootPct: 92.82,
            mscpScorePct: 95.40
        )

        let input = SecurityScoreCalculator.input(from: summary)

        XCTAssertEqual(input.totalDevices, 655)
        XCTAssertEqual(input.compliantCounts[.fileVault], 647)
        XCTAssertEqual(input.compliantCounts[.sip], 655)
        XCTAssertEqual(input.compliantCounts[.edrAgent], 635)
        XCTAssertNil(input.compliantCounts[.xprotect],
                     "Summary without xprotectPct should omit, not zero")
        XCTAssertNil(input.compliantCounts[.cve])
    }

    func testGradeBanding() {
        XCTAssertEqual(SecurityScore.Grade.from(value: 99), .aPlus)
        XCTAssertEqual(SecurityScore.Grade.from(value: 95), .aPlus)
        XCTAssertEqual(SecurityScore.Grade.from(value: 94.9), .a)
        XCTAssertEqual(SecurityScore.Grade.from(value: 89), .b)
        XCTAssertEqual(SecurityScore.Grade.from(value: 75), .c)
        XCTAssertEqual(SecurityScore.Grade.from(value: 65), .d)
        XCTAssertEqual(SecurityScore.Grade.from(value: 50), .f)
        XCTAssertEqual(SecurityScore.Grade.from(value: nil), .f)
        XCTAssertEqual(SecurityScore.Grade.from(value: .nan), .f)
    }
}
