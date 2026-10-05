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
}
