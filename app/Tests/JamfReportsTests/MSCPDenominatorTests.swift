import Foundation
import XCTest
@testable import JamfReports

/// Visual review 2026-10-04: the Compliance Posture subtitle counted the first baseline's
/// evaluated devices (632) while the cards beside it counted 606, and one card divided its
/// band shares by 664 and its compliance rate by 632 without saying so. Each baseline
/// evaluates only the devices that report its own column, so the three counts are different
/// numbers and the screen names each one.
///
/// Fixture, invented: six devices. "Count A" has a value for d1 to d4 (0, 0, 5, 40), a
/// sentinel -1 for d5 and no row for d6, so 4 are evaluated and 2 pass. "Count B" has a value
/// for all six.
final class MSCPDenominatorTests: XCTestCase {

    private func row(_ device: String, _ column: String, _ value: Int) -> EAResultRow {
        EAResultRow(
            computerId: nil, computerName: nil, serial: nil, eaId: nil, eaName: column,
            device: device, value: AnyCodable(value))
    }

    private func results(columns: [String] = ["Count A", "Count B"]) -> [
        MSCPComplianceService.BaselineResult
    ] {
        var rows: [EAResultRow] = []
        for (device, value) in [("d1", 0), ("d2", 0), ("d3", 5), ("d4", 40), ("d5", -1)] {
            rows.append(row(device, "Count A", value))
        }
        for (device, value) in [("d1", 0), ("d2", 1), ("d3", 2), ("d4", 60), ("d5", 0), ("d6", 0)] {
            rows.append(row(device, "Count B", value))
        }
        let baselines = columns.map {
            ComplianceBaselineConfig(
                name: "Baseline \($0)", failuresCountColumn: $0,
                failuresListColumn: nil, ruleCount: nil)
        }
        return MSCPComplianceService.evaluate(rows: rows, baselines: baselines)
    }

    func testEveryBaselineSeesTheSameDevicesButEvaluatesItsOwn() throws {
        let both = results()
        XCTAssertEqual(both.map(\.totalDevices), [6, 6])
        XCTAssertEqual(both.map(\.devicesWithData), [4, 6])
    }

    func testComplianceRateNamesItsDenominatorApartFromTheShares() throws {
        let a = try XCTUnwrap(results().first)
        XCTAssertEqual(a.passCount, 2)
        XCTAssertEqual(try XCTUnwrap(a.compliancePct), 50.0, accuracy: 0.0001)
        XCTAssertEqual(a.complianceRateBasisText, "2 of 4 evaluated")
        XCTAssertEqual(a.evaluatedBasisText, "of 6 devices, 2 No Data")
        XCTAssertEqual(a.shareBasisText, "Share of all 6 devices, No Data included")
        // The donut divides by all six: the Pass slice reads 2 of 6, not 2 of 4.
        let pass = try XCTUnwrap(
            MSCPChartDataBuilder.toDonutSlices(result: a).first { $0.label.hasPrefix("Pass") })
        XCTAssertEqual(pass.pct, 100.0 * 2 / 6, accuracy: 0.0001)
    }

    func testSubtitleGivesTheRangeWhenBaselinesEvaluateDifferentCounts() {
        XCTAssertEqual(
            MSCPComplianceService.evaluatedSummary(results()),
            "6 devices across 2 mSCP baselines; each evaluates the devices that report its "
                + "column (4 to 6).")
    }

    func testSubtitleStatesOneCountWhenTheBaselinesAgree() {
        let b = results(columns: ["Count B"])
        XCTAssertEqual(
            MSCPComplianceService.evaluatedSummary(b),
            "6 of 6 devices evaluated across 1 mSCP baseline.")
        XCTAssertEqual(
            MSCPComplianceService.evaluatedSummary(b + b),
            "6 of 6 devices evaluated across 2 mSCP baselines.")
    }

    func testSubtitleDoesNotBorrowTheFirstBaselinesCount() {
        // The first baseline evaluates 4, the second 6: neither alone describes the screen.
        let subtitle = MSCPComplianceService.evaluatedSummary(results())
        XCTAssertFalse(subtitle.hasPrefix("4"))
        XCTAssertTrue(subtitle.contains("4 to 6"))
    }

    func testSubtitleWhenNoDeviceMatchesAnyColumn() {
        XCTAssertEqual(
            MSCPComplianceService.evaluatedSummary(results(columns: ["Count Z"])),
            "No device data matched the configured baseline EA column.")
        XCTAssertEqual(
            MSCPComplianceService.evaluatedSummary([]),
            "No device data matched the configured baseline EA column.")
    }
}
