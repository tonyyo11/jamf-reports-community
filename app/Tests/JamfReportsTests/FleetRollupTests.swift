import XCTest
@testable import JamfReports

/// v2.2.0 Phase 4: consolidated fleet rollup (device-weighted KPIs +
/// period-over-period deltas) and the CSV emitter.
final class FleetRollupTests: XCTestCase {

    private func summary(
        date: String, devices: Int, compliance: Double?, stale: Int = 0,
        security: Double? = nil
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: devices, fileVaultPct: nil,
            compliancePct: compliance, staleCount: stale, osCurrentPct: nil,
            crowdstrikePct: nil, patchPct: nil, securityScore: security
        )
    }

    private func metric(_ rollup: FleetRollup, _ key: String) -> FleetRollup.Metric? {
        rollup.metrics.first { $0.key == key }
    }

    // MARK: - Aggregation

    func testDevicesAndStaleAreSummed() {
        let rollup = FleetRollup.compute(
            groupName: "Fleet",
            current: [
                summary(date: "2026-06-06", devices: 100, compliance: 90, stale: 10),
                summary(date: "2026-06-06", devices: 50, compliance: 50, stale: 5),
            ],
            previous: []
        )
        XCTAssertEqual(rollup.totalDevices, 150)
        XCTAssertEqual(rollup.profileCount, 2)
        XCTAssertEqual(metric(rollup, "devices")?.value, 150)
        XCTAssertEqual(metric(rollup, "stale")?.value, 15)
    }

    func testComplianceIsDeviceWeightedNotSimpleMean() throws {
        // 1000@90% + 10@50% → weighted ≈ 89.6%, NOT the 70% simple mean.
        let rollup = FleetRollup.compute(
            groupName: "Fleet",
            current: [
                summary(date: "2026-06-06", devices: 1000, compliance: 90),
                summary(date: "2026-06-06", devices: 10, compliance: 50),
            ],
            previous: []
        )
        let compliance = try XCTUnwrap(metric(rollup, "compliance")?.value)
        // Precomputed as explicit Double — inline mixed-literal arithmetic in
        // XCTAssertEqual trips the Swift 6.1 type-checker (CI gate).
        let weightedSum = 90.0 * 1000.0 + 50.0 * 10.0
        let expected = weightedSum / 1010.0
        XCTAssertEqual(compliance, expected, accuracy: 0.01)
    }

    func testPercentMetricNilWhenNoProfileReportsIt() {
        let rollup = FleetRollup.compute(
            groupName: "Fleet",
            current: [summary(date: "2026-06-06", devices: 100, compliance: nil)],
            previous: []
        )
        XCTAssertNil(metric(rollup, "compliance")?.value)
    }

    // MARK: - Deltas

    func testDeltaIsCurrentMinusPrevious() {
        let rollup = FleetRollup.compute(
            groupName: "Fleet",
            current: [summary(date: "2026-06-06", devices: 100, compliance: 92, stale: 8)],
            previous: [summary(date: "2026-05-30", devices: 100, compliance: 88, stale: 12)]
        )
        let complianceDelta: Double = metric(rollup, "compliance")?.delta ?? 0
        XCTAssertEqual(complianceDelta, 4.0, accuracy: 0.01)
        XCTAssertEqual(metric(rollup, "stale")?.delta, -4)
    }

    func testDeltaNilWhenNoPrevious() {
        let rollup = FleetRollup.compute(
            groupName: "Fleet",
            current: [summary(date: "2026-06-06", devices: 100, compliance: 92)],
            previous: []
        )
        XCTAssertNil(metric(rollup, "compliance")?.delta)
    }

    // MARK: - Emitter: prior-period selection

    func testPriorSummaryPicksNewestBeyondLookback() {
        let summaries = [
            summary(date: "2026-05-20", devices: 100, compliance: 80),  // > 7d back
            summary(date: "2026-05-30", devices: 100, compliance: 85),  // ~7d back
            summary(date: "2026-06-06", devices: 100, compliance: 90),  // current
        ]
        let prior = FleetReportEmitter.priorSummary(summaries, lookbackDays: 7)
        XCTAssertEqual(prior?.date, "2026-05-30")
    }

    func testPriorSummaryFallsBackToImmediatelyPrior() {
        // Only two summaries one day apart; 7-day lookback finds none older →
        // fall back to the immediately-prior summary.
        let summaries = [
            summary(date: "2026-06-05", devices: 100, compliance: 85),
            summary(date: "2026-06-06", devices: 100, compliance: 90),
        ]
        XCTAssertEqual(FleetReportEmitter.priorSummary(summaries, lookbackDays: 7)?.date, "2026-06-05")
    }

    func testPriorSummaryNilForSingleSummary() {
        XCTAssertNil(
            FleetReportEmitter.priorSummary(
                [summary(date: "2026-06-06", devices: 100, compliance: 90)], lookbackDays: 7
            )
        )
    }

    // MARK: - Emitter: CSV + emit

    func testCSVHasHeaderAndFormattedDeltaColumns() {
        let rollup = FleetRollup.compute(
            groupName: "Fleet",
            current: [summary(date: "2026-06-06", devices: 100, compliance: 92, stale: 8)],
            previous: [summary(date: "2026-05-30", devices: 100, compliance: 88, stale: 12)]
        )
        let csv = FleetReportEmitter.csv(for: rollup)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "Metric,Current,Previous,Delta")
        let compliance = try? XCTUnwrap(lines.first { $0.hasPrefix("Compliance %,") })
        XCTAssertEqual(compliance, "Compliance %,92.0%,88.0%,+4.0pp")
        let stale = try? XCTUnwrap(lines.first { $0.hasPrefix("Stale Devices,") })
        XCTAssertEqual(stale, "Stale Devices,8,12,-4")
    }

    func testRollupNilWhenNoProfileHasSummaries() {
        let group = ReportGroup(name: "Empty", profiles: ["a", "b"])
        XCTAssertNil(
            FleetReportEmitter.rollup(for: group, summariesByProfile: [[], []], lookbackDays: 7)
        )
    }

    func testEmitWritesConsolidatedCSVToDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let group = ReportGroup(name: "Production Fleet", profiles: ["prod", "dev"])
        let byProfile: [String: [DailySummary]] = [
            "prod": [
                summary(date: "2026-05-30", devices: 100, compliance: 88),
                summary(date: "2026-06-06", devices: 100, compliance: 92),
            ],
            "dev": [summary(date: "2026-06-06", devices: 20, compliance: 70)],
        ]
        let url = try FleetReportEmitter.emit(
            group: group, lookbackDays: 7, timestamp: "2026-06-06_120000",
            outputDir: dir, summariesFor: { byProfile[$0] ?? [] }
        )
        let written = try XCTUnwrap(url)
        XCTAssertEqual(written.lastPathComponent, "fleet-Production-Fleet-2026-06-06_120000.csv")
        let text = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(text.contains("Metric,Current,Previous,Delta"))
        XCTAssertTrue(text.contains("Devices,120,"))
    }

    func testEmitReturnsNilWhenGroupHasNoData() throws {
        let group = ReportGroup(name: "Empty", profiles: ["x"])
        let url = try FleetReportEmitter.emit(
            group: group, lookbackDays: 7, timestamp: "2026-06-06_120000",
            outputDir: FileManager.default.temporaryDirectory, summariesFor: { _ in [] }
        )
        XCTAssertNil(url)
    }
}
