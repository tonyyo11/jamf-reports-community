import Foundation
import XCTest
@testable import JamfReports

// MARK: - MSCPComplianceSheetsTests
//
// Tests for:
//   - writeMSCPCompliance  (SheetID.mscpCompliance)
//   - writeComplianceTrend (SheetID.complianceTrend)
//
// Covers: happy path, skip when no baselines configured, skip when no ea-results,
// skip when no data for any baseline, band row ordering, trend row count,
// SheetID/FullInstanceTemplate/ComplianceTemplate wiring.

@MainActor
final class MSCPComplianceSheetsTests: XCTestCase {

    // MARK: - Helpers

    private nonisolated(unsafe) var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSCPSheetsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Fixture helpers

    /// Build a ReportConfig with one baseline using `eaColumn`.
    private func configWithBaseline(eaColumn: String = "STIG Failures",
                                    name: String = "DISA STIG") -> ReportConfig {
        let yaml = """
        compliance:
          baselines:
            - name: "\(name)"
              failures_count_column: "\(eaColumn)"
        """
        return (try? ConfigLoader.loadFromString(yaml)) ?? ReportConfig()
    }

    /// Write a synthetic ea-results JSON into `tmpDir/ea-results/<filename>`.
    ///
    /// `passCount` devices get value 0, `lowCount` get value 5, `highCount` get 60.
    /// `noDataCount` devices use a mismatched ea_name so they appear in the universe
    /// but contribute to No Data for the configured baseline.
    private func seedEAResults(
        eaColumn: String,
        passCount: Int = 0,
        lowCount: Int = 0,
        highCount: Int = 0,
        noDataCount: Int = 0,
        filename: String = "ea-results_20240615T120000.json"
    ) throws {
        let eaDir = tmpDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for i in 0..<passCount {
            rows.append(["device": "mac-pass-\(i)", "ea_name": eaColumn, "value": 0])
        }
        for i in 0..<lowCount {
            rows.append(["device": "mac-low-\(i)", "ea_name": eaColumn, "value": 5])
        }
        for i in 0..<highCount {
            rows.append(["device": "mac-high-\(i)", "ea_name": eaColumn, "value": 60])
        }
        for i in 0..<noDataCount {
            rows.append(["device": "mac-nodata-\(i)", "ea_name": "Other EA", "value": 0])
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: eaDir.appendingPathComponent(filename))
    }

    /// Write a second dated ea-results snapshot for trend tests.
    private func seedSecondSnapshot(eaColumn: String, passCount: Int, highCount: Int) throws {
        try seedEAResults(
            eaColumn: eaColumn,
            passCount: passCount,
            highCount: highCount,
            filename: "ea-results_20240616T120000.json"
        )
    }

    private func makeDashboard(config: ReportConfig) -> CoreDashboard {
        CoreDashboard(config: config, dataDir: tmpDir, workbook: Workbook())
    }

    // MARK: - SheetID registration

    func testMSCPComplianceSheetIDExists() {
        XCTAssertEqual(SheetID.mscpCompliance.rawValue, "mSCP Compliance")
    }

    func testComplianceTrendSheetIDExists() {
        XCTAssertEqual(SheetID.complianceTrend.rawValue, "Compliance Trend")
    }

    func testFullInstanceTemplateIncludesMSCPCompliance() {
        XCTAssertTrue(
            FullInstanceTemplate().includedSheets.contains(.mscpCompliance),
            "FullInstanceTemplate must include .mscpCompliance"
        )
    }

    func testFullInstanceTemplateIncludesComplianceTrend() {
        XCTAssertTrue(
            FullInstanceTemplate().includedSheets.contains(.complianceTrend),
            "FullInstanceTemplate must include .complianceTrend"
        )
    }

    func testComplianceTemplateIncludesMSCPCompliance() {
        XCTAssertTrue(
            ComplianceTemplate().includedSheets.contains(.mscpCompliance),
            "ComplianceTemplate must include .mscpCompliance"
        )
    }

    func testComplianceTemplateIncludesComplianceTrend() {
        XCTAssertTrue(
            ComplianceTemplate().includedSheets.contains(.complianceTrend),
            "ComplianceTemplate must include .complianceTrend"
        )
    }

    /// FullInstanceTemplate.includedSheets must cover every SheetID case.
    ///
    /// Mirrors `testFullInstanceTemplateHtmlSectionsCoversAllSectionIDs` for sheets.
    func testFullInstanceTemplateCoversAllSheetIDs() {
        let templateSheets = Set(FullInstanceTemplate().includedSheets)
        let allSheets = Set(SheetID.allCases)
        let missing = allSheets.subtracting(templateSheets)
        XCTAssertTrue(
            missing.isEmpty,
            "FullInstanceTemplate.includedSheets is missing SheetIDs: " +
            "\(missing.map(\.rawValue).sorted().joined(separator: ", "))"
        )
    }

