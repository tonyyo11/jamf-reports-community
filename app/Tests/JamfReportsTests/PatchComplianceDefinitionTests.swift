import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 C1: patch compliance is `Σ on_latest / Σ total` over titles that have devices,
/// on every surface. The summary writer, the Compliance Posture sheet, the Executive Summary
/// and the Patch screen all read it from `PatchStatusService.fleetCompliancePct`.
///
/// Fixture, worked by hand. Three titles of different sizes:
///   Chrome 450 of 500 = 90%, Zoom 20 of 100 = 20%, Slack 10 of 10 = 100%.
/// Device-weighted: (450 + 20 + 10) / (500 + 100 + 10) = 480 / 610 = 78.689%.
/// The per-title mean the summary used before: (90 + 20 + 100) / 3 = 70.0%.
final class PatchComplianceDefinitionTests: XCTestCase {

    private var tmpDirs: [URL] = []
    private var anchor: Date!

    override func setUp() {
        super.setUp()
        anchor = GoldenFleetClock.anchorNoon()
    }

    override func tearDown() {
        for dir in tmpDirs { try? FileManager.default.removeItem(at: dir) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        tmpDirs.append(root)
        return root
    }

    private static let weighted = 480.0 / 610.0 * 100.0

    private func row(_ title: String, onLatest: Int, total: Int) -> PatchStatusRow {
        PatchStatusRow(
            title: title, id: title, onLatest: onLatest, onOther: max(total - onLatest, 0),
            total: total, latest: "1.0",
            compliancePct: String(format: "%.1f%%", total > 0
                ? Double(onLatest) / Double(total) * 100 : 0)
        )
    }

    private var threeTitles: [PatchStatusRow] {
        [row("Chrome", onLatest: 450, total: 500),
         row("Zoom", onLatest: 20, total: 100),
         row("Slack", onLatest: 10, total: 10)]
    }

    private var threeTitleSnapshotRows: [[String: Any]] {
        [GoldenFleetWorkspace.patchRow(id: "1", title: "Chrome", onLatest: 450, total: 500),
         GoldenFleetWorkspace.patchRow(id: "2", title: "Zoom", onLatest: 20, total: 100),
         GoldenFleetWorkspace.patchRow(id: "3", title: "Slack", onLatest: 10, total: 10)]
    }

    // MARK: - The function

    func testFigureWeighsEveryDeviceEquallyNotEveryTitle() throws {
        let pct = try XCTUnwrap(PatchStatusService.fleetCompliancePct(threeTitles))
        XCTAssertEqual(pct, Self.weighted, accuracy: 0.0001)
        XCTAssertEqual(pct, 78.689, accuracy: 0.001)
        XCTAssertNotEqual(pct, 70.0, accuracy: 1.0, "the old per-title mean")
    }

    func testTitleWithoutDevicesIsLeftOutOfBothSums() throws {
        // Some jamf-cli builds report a parseable "0%" for a title nobody has.
        let rows = threeTitles + [row("Empty", onLatest: 0, total: 0)]
        let pct = try XCTUnwrap(PatchStatusService.fleetCompliancePct(rows))
        XCTAssertEqual(pct, Self.weighted, accuracy: 0.0001)
    }

    func testNoTitleWithDevicesIsNilNotZero() {
        XCTAssertNil(PatchStatusService.fleetCompliancePct([]))
        XCTAssertNil(PatchStatusService.fleetCompliancePct([row("Empty", onLatest: 0, total: 0)]))
    }

    // MARK: - The summary writer

    private func writeSummary(patchRows: [[String: Any]]) throws -> (DailySummary, URL) {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        // totalDevices > 0 or the writer emits nothing.
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 100, filevault: 100, sip: 100, firewall: 100, gatekeeper: 100),
            to: dataDir.appendingPathComponent("security", isDirectory: true)
                .appendingPathComponent("security_\(GoldenFleetClock.stamp(anchor)).json"))
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: anchor, rows: patchRows)

        ReportEngine(config: ReportConfig(), dataDir: dataDir)
            .emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
        return (summary, summariesDir)
    }

    func testSummaryRecordsTheDeviceWeightedFigureAndItsBasis() throws {
        let (summary, dir) = try writeSummary(patchRows: threeTitleSnapshotRows)

        XCTAssertEqual(try XCTUnwrap(summary.patchPct), 78.7, accuracy: 0.001)
        XCTAssertEqual(summary.patchPctBasis, "device")
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: dir.path)
                .first { $0.hasPrefix("summary_") })
        let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(text.contains("\"patchPctBasis\" : \"device\""), text)
    }

    func testSummaryWithNoTitleOnDevicesOmitsThePercentButStillNamesTheBasis() throws {
        let (summary, _) = try writeSummary(patchRows: [
            GoldenFleetWorkspace.patchRow(id: "1", title: "Empty", onLatest: 0, total: 0),
        ])

        XCTAssertNil(summary.patchPct, "no data is not 0%")
        XCTAssertEqual(summary.patchPctBasis, "device")
    }

    // MARK: - patchPctBasis in summary.json

    func testSummaryWrittenBeforeTheBasisExistedDecodesWithNone() throws {
        let json = #"""
        {"date":"2026-05-10","totalDevices":100,"patchPct":72.5,"source":"jamf-cli"}
        """#
        let summary = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.patchPct, 72.5)
        XCTAssertNil(summary.patchPctBasis)
    }

    func testBasisRoundTripsAndIsAbsentWhenNil() throws {
        func encoded(_ basis: String?) throws -> [String: Any] {
            let summary = DailySummary(
                date: "2026-05-10", totalDevices: 100, fileVaultPct: nil, compliancePct: nil,
                staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: 80,
                patchPctBasis: basis)
            let data = try JSONEncoder().encode(summary)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try encoded("device")["patchPctBasis"] as? String, "device")
        XCTAssertNil(try encoded(nil)["patchPctBasis"])
    }

    // MARK: - The workbook and the Patch screen

    func testPatchScreenFigureIsTheSameFunction() throws {
        let snapshot = PatchStatusService.Snapshot(
            titles: threeTitles, failures: [], sourceFile: nil, snapshotDate: nil)
        XCTAssertEqual(try XCTUnwrap(snapshot.fleetCompliancePct), Self.weighted, accuracy: 0.0001)

        let empty = PatchStatusService.Snapshot(
            titles: [row("Empty", onLatest: 0, total: 0)], failures: [],
            sourceFile: nil, snapshotDate: nil)
        XCTAssertNil(empty.fleetCompliancePct)
    }

    private func sheetValue(
        _ dash: CoreDashboard, sheet: String, labelPrefix: String
    ) throws -> String {
        let ws = try XCTUnwrap(dash.workbook.sheet(named: sheet), "no \(sheet) sheet")
        func text(_ value: CellValue) -> String {
            if case .string(let s) = value { return s }
            return ""
        }
        let cells = ws.dedupedCells
        let label = try XCTUnwrap(
            cells.first { $0.col == 0 && text($0.value).hasPrefix(labelPrefix) },
            "\(sheet) has no row starting \(labelPrefix)")
        let value = try XCTUnwrap(cells.first { $0.row == label.row && $0.col == 1 })
        return text(value.value)
    }

    private func dashboard(patchRows: [[String: Any]]) throws -> CoreDashboard {
        let dataDir = makeRoot().appendingPathComponent("data", isDirectory: true)
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: anchor, rows: patchRows)
        return CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    func testComplianceSheetRowReadsTheDeviceWeightedFigure() throws {
        let dash = try dashboard(patchRows: threeTitleSnapshotRows)
        try dash.writeCompliancePosture()

        // 78.689 rounds to 79%; the old title average rendered 70%.
        XCTAssertEqual(
            try sheetValue(dash, sheet: "Compliance Posture", labelPrefix: "Patch Compliance"),
            "79%")
    }

    func testComplianceSheetRowIsADashWhenNoTitleHasDevices() throws {
        let dash = try dashboard(patchRows: [
            GoldenFleetWorkspace.patchRow(id: "1", title: "Empty", onLatest: 0, total: 0),
        ])
        try dash.writeCompliancePosture()

        XCTAssertEqual(
            try sheetValue(dash, sheet: "Compliance Posture", labelPrefix: "Patch Compliance"),
            "\u{2014}")
    }

    /// Active devices only: the sheet scales each title by the active share, but its fleet
    /// row is the same figure as every other surface.
    private func summaryDashboard(patchRows: [[String: Any]]) throws -> CoreDashboard {
        let dash = try dashboard(patchRows: patchRows)
        let devices: [[String: Any]] = (1...3).map {
            ["name": "Mac-\($0)", "serial": "S\($0)", "managed": true, "stale": false]
        }
        try GoldenFleetWorkspace.writeJSON(
            devices,
            to: dash.dataDir.appendingPathComponent("device-compliance", isDirectory: true)
                .appendingPathComponent("device-compliance_\(GoldenFleetClock.stamp(anchor)).json"))
        try dash.writePatchSummaryDashboard()
        return dash
    }

    func testPatchSummaryDashboardFleetRowReadsTheDeviceWeightedFigure() throws {
        let dash = try summaryDashboard(patchRows: threeTitleSnapshotRows)

        // The per-title mean the row used to show reads 70.0%.
        XCTAssertEqual(
            try sheetValue(dash, sheet: "Patch Summary Dashboard",
                           labelPrefix: "Fleet Compliance (devices on latest)"),
            "78.7%")
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Patch Summary Dashboard"))
        XCTAssertFalse(ws.dedupedCells.contains {
            if case .string(let s) = $0.value { return s.hasPrefix("Average Completion") }
            return false
        })
    }

    func testPatchSummaryDashboardFleetRowIsADashWhenNoTitleHasDevices() throws {
        let dash = try summaryDashboard(patchRows: [
            GoldenFleetWorkspace.patchRow(id: "1", title: "Empty", onLatest: 0, total: 0),
        ])

        XCTAssertEqual(
            try sheetValue(dash, sheet: "Patch Summary Dashboard",
                           labelPrefix: "Fleet Compliance (devices on latest)"),
            "\u{2014}")
    }

    func testExecutiveSummaryRowReadsTheSameFigure() throws {
        let dash = try dashboard(patchRows: threeTitleSnapshotRows)
        try dash.writeExecutiveSummary()

        XCTAssertEqual(
            try sheetValue(dash, sheet: "Executive Summary",
                           labelPrefix: "Patch Fleet Compliance"),
            "78.7%")
    }
}
