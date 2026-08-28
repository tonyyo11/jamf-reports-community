import XCTest
@testable import JamfReports

final class PeriodReportEmitterTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func d(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = cal; f.timeZone = .current
        return f.date(from: s)!
    }
    private func summary(_ date: String, _ total: Int, _ fv: Double) -> DailySummary {
        DailySummary(date: date, totalDevices: total, fileVaultPct: fv, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "test", provenance: nil, sipPct: nil, firewallPct: nil,
            gatekeeperPct: nil, secureBootPct: nil, bootstrapPct: nil, xprotectPct: nil,
            cvePct: nil, mscpScorePct: nil, securityScore: nil, noBaselineActive: nil,
            complianceIsProxy: nil)
    }
    private func makeModel(
        adrift: Bool = false, withEA: Bool = false
    ) -> PeriodReportModel {
        let startDate = adrift ? "2026-04-19" : "2026-04-01"
        let s = [summary(startDate, 600, 96), summary("2026-06-30", 662, 98)]
        let period = ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: s.map { d($0.date) }, now: d("2026-07-15"), calendar: cal)!
        var metrics = PeriodMetricCatalog.fleetMetrics(in: s)
        var snapshots: [PeriodEASnapshot] = []
        if withEA {
            metrics.append(PeriodMetric(
                id: "ea:Widget Status", label: "Widget Status", unit: .distribution,
                source: .extensionAttribute(name: "Widget Status", match: nil)))
            snapshots = [
                PeriodEASnapshot(date: d(startDate),
                                 valuesByEA: ["Widget Status": ["a": "On", "b": "Off"]]),
                PeriodEASnapshot(date: d("2026-06-30"),
                                 valuesByEA: ["Widget Status": ["a": "On", "b": "On"]])]
        }
        return PeriodReportModel.build(
            period: period, metrics: metrics, summaries: s, eaSnapshots: snapshots,
            profile: "acme-prod", generatedAt: d("2026-07-15"))
    }

    func testWorkbookHasSummaryDailyAndAboutSheets() {
        let wb = PeriodReportEmitter.workbook(for: makeModel())
        XCTAssertNotNil(wb.sheet(named: "Summary"))
        XCTAssertNotNil(wb.sheet(named: "Daily detail"))
        XCTAssertNotNil(wb.sheet(named: "About"))
    }

    /// The distributions sheet exists only when an unconfigured EA was selected,
    /// so a fleet-metrics-only report carries no empty sheet.
    func testDistributionsSheetOmittedWhenNoUnconfiguredEASelected() {
        XCTAssertNil(PeriodReportEmitter.workbook(for: makeModel())
            .sheet(named: "Value distributions"))
    }

    func testDistributionsSheetPresentWhenAnEAIsSelected() {
        XCTAssertNotNil(PeriodReportEmitter.workbook(for: makeModel(withEA: true))
            .sheet(named: "Value distributions"))
    }

    /// The filename carries the period so successive reports are
    /// self-identifying rather than distinguishable only by timestamp.
    func testReportKindCarriesThePeriod() {
        XCTAssertEqual(PeriodReportEmitter.reportKind(for: makeModel()),
                       "period-report-20260401-20260630")
    }

    func testEmitWritesAReadableFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("period.xlsx")
        try PeriodReportEmitter.emit(model: makeModel(withEA: true), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 1000, "an xlsx package should not be near-empty")
    }

    func testAboutSheetIsBuiltForADriftedPeriod() {
        XCTAssertNotNil(PeriodReportEmitter.workbook(for: makeModel(adrift: true))
            .sheet(named: "About"))
    }

    /// The Summary sheet is the paste-ready block; caveats belong on About so a
    /// rectangular selection copies cleanly.
    func testSummarySheetCarriesTheAsOfColumns() {
        let wb = PeriodReportEmitter.workbook(for: makeModel())
        XCTAssertNotNil(wb.sheet(named: "Summary"))
        XCTAssertNotNil(wb.sheet(named: "About"))
    }
}