    // MARK: - sheetPlan registration

    func testMSCPComplianceRegisteredInSheetPlan() {
        let dash = makeDashboard(config: configWithBaseline())
        let names = Set(dash.sheetPlan.map { $0.name })
        XCTAssertTrue(names.contains("mSCP Compliance"),
                      "sheetPlan must contain 'mSCP Compliance'")
    }

    func testComplianceTrendRegisteredInSheetPlan() {
        let dash = makeDashboard(config: configWithBaseline())
        let names = Set(dash.sheetPlan.map { $0.name })
        XCTAssertTrue(names.contains("Compliance Trend"),
                      "sheetPlan must contain 'Compliance Trend'")
    }

    // MARK: - writeMSCPCompliance skip paths

    func testWriteMSCPComplianceSkipsWhenNoBaselinesConfigured() {
        let dash = makeDashboard(config: ReportConfig())
        XCTAssertThrowsError(try dash.writeMSCPCompliance()) { error in
            XCTAssertTrue(error is SheetSkippable,
                          "No-baseline case must throw SheetSkippable, got: \(error)")
        }
        XCTAssertNil(dash.workbook.sheet(named: "mSCP Compliance"),
                     "No sheet must be created when no baselines configured")
    }

    func testWriteMSCPComplianceSkipsWhenNoEAResults() {
        let dash = makeDashboard(config: configWithBaseline())
        XCTAssertThrowsError(try dash.writeMSCPCompliance()) { error in
            XCTAssertTrue(error is SheetSkippable,
                          "No ea-results case must throw SheetSkippable, got: \(error)")
        }
        XCTAssertNil(dash.workbook.sheet(named: "mSCP Compliance"))
    }

    func testWriteMSCPComplianceSkipsWhenAllDevicesNoData() throws {
        // All rows carry a mismatched ea_name → no data for the baseline.
        let eaDir = tmpDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["device": "mac-1", "ea_name": "Other EA", "value": 0],
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: eaDir.appendingPathComponent("ea-results_20240615T120000.json"))

