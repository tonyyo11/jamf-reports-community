import Foundation
import XCTest
@testable import JamfReports

// MARK: - CoverSheetTests
// Verifies that the Cover sheet method and sheetPlan ordering behave correctly.

final class CoverSheetTests: XCTestCase {

    // MARK: - Helpers

    private func makeDashboard(config: ReportConfig = ReportConfig()) -> CoreDashboard {
        CoreDashboard(
            config: config,
            dataDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("jrc-cover-\(UUID().uuidString)"),
            workbook: Workbook()
        )
    }

    // MARK: - Cover sheet renders without throwing

    func testCoverSheetRendersWithoutData() {
        // writeCoverSheet must never throw — missing snapshots are shown as placeholders.
        let dash = makeDashboard()
        XCTAssertNoThrow(try dash.writeCoverSheet())
    }

    // MARK: - Executive Summary is the first sheet in sheetPlan

    func testExecutiveSummaryIsFirstSheetInPlan() {
        let dash = makeDashboard()
        XCTAssertEqual(dash.sheetPlan.first?.name, "Executive Summary")
    }

    // MARK: - Cover is the second sheet in sheetPlan

    func testCoverIsSecondSheetInPlan() {
        let dash = makeDashboard()
        guard dash.sheetPlan.count >= 2 else {
            XCTFail("sheetPlan has fewer than 2 entries")
            return
        }
        XCTAssertEqual(dash.sheetPlan[1].name, "Cover")
    }

    // MARK: - Compliance Posture is the third sheet

    func testCompliancePostureIsThirdInPlan() {
        let dash = makeDashboard()
        guard dash.sheetPlan.count >= 3 else {
            XCTFail("sheetPlan has fewer than 3 entries")
            return
        }
        XCTAssertEqual(dash.sheetPlan[2].name, "Compliance Posture")
    }

    // MARK: - Exec-priority sheet ordering

    func testExecPrioritySheetOrder() {
        let dash = makeDashboard()
        let names = dash.sheetPlan.map(\.name)
        // First eight sheets must be exec-priority in specified order.
        // Executive Summary was added as sheet 1 in v2.1.1.
        let expectedTop8 = [
            "Executive Summary",
            "Cover",
            "Compliance Posture",
            "Fleet Overview",
            "Security Posture",
            "Patch Compliance",
            "Device Compliance",
            "Audit Summary",
        ]
        let actualTop8 = Array(names.prefix(8))
        XCTAssertEqual(actualTop8, expectedTop8)
    }

    // MARK: - Sheet manifest

    func testEveryPlannedTabHasADescription() {
        let descriptions = CoreDashboard.sheetManifestDescriptions()
        let missing = makeDashboard().sheetPlan.map(\.name).filter { descriptions[$0] == nil }
        XCTAssertEqual(missing, [])
        XCTAssertNotNil(descriptions["EA Warnings"])
        XCTAssertNotNil(descriptions[ReportEngine.chartsSheetName])
    }

    /// The manifest lists the tabs the workbook holds, in tab order, after `sheets.order` and
    /// the custom EA tabs, and none it does not hold.
    func testManifestListsTheWrittenTabsInOrder() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cover-gen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let ea = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: ea, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            ["definition_id": "1", "device": "Mac-1", "ea_name": "FV", "value": "Encrypted"],
        ]).write(to: ea.appendingPathComponent("ea-results_20261111T120000.json"))
        let config = try ConfigLoader.loadFromString("""
        custom_eas:
          - {name: FileVault, column: FV, type: boolean, true_value: Encrypted}
        sheets:
          order: [FileVault]
        """)
        let out = dataDir.appendingPathComponent("out/report.xlsx")
        try await ReportEngine(config: config, dataDir: dataDir)
            .generate(outputURL: out, locateJamfCLI: { nil })

        let tabs = try XLSXReader.tabs(of: out)
        let cover = try XCTUnwrap(tabs.first { $0.name == "Cover" })
        func text(_ cell: XLSXReader.Cell?) -> String? {
            if case .text(let value)? = cell { return value }
            return nil
        }
        let start = try XCTUnwrap(cover.rows.firstIndex { text($0.first) == "Sheet Manifest" })
        let manifest = cover.rows[(start + 1)...].filter { !$0.isEmpty }
        XCTAssertEqual(manifest.map { text($0.first) },
                       tabs.enumerated().map { "\($0.offset + 1). \($0.element.name)" })
        XCTAssertEqual(tabs.first?.name, "FileVault")
        XCTAssertEqual(text(manifest.first?.dropFirst().first),
                       "Custom extension attribute: FV")
        for row in manifest {
            XCTAssertFalse((text(row.dropFirst().first) ?? "").isEmpty, "\(row)")
        }
        let cells = cover.rows.flatMap { $0 }.compactMap(text)
        XCTAssertFalse(cells.contains { $0.hasPrefix("Sheets ") },
                       "no numbered ranges that can name tabs the workbook lacks")
    }
}
