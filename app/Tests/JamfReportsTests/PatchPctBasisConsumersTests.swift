import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 C1: a patch figure recorded before `patchPctBasis` is a per-title mean, one
/// recorded after it is device-weighted. A change across the two is not a change in the
/// fleet, so every consumer that compares two figures leaves the earlier one out, as
/// `MetricAlertEvaluator` does for a `drops_more_than` alert.
final class PatchPctBasisConsumersTests: XCTestCase {

    private let device = DailySummary.deviceWeightedPatchBasis

    private func summary(
        _ date: String, patch: Double?, basis: String?, devices: Int = 100
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: devices, fileVaultPct: 90, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: patch,
            patchPctBasis: basis)
    }

    private func patchMetric(_ rollup: FleetRollup) throws -> FleetRollup.Metric {
        try XCTUnwrap(rollup.metrics.first { $0.key == "patch" })
    }

    func testTheFleetRollupHasNoPatchPriorAcrossTheBasisChange() throws {
        let current = [summary("2026-09-02", patch: 80, basis: device)]
        let mixed = FleetRollup.compute(
            groupName: "g", current: current,
            previous: [summary("2026-09-01", patch: 70, basis: nil)])
        XCTAssertEqual(try patchMetric(mixed).value, 80)
        XCTAssertNil(try patchMetric(mixed).previous)
        XCTAssertEqual(mixed.metrics.first { $0.key == "fileVault" }?.previous, 90,
                       "other metrics keep their prior")

        let same = FleetRollup.compute(
            groupName: "g", current: current,
            previous: [summary("2026-09-01", patch: 70, basis: device)])
        XCTAssertEqual(try patchMetric(same).previous, 70)
    }

    /// Two profiles on one date, one upgraded: their figures are not on one scale.
    func testAFleetTrendDateMixingBasesHasNoPatchFigure() throws {
        let model = try XCTUnwrap(FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("a", [summary("2026-09-01", patch: 70, basis: nil),
                       summary("2026-09-02", patch: 80, basis: device)]),
                ("b", [summary("2026-09-02", patch: 60, basis: nil)]),
            ],
            lookbackDays: 1, timestamp: "t"))
        XCTAssertEqual(model.trend.map(\.date), ["2026-09-01", "2026-09-02"])
        XCTAssertEqual(model.trend.first?.patchPct, 70)
        XCTAssertNil(model.trend.last?.patchPct)
    }

    func testTheOverviewInsightHasNoPatchPriorAcrossTheBasisChange() throws {
        func patchFact(previousBasis: String?) throws -> FleetInsightInput.Fact {
            let input = FleetInsightInput.fleet(
                current: summary("2026-09-02", patch: 80, basis: device),
                previous: summary("2026-09-01", patch: 70, basis: previousBasis))
            return try XCTUnwrap(input.facts.first { $0.label == "Patch compliance" })
        }
        XCTAssertNil(try patchFact(previousBasis: nil).prior)
        XCTAssertEqual(try patchFact(previousBasis: device).prior, .percent(70))
    }
}
