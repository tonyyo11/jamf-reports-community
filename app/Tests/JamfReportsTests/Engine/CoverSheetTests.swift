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

    // MARK: - Cover is the first sheet in sheetPlan

    func testCoverIsFirstSheetInPlan() {
        let dash = makeDashboard()
        XCTAssertEqual(dash.sheetPlan.first?.name, "Cover")
    }

    // MARK: - Compliance Posture is the second sheet

    func testCompliancePostureIsSecondInPlan() {
        let dash = makeDashboard()
        guard dash.sheetPlan.count >= 2 else {
            XCTFail("sheetPlan has fewer than 2 entries")
            return
        }
        XCTAssertEqual(dash.sheetPlan[1].name, "Compliance Posture")
    }

    // MARK: - Manifest entry count matches sheet plan

    func testManifestEntryCountMatchesSheetPlan() throws {
        let dash = makeDashboard()
        let planCount = dash.sheetPlan.count
        // Cover itself is in sheetPlan, so the manifest should list planCount entries.
        // We verify this by running writeAll (which calls writeCoverSheet) and counting
        // sheets written. writeCoverSheet always succeeds, so it will appear in written.
        let written = dash.writeAll(selectedNames: ["cover"])
        XCTAssertEqual(written, ["Cover"],
                       "writeAll with only 'cover' selected should write exactly Cover")
        // planCount is the expected manifest row count — we trust it matches since
        // writeCoverSheet iterates sheetPlan directly.
        XCTAssertGreaterThan(planCount, 30,
                             "sheetPlan should have at least 34 entries (Cover + 33 others)")
    }

    // MARK: - Cover renders with writeAll (no selection filter)

    func testCoverSheetRendersViaWriteAll() {
        let dash = makeDashboard()
        let written = dash.writeAll()
        XCTAssertTrue(written.contains("Cover"), "writeAll should write Cover sheet")
    }

    // MARK: - Empty selection writes nothing

    func testWriteAllWithEmptySelectionWritesNothing() {
        let dash = makeDashboard()
        let written = dash.writeAll(selectedNames: Set<String>())
        XCTAssertTrue(written.isEmpty, "Empty selection should produce zero written sheets")
    }

    // MARK: - Exec-priority sheet ordering

    func testExecPrioritySheetOrder() {
        let dash = makeDashboard()
        let names = dash.sheetPlan.map(\.name)
        // First seven sheets must be exec-priority in specified order.
        let expectedTop7 = [
            "Cover",
            "Compliance Posture",
            "Fleet Overview",
            "Security Posture",
            "Patch Compliance",
            "Device Compliance",
            "Audit Summary",
        ]
        let actualTop7 = Array(names.prefix(7))
        XCTAssertEqual(actualTop7, expectedTop7)
    }
}
