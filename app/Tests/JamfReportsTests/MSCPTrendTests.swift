import Foundation
import XCTest
@testable import JamfReports

@MainActor
final class MSCPTrendTests: XCTestCase {

    func testMSCPBandHistoryDetection() {
        // TrendStore with no mSCP bands history
        let emptyStore = TrendStore(summaries: [], range: .w4)
        XCTAssertFalse(emptyStore.hasMSCPBandHistory, "Empty store should not have mSCP band history")

        // TrendStore with summaries but no mSCP bands
        let summaryWithoutBands = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 85.0,
            compliancePct: 75.0,
            staleCount: 10,
            osCurrentPct: 90.0,
            crowdstrikePct: 88.0,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: nil,
            sipPct: nil,
            firewallPct: nil,
            gatekeeperPct: nil,
            secureBootPct: nil,
            bootstrapPct: nil,
            xprotectPct: nil,
            cvePct: nil,
            mscpScorePct: nil,
            securityScore: nil,
            actionItemsP0: nil,
            actionItemsP1: nil,
            actionItemsP2: nil,
            noBaselineActive: nil,
            complianceIsProxy: nil,
            mscpBands: nil
        )
        let storeWithoutBands = TrendStore(summaries: [summaryWithoutBands], range: .w4)
        XCTAssertFalse(storeWithoutBands.hasMSCPBandHistory, "Store without mSCP bands should not have band history")

        // TrendStore with mSCP bands
        let mscpBands = [
            "NIST 800-53r5": MSCPBandCounts(pass: 50, low: 30, medLow: 15, medium: 4, high: 1, noData: 0)
        ]
        let summaryWithBands = DailySummary(
            date: "2026-05-02",
            totalDevices: 100,
            fileVaultPct: 85.0,
            compliancePct: 75.0,
            staleCount: 10,
            osCurrentPct: 90.0,
            crowdstrikePct: 88.0,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: nil,
            sipPct: nil,
            firewallPct: nil,
            gatekeeperPct: nil,
            secureBootPct: nil,
            bootstrapPct: nil,
            xprotectPct: nil,
            cvePct: nil,
            mscpScorePct: nil,
            securityScore: nil,
            actionItemsP0: nil,
            actionItemsP1: nil,
            actionItemsP2: nil,
            noBaselineActive: nil,
            complianceIsProxy: nil,
            mscpBands: mscpBands
        )
        let storeWithBands = TrendStore(summaries: [summaryWithBands], range: .w4)
        XCTAssertTrue(storeWithBands.hasMSCPBandHistory, "Store with mSCP bands should have band history")
    }

    func testPrimaryMSCPBaselineDetection() {
        let mscpBands1 = [
            "NIST 800-53r5": MSCPBandCounts(pass: 50, low: 30, medLow: 15, medium: 4, high: 1, noData: 0),
            "DISA STIG": MSCPBandCounts(pass: 45, low: 25, medLow: 20, medium: 8, high: 2, noData: 0)
        ]
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 85.0,
            compliancePct: 75.0,
            staleCount: 10,
            osCurrentPct: 90.0,
            crowdstrikePct: 88.0,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: nil,
            sipPct: nil,
            firewallPct: nil,
            gatekeeperPct: nil,
            secureBootPct: nil,
            bootstrapPct: nil,
            xprotectPct: nil,
            cvePct: nil,
            mscpScorePct: nil,
            securityScore: nil,
            actionItemsP0: nil,
            actionItemsP1: nil,
            actionItemsP2: nil,
            noBaselineActive: nil,
            complianceIsProxy: nil,
            mscpBands: mscpBands1
        )

        let store = TrendStore(summaries: [summary], range: .w4)
        let primaryBaseline = store.primaryMSCPBaseline
        XCTAssertNotNil(primaryBaseline, "Should detect a primary baseline")
        XCTAssertTrue(mscpBands1.keys.contains(primaryBaseline!), "Primary baseline should be one of the configured baselines")
    }

    func testMSCPStackedSeriesGeneration() {
        let mscpBands = [
            "NIST 800-53r5": MSCPBandCounts(pass: 50, low: 30, medLow: 15, medium: 4, high: 1, noData: 0)
        ]
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 100,
            fileVaultPct: 85.0,
            compliancePct: 75.0,
            staleCount: 10,
            osCurrentPct: 90.0,
            crowdstrikePct: 88.0,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: nil,
            sipPct: nil,
            firewallPct: nil,
            gatekeeperPct: nil,
            secureBootPct: nil,
            bootstrapPct: nil,
            xprotectPct: nil,
            cvePct: nil,
            mscpScorePct: nil,
            securityScore: nil,
            actionItemsP0: nil,
            actionItemsP1: nil,
            actionItemsP2: nil,
            noBaselineActive: nil,
            complianceIsProxy: nil,
            mscpBands: mscpBands
        )

        let store = TrendStore(summaries: [summary], range: .w4)
        let series = store.mscpStackedSeries()

        XCTAssertEqual(series.count, 5, "Should generate 5 series for Pass, Low, Med-Low, Medium, High")
        XCTAssertTrue(series.allSatisfy { $0.points.count == 1 }, "Each series should have 1 point for the single summary")

        // Verify series labels match expected compliance bands
        let labels = series.map(\.label)
        XCTAssertTrue(labels.contains("Pass (0)"), "Should include Pass series")
        XCTAssertTrue(labels.contains("Low (1–10)"), "Should include Low series")
        XCTAssertTrue(labels.contains("Med-Low (11–30)"), "Should include Med-Low series")
        XCTAssertTrue(labels.contains("Medium (31–50)"), "Should include Medium series")
        XCTAssertTrue(labels.contains("High (>50)"), "Should include High series")
    }

    func testMSCPBandTrendValueExtraction() {
        let mscpBands = [
            "NIST 800-53r5": MSCPBandCounts(pass: 50, low: 30, medLow: 15, medium: 4, high: 1, noData: 5)
        ]
        let summary = DailySummary(
            date: "2026-05-01",
            totalDevices: 105,
            fileVaultPct: 85.0,
            compliancePct: 75.0,
            staleCount: 10,
            osCurrentPct: 90.0,
            crowdstrikePct: 88.0,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: nil,
            sipPct: nil,
            firewallPct: nil,
            gatekeeperPct: nil,
            secureBootPct: nil,
            bootstrapPct: nil,
            xprotectPct: nil,
            cvePct: nil,
            mscpScorePct: nil,
            securityScore: nil,
            actionItemsP0: nil,
            actionItemsP1: nil,
            actionItemsP2: nil,
            noBaselineActive: nil,
            complianceIsProxy: nil,
            mscpBands: mscpBands
        )

        let store = TrendStore(summaries: [summary], range: .w4)
        let points = store.points(metric: .mscpBandTrend)

        XCTAssertEqual(points.count, 1, "Should have one data point")
        if let point = points.first {
            // Total devices with data = total - noData = 105 - 5 = 100
            XCTAssertEqual(point.value, 100.0, "Should return devices with data (total - noData)")
        }
    }
}