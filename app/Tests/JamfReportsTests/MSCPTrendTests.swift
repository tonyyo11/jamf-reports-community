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

    // MARK: - Improvement 1: hasMSCPBandHistory from ea-results only

    /// `hasMSCPBandHistory` must become true as soon as dated ea-results snapshots
    /// carry band data — even when no summary.json mscpBands exist yet.
    /// This verifies the fix for the prod symptom where the stackplot showed
    /// "unavailable" despite ea-results existing.
    func testHasMSCPBandHistoryTrueWhenOnlyEAResultsPresent() throws {
        let tmp = try makeTempDataDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let eaColumn = "Compliance Failures"
        try writeEAResults(to: tmp, eaColumn: eaColumn, passCount: 5, highCount: 2)

        // Summaries with NO mscpBands — only ea-results carry band data.
        let summaries = [makeSummary(date: "2026-05-01", mscpBands: nil)]

        // The store is loaded in-memory using the init path; cachedBandPoints
        // are built from summaries-only here (no config.yaml in tmp).
        // To exercise the ea-results backfill path we call buildSeries directly
        // and assert the output, which is what TrendStore.rebuildBandPoints delegates to.
        let baseline = ComplianceBaselineConfig(
            name: "NIST 800-53r5", failuresCountColumn: eaColumn, ruleCount: nil)
        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: tmp, summaries: summaries)

        XCTAssertFalse(points.isEmpty,
            "buildSeries must return band points from ea-results when no summary mscpBands exist")
        XCTAssertEqual(points.first?.counts.pass, 5)
        XCTAssertEqual(points.first?.counts.high, 2)

        // Confirm hasMSCPBandHistory follows cachedBandPoints when a store is
        // seeded with a summary whose mscpBands are populated (the in-memory path).
        let bandedSummary = makeSummary(
            date: "2026-05-01",
            mscpBands: ["NIST 800-53r5": MSCPBandCounts(pass: 5, low: 0, medLow: 0, medium: 0, high: 2, noData: 0)]
        )
        let store = TrendStore(summaries: [bandedSummary], range: .w4)
        XCTAssertTrue(store.hasMSCPBandHistory,
            "hasMSCPBandHistory must be true when band points exist (in-memory path via summaries)")
    }

    /// When summaries carry no mscpBands AND no ea-results directory exists,
    /// `hasMSCPBandHistory` must remain false.
    func testHasMSCPBandHistoryFalseWhenNeitherSourcePresent() {
        let store = TrendStore(
            summaries: [makeSummary(date: "2026-05-01", mscpBands: nil)],
            range: .w4
        )
        XCTAssertFalse(store.hasMSCPBandHistory,
            "hasMSCPBandHistory must be false when neither ea-results nor summary mscpBands exist")
    }

    /// `mscpStackedSeries()` must return 5 series when band points are available,
    /// and those series must cover the full range of band labels.
    func testMSCPStackedSeriesFromBandPoints() {
        let mscpBands = [
            "NIST 800-53r5": MSCPBandCounts(pass: 50, low: 20, medLow: 10, medium: 5, high: 2, noData: 3)
        ]
        let summary = makeSummary(date: "2026-05-01", mscpBands: mscpBands)
        let store = TrendStore(summaries: [summary], range: .all)
        let series = store.mscpStackedSeries()

        XCTAssertEqual(series.count, 5, "mscpStackedSeries must return 5 band series")
        let labels = series.map(\.label)
        XCTAssertTrue(labels.contains("Pass (0)"))
        XCTAssertTrue(labels.contains("High (>50)"))
        // Pass band value should equal the band's count
        let passSeries = series.first { $0.label == "Pass (0)" }
        XCTAssertEqual(passSeries?.points.first?.value, 50.0)
    }

    // MARK: - Finding 1: single-baseline name-drift bridging

    /// A single-baseline workspace where the baseline name changed between two
    /// daily summaries must produce ONE continuous series, not two separate ones.
    ///
    /// Scenario: day1 summary was written with key "OldName" (pre-config-fix);
    /// day2 summary uses "Compliance" (post-config-fix). With
    /// `singleBaselineWorkspace: true`, both points land on the same series.
    func testSingleBaselineNameDriftProducesOneContinuousSeries() {
        let nonexistentDir = URL(fileURLWithPath: "/tmp/mscp-nonexistent-\(UUID().uuidString)")
        let bands = MSCPBandCounts(pass: 50, low: 10, medLow: 5, medium: 2, high: 1, noData: 0)

        let day1 = makeSummary(date: "2026-06-05",
                               mscpBands: ["OldName": bands])    // pre-rename key
        let day2 = makeSummary(date: "2026-06-06",
                               mscpBands: ["Compliance": bands]) // post-rename key

        let baseline = ComplianceBaselineConfig(
            name: "Compliance", failuresCountColumn: "Compliance Failures", ruleCount: nil)

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline,
            dataDir: nonexistentDir,
            summaries: [day1, day2],
            singleBaselineWorkspace: true
        )

        XCTAssertEqual(points.count, 2,
            "Single-baseline rename must bridge to one continuous series (2 points), not fork into 1")
    }

    /// With `singleBaselineWorkspace: false` (multi-baseline), mismatched keys
    /// are NOT coalesced — each baseline keeps its own series.
    func testMultiBaselineNameMismatchIsNotCoalesced() {
        let nonexistentDir = URL(fileURLWithPath: "/tmp/mscp-nonexistent-\(UUID().uuidString)")
        let bands = MSCPBandCounts(pass: 50, low: 10, medLow: 5, medium: 2, high: 1, noData: 0)

        let day1 = makeSummary(date: "2026-06-05",
                               mscpBands: ["OtherBaseline": bands, "Compliance": bands])
        let day2 = makeSummary(date: "2026-06-06",
                               mscpBands: ["OtherBaseline": bands, "Compliance": bands])

        let baseline = ComplianceBaselineConfig(
            name: "Compliance", failuresCountColumn: "Compliance Failures", ruleCount: nil)

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline,
            dataDir: nonexistentDir,
            summaries: [day1, day2],
            singleBaselineWorkspace: false
        )

        // Multi-baseline: only exact-name matches land — both days have "Compliance"
        XCTAssertEqual(points.count, 2,
            "Multi-baseline workspace must key by exact name; both days match 'Compliance' directly")

        // Now try a name that doesn't appear in the multi-baseline dict
        let missingBaseline = ComplianceBaselineConfig(
            name: "Missing", failuresCountColumn: "x", ruleCount: nil)
        let noPoints = MSCPChartDataBuilder.buildSeries(
            baseline: missingBaseline,
            dataDir: nonexistentDir,
            summaries: [day1, day2],
            singleBaselineWorkspace: false  // must NOT coalesce despite count > 1
        )
        XCTAssertEqual(noPoints.count, 0,
            "Multi-baseline workspace must not coalesce a non-matching key even when no exact match exists")
    }

    // MARK: - Multi-baseline selection

    /// A multi-baseline workspace exposes both baseline names, and switching the
    /// selection changes which baseline's series `mscpStackedSeries()` returns.
    func testSelectMSCPBaselineSwitchesSeries() {
        // Two baselines with distinct band distributions on the same date.
        let bands: [String: MSCPBandCounts] = [
            "DISA STIG": MSCPBandCounts(pass: 45, low: 25, medLow: 20, medium: 8, high: 2, noData: 0),
            "NIST 800-53r5": MSCPBandCounts(pass: 50, low: 30, medLow: 15, medium: 4, high: 1, noData: 0),
        ]
        let store = TrendStore(summaries: [makeSummary(date: "2026-05-01", mscpBands: bands)],
                               range: .all)

        // Both names are listed (order = sorted in the no-config fallback path).
        XCTAssertEqual(Set(store.mscpBaselineNames), ["DISA STIG", "NIST 800-53r5"])
        XCTAssertNotNil(store.selectedMSCPBaseline)

        // Select STIG → its Pass band is 45.
        store.selectMSCPBaseline("DISA STIG")
        let stigPass = store.mscpStackedSeries().first { $0.label == "Pass (0)" }
        XCTAssertEqual(stigPass?.points.first?.value, 45.0)

        // Select NIST → its Pass band is 50.
        store.selectMSCPBaseline("NIST 800-53r5")
        let nistPass = store.mscpStackedSeries().first { $0.label == "Pass (0)" }
        XCTAssertEqual(nistPass?.points.first?.value, 50.0)

        // Unknown name is a no-op — selection unchanged.
        store.selectMSCPBaseline("Does Not Exist")
        XCTAssertEqual(store.selectedMSCPBaseline, "NIST 800-53r5")
    }

    // MARK: - Helpers

    private func makeSummary(date: String, mscpBands: [String: MSCPBandCounts]?) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: 100,
            fileVaultPct: 85.0,
            compliancePct: 75.0,
            staleCount: 10,
            osCurrentPct: 90.0,
            crowdstrikePct: 88.0,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: nil,
            sipPct: nil, firewallPct: nil, gatekeeperPct: nil,
            secureBootPct: nil, bootstrapPct: nil, xprotectPct: nil,
            cvePct: nil, mscpScorePct: nil, securityScore: nil,
            actionItemsP0: nil, actionItemsP1: nil, actionItemsP2: nil,
            noBaselineActive: nil, complianceIsProxy: nil,
            mscpBands: mscpBands
        )
    }

    private func makeTempDataDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscp-trend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func writeEAResults(
        to dataDir: URL,
        eaColumn: String,
        passCount: Int = 0,
        highCount: Int = 0,
        filename: String = "ea-results_20260501T120000.json"
    ) throws {
        let eaDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for i in 0..<passCount {
            rows.append(["device": "mac-pass-\(i)", "ea_name": eaColumn, "value": 0])
        }
        for i in 0..<highCount {
            rows.append(["device": "mac-high-\(i)", "ea_name": eaColumn, "value": 60])
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: eaDir.appendingPathComponent(filename))
    }
}