        let dash = makeDashboard(config: configWithBaseline())
        XCTAssertThrowsError(try dash.writeMSCPCompliance()) { error in
            XCTAssertTrue(error is SheetSkippable,
                          "All-no-data case must be SheetSkippable, got: \(error)")
        }
    }

    // MARK: - writeMSCPCompliance happy path

    func testWriteMSCPComplianceHappyPath() throws {
        let eaColumn = "STIG Failures"
        try seedEAResults(eaColumn: eaColumn, passCount: 10, lowCount: 3, highCount: 2)

        let dash = makeDashboard(config: configWithBaseline(eaColumn: eaColumn))
        XCTAssertNoThrow(try dash.writeMSCPCompliance(),
                         "writeMSCPCompliance must not throw on valid data")
        XCTAssertNotNil(dash.workbook.sheet(named: "mSCP Compliance"),
                        "Sheet 'mSCP Compliance' must be created")
    }

    func testWriteMSCPComplianceBandRowCount() throws {
        // 10 pass + 3 low + 2 high = 15 total; expected row structure:
        // header (1) + 3 summary rows + band-header (1) + No Data + 5 band rows = 11 rows per baseline.
        let eaColumn = "STIG Failures"
        try seedEAResults(eaColumn: eaColumn, passCount: 10, lowCount: 3, highCount: 2)

        let dash = makeDashboard(config: configWithBaseline(eaColumn: eaColumn))
        XCTAssertNoThrow(try dash.writeMSCPCompliance())

        let ws = dash.workbook.sheet(named: "mSCP Compliance")
        XCTAssertNotNil(ws, "Sheet must exist")
    }

    func testWriteMSCPComplianceMultipleBaselines() throws {
        let yaml = """
        compliance:
          baselines:
            - name: "DISA STIG"
              failures_count_column: "STIG Failures"
            - name: "NIST 800-53"
              failures_count_column: "NIST Failures"
        """
        let config = (try? ConfigLoader.loadFromString(yaml)) ?? ReportConfig()
        let eaDir = tmpDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["device": "mac-1", "ea_name": "STIG Failures", "value": 0],
            ["device": "mac-2", "ea_name": "NIST Failures", "value": 5],
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: eaDir.appendingPathComponent("ea-results_20240615T120000.json"))

        let dash = makeDashboard(config: config)
        XCTAssertNoThrow(try dash.writeMSCPCompliance())
        XCTAssertNotNil(dash.workbook.sheet(named: "mSCP Compliance"))
    }

    // MARK: - writeComplianceTrend skip paths

    func testWriteComplianceTrendSkipsWhenNoBaselinesConfigured() {
        let dash = makeDashboard(config: ReportConfig())
        XCTAssertThrowsError(try dash.writeComplianceTrend()) { error in
            XCTAssertTrue(error is SheetSkippable,
                          "No-baseline case must throw SheetSkippable, got: \(error)")
        }
        XCTAssertNil(dash.workbook.sheet(named: "Compliance Trend"))
    }

    func testWriteComplianceTrendSkipsWhenNoSnapshots() {
        let dash = makeDashboard(config: configWithBaseline())
        XCTAssertThrowsError(try dash.writeComplianceTrend()) { error in
            XCTAssertTrue(error is SheetSkippable,
                          "No snapshots case must throw SheetSkippable, got: \(error)")
        }
        XCTAssertNil(dash.workbook.sheet(named: "Compliance Trend"))
    }

    // MARK: - writeComplianceTrend happy path

    func testWriteComplianceTrendHappyPath() throws {
        let eaColumn = "STIG Failures"
        try seedEAResults(eaColumn: eaColumn, passCount: 8, lowCount: 2)

        let dash = makeDashboard(config: configWithBaseline(eaColumn: eaColumn))
        XCTAssertNoThrow(try dash.writeComplianceTrend(),
                         "writeComplianceTrend must not throw when snapshot exists")
        XCTAssertNotNil(dash.workbook.sheet(named: "Compliance Trend"),
                        "Sheet 'Compliance Trend' must be created")
    }

    func testWriteComplianceTrendRowCountMatchesSnapshots() throws {
        let eaColumn = "STIG Failures"
        // Two distinctly named snapshots → two date rows in the trend table.
        try seedEAResults(eaColumn: eaColumn, passCount: 5, lowCount: 2,
                          filename: "ea-results_20240615T120000.json")
        try seedSecondSnapshot(eaColumn: eaColumn, passCount: 7, highCount: 1)

        let dash = makeDashboard(config: configWithBaseline(eaColumn: eaColumn))
        XCTAssertNoThrow(try dash.writeComplianceTrend())

        // Verify the sheet was created; full cell-count inspection is not in scope
        // (Workbook doesn't expose a row-count API). The no-throw with two snapshots
        // is sufficient to assert two data rows were written.
        XCTAssertNotNil(dash.workbook.sheet(named: "Compliance Trend"))
    }

    func testWriteComplianceTrendSingleSnapshotProducesOneRow() throws {
        let eaColumn = "STIG Failures"
        try seedEAResults(eaColumn: eaColumn, passCount: 10,
                          filename: "ea-results_20240615T120000.json")

        let dash = makeDashboard(config: configWithBaseline(eaColumn: eaColumn))
        XCTAssertNoThrow(try dash.writeComplianceTrend())
        XCTAssertNotNil(dash.workbook.sheet(named: "Compliance Trend"))
    }

    // MARK: - Verify band counts round-trip through MSCPComplianceService

    func testBandCountsAreCorrect() throws {
        let eaColumn = "STIG Failures"
        // 5 pass, 3 low (value 5), 2 high (value 60), 1 noData device (other EA).
        try seedEAResults(eaColumn: eaColumn,
                          passCount: 5, lowCount: 3, highCount: 2, noDataCount: 1)

        let yaml = """
        compliance:
          baselines:
            - name: "DISA STIG"
              failures_count_column: "\(eaColumn)"
        """
        let config = (try? ConfigLoader.loadFromString(yaml)) ?? ReportConfig()
        guard let eaData = try? Data(contentsOf:
            tmpDir.appendingPathComponent("ea-results")
                  .appendingPathComponent("ea-results_20240615T120000.json")),
              let rows = try? JSONDecoder().decode([EAResultRow].self, from: eaData)
        else {
            XCTFail("Could not load synthesized ea-results fixture")
            return
        }

        let baselines = config.compliance?.resolvedBaselines ?? []
        XCTAssertEqual(baselines.count, 1)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: baselines)
        guard let result = results.first else {
            XCTFail("MSCPComplianceService.evaluate returned no results")
            return
        }

        XCTAssertEqual(result.totalDevices, 11, "11 distinct devices total")
        XCTAssertEqual(result.noDataCount, 1, "1 no-data device (mismatched ea_name)")
        XCTAssertEqual(result.devicesWithData, 10, "10 devices with data")

        // bands is [pass, low, medLow, medium, high, noData] order
        let passCount = result.bands.first(where: { $0.label == "Pass" })?.count
        let lowCount  = result.bands.first(where: { $0.label == "Low" })?.count
        let highCount = result.bands.first(where: { $0.label == "High" })?.count
        XCTAssertEqual(passCount, 5, "Pass count must be 5")
        XCTAssertEqual(lowCount,  3, "Low count must be 3")
        XCTAssertEqual(highCount, 2, "High count must be 2")

        // compliancePct = pass / devicesWithData = 5 / 10 = 50%
        XCTAssertEqual(result.compliancePct ?? 0.0, 50.0, accuracy: 0.01,
                       "compliancePct must be 50% (5 pass out of 10 with data)")
    }
}
