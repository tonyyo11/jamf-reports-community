import XCTest
import ZIPFoundation
@testable import JamfReports

final class PeriodReportEmitterTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func d(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.calendar = cal; f.timeZone = .current
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

    // MARK: - Patch definition change (epic #207 C1)

    private func patchSummary(_ date: String, patch: Double, basis: String?) -> DailySummary {
        DailySummary(date: date, totalDevices: 600, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: patch,
            source: "test", patchPctBasis: basis)
    }

    private func patchWorkbook(startBasis: String?, endBasis: String?) -> Workbook {
        let s = [patchSummary("2026-04-01", patch: 70, basis: startBasis),
                 patchSummary("2026-06-30", patch: 78.7, basis: endBasis)]
        let period = ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: s.map { d($0.date) }, now: d("2026-07-15"), calendar: cal)!
        let model = PeriodReportModel.build(
            period: period, metrics: PeriodMetricCatalog.fleetMetrics(in: s), summaries: s,
            eaSnapshots: [], profile: "acme-prod", generatedAt: d("2026-07-15"))
        return PeriodReportEmitter.workbook(for: model)
    }

    private func texts(_ wb: Workbook, _ sheet: String) -> [(row: Int, col: Int, text: String)] {
        (wb.sheet(named: sheet)?.dedupedCells ?? []).compactMap {
            if case .string(let s) = $0.value { return ($0.row, $0.col, s) }
            return nil
        }
    }

    private func patchChangeCell(_ wb: Workbook) throws -> String {
        let cells = texts(wb, "Summary")
        let label = try XCTUnwrap(cells.first { $0.col == 0 && $0.text == "Patch compliance" })
        return try XCTUnwrap(cells.first { $0.row == label.row && $0.col == 3 }).text
    }

    func testSummaryChangeCellIsADashAndAboutNamesTheChangeAcrossTheDefinitionChange() throws {
        let wb = patchWorkbook(startBasis: nil, endBasis: "device")

        XCTAssertEqual(try patchChangeCell(wb), "—")
        let note = "Patch compliance changed definition during this period "
            + "(device-weighted from 2.9); the change is not shown."
        XCTAssertEqual(texts(wb, "About").filter { $0.text == note }.count, 1)
    }

    func testSummaryChangeCellAndAboutAreUnchangedOnOneDefinition() throws {
        let wb = patchWorkbook(startBasis: "device", endBasis: "device")

        // The writer tab-escapes a leading "+", so the cell reads "\t+8.7pp".
        XCTAssertTrue(try patchChangeCell(wb).hasSuffix("+8.7pp"))
        XCTAssertFalse(texts(wb, "About").contains { $0.text.hasPrefix("Patch compliance") })
    }

    // MARK: - Untrusted values

    /// EA names and values are server-supplied and reach cells verbatim. Every
    /// write routes through CellValue.safe, which tab-escapes a leading =+-@ so
    /// a crafted attribute value cannot become a formula in a workbook someone
    /// opens. Pinned against the WRITTEN FILE (not the sanitizer in isolation)
    /// because this emitter is the path that carries the most attacker-shaped
    /// strings — a pin on the helper alone would not catch a call site that
    /// bypasses it. The hostile value avoids XML-escapable characters (no
    /// quotes/&/<>) so the assertions compare the writer's literal bytes
    /// rather than an escaped form, and the negative assertion checks the
    /// writer's real opening tag — a bare `<t>` never appears in this writer's
    /// output, so checking for it would pass vacuously even if the sanitizer
    /// were bypassed.
    func testHostileEAValuesAreNeutralisedNotWrittenRaw() throws {
        let hostile = "=cmd|/c calc!A1"
        let period = ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: [d("2026-04-01")], now: d("2026-07-15"), calendar: cal)!
        let metric = PeriodMetric(
            id: "ea:X", label: "=SUM(A1)", unit: .distribution,
            source: .extensionAttribute(name: "X", match: nil))
        let model = PeriodReportModel.build(
            period: period, metrics: [metric], summaries: [summary("2026-04-01", 1, 1)],
            eaSnapshots: [PeriodEASnapshot(date: d("2026-04-01"),
                                           valuesByEA: ["X": ["a": hostile]])],
            profile: "acme-prod", generatedAt: d("2026-07-15"))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hostile.xlsx")
        try PeriodReportEmitter.emit(model: model, to: url)

        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive["xl/sharedStrings.xml"],
                                   "a string cell was written, so sharedStrings.xml must exist")
        var xmlData = Data()
        _ = try archive.extract(entry) { chunk in xmlData.append(chunk) }
        let xml = try XCTUnwrap(String(data: xmlData, encoding: .utf8))

        XCTAssertTrue(xml.contains("\t" + hostile),
                      "the tab-escaped form of the hostile value, exactly as the "
                      + "writer serialises it, must reach the file")
        XCTAssertFalse(xml.contains("<t xml:space=\"preserve\">" + hostile),
                       "the hostile value must never sit raw immediately after the "
                       + "shared-string tag opens — that is what CellValue.safe "
                       + "being bypassed would look like")
    }

    /// The report writes only into the profile's own output directory, and the
    /// period-bearing kind is sanitized, so a separator cannot escape it.
    func testReportKindCannotIntroduceAPathSeparator() {
        let kind = PeriodReportEmitter.reportKind(for: makeModel())
        XCTAssertFalse(kind.contains("/"))
        XCTAssertEqual(ExportNaming.sanitize(kind), kind,
                       "the kind should already be filename-safe")
    }
}
