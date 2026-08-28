import XCTest
@testable import JamfReports

final class PeriodReportModelTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func d(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = cal; f.timeZone = .current
        return f.date(from: s)!
    }
    private func summary(_ date: String, total: Int, fv: Double?) -> DailySummary {
        DailySummary(date: date, totalDevices: total, fileVaultPct: fv, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "test", provenance: nil, sipPct: nil, firewallPct: nil, gatekeeperPct: nil,
            secureBootPct: nil, bootstrapPct: nil, xprotectPct: nil, cvePct: nil,
            mscpScorePct: nil, securityScore: nil, noBaselineActive: nil, complianceIsProxy: nil)
    }
    private func model(_ s: [DailySummary]) -> PeriodReportModel {
        let period = ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: s.map { d($0.date) }, now: d("2026-07-15"), calendar: cal)!
        return PeriodReportModel.build(
            period: period,
            metrics: PeriodMetricCatalog.fleetMetrics(in: s),
            summaries: s, eaSnapshots: [], profile: "acme-prod",
            generatedAt: d("2026-07-15"))
    }

    func testStartAndEndComeFromTheBoundarySummaries() throws {
        let m = model([summary("2026-04-01", total: 600, fv: 90),
                       summary("2026-05-15", total: 630, fv: 95),
                       summary("2026-06-30", total: 662, fv: 98)])
        let row = try XCTUnwrap(m.rows.first { $0.metricID == "totalDevices" })
        XCTAssertEqual(row.startValue, 600)
        XCTAssertEqual(row.endValue, 662)
        XCTAssertEqual(row.change, 62)
    }

    /// Change on a percentage is percentage points, never a relative percentage.
    /// Both readings are arithmetically defensible and they differ, so a figure
    /// quoted into a management document must say which it is.
    func testPercentChangeIsInPercentagePoints() throws {
        let m = model([summary("2026-04-01", total: 600, fv: 96),
                       summary("2026-06-30", total: 600, fv: 98)])
        let row = try XCTUnwrap(m.rows.first { $0.metricID == "fileVaultPct" })
        XCTAssertEqual(try XCTUnwrap(row.change), 2.0, accuracy: 0.001)
        XCTAssertEqual(PeriodReportModel.formatChange(row.change, unit: .percent), "+2.0 pp")
    }

    func testCountChangeRendersAsSignedInteger() {
        XCTAssertEqual(PeriodReportModel.formatChange(62, unit: .count), "+62")
        XCTAssertEqual(PeriodReportModel.formatChange(-5, unit: .count), "-5")
    }

    func testPercentValueRendersWithOneDecimal() {
        XCTAssertEqual(PeriodReportModel.formatValue(98.0, unit: .percent), "98.0%")
        XCTAssertEqual(PeriodReportModel.formatValue(nil, unit: .percent), "—")
    }

    /// nil is not zero: a metric unmeasured at a boundary reports no value and
    /// no change, rather than implying it fell to zero.
    func testMissingBoundaryValueYieldsNoValueAndNoChange() throws {
        let m = model([summary("2026-04-01", total: 600, fv: nil),
                       summary("2026-06-30", total: 662, fv: 98)])
        let row = try XCTUnwrap(m.rows.first { $0.metricID == "fileVaultPct" })
        XCTAssertNil(row.startValue)
        XCTAssertNil(row.change, "no start value means no defensible change")
        XCTAssertEqual(row.endValue, 98)
    }

    func testRowCarriesTheResolvedBoundaryDates() throws {
        let m = model([summary("2026-04-19", total: 600, fv: 90),
                       summary("2026-06-30", total: 662, fv: 98)])
        let row = try XCTUnwrap(m.rows.first { $0.metricID == "totalDevices" })
        XCTAssertEqual(row.startDate, d("2026-04-19"))
        XCTAssertTrue(m.period.start.isAdrift)
    }

    func testDailySeriesCoversEverySummaryInThePeriod() {
        let m = model([summary("2026-04-01", total: 600, fv: 90),
                       summary("2026-05-15", total: 630, fv: 95),
                       summary("2026-06-30", total: 662, fv: 98)])
        XCTAssertEqual(m.days.count, 3)
        XCTAssertEqual(m.days.first?.values["totalDevices"], 600)
    }

    func testSummariesOutsideThePeriodAreExcluded() {
        let m = model([summary("2026-04-01", total: 600, fv: 90),
                       summary("2026-06-30", total: 662, fv: 98)])
        XCTAssertFalse(m.days.contains { $0.date < d("2026-04-01") })
    }
}
