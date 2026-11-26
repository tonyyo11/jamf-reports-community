import XCTest
@testable import JamfReports

/// Plans with no USB control set or prevent list (wave E, slice E2): neutral counts on the
/// Protect screen's Plans card and the workbook's Protect Plans tab.
final class ProtectConfigurationTests: XCTestCase {

    private func decode(_ json: String) throws -> [ProtectPlanRow] {
        try JSONDecoder().decode([ProtectPlanRow].self, from: Data(json.utf8))
    }

    func testTheDecoderReadsBothReferencesAndToleratesTheWrongType() throws {
        let rows = try decode("""
        [{"name":"A","usbControlSet":"Block","preventListSets":"Dev, Ops"},
         {"name":"B","preventListSets":""},
         {"name":"C","usbControlSet":7,"preventListSets":false}]
        """)
        XCTAssertEqual(rows[0].usbControlSet, .names("Block"))
        XCTAssertEqual(rows[0].preventListSets, .names("Dev, Ops"))
        XCTAssertEqual(rows[1].usbControlSet, .absent, "jamf-cli leaves the key out when unset")
        XCTAssertEqual(rows[1].preventListSets, .names(""))
        XCTAssertEqual(rows[2].usbControlSet, .unreadable)
        XCTAssertEqual(rows[2].preventListSets, .unreadable)
        XCTAssertEqual(rows[2].name, "C", "a bad field costs that field only")
    }

    func testBlankAndAbsentAreUnset() throws {
        let rows = try decode("""
        [{"usbControlSet":"Block","preventListSets":"Dev"},
         {"usbControlSet":"  ","preventListSets":""},
         {"preventListSets":" "},
         {"usbControlSet":"\\n\\t","preventListSets":"\\n"}]
        """)
        let counts = try XCTUnwrap(ProtectConfiguration.counts(plans: rows))
        XCTAssertEqual(counts.noUSBControl, .init(met: 3, of: 4), "newlines and tabs are blank")
        XCTAssertEqual(counts.noPreventList, .init(met: 3, of: 4))
    }

    func testAValueThatIsNotTextIsLeftOutOfItsCount() throws {
        let rows = try decode("""
        [{"usbControlSet":7,"preventListSets":"Dev"},
         {"preventListSets":false}]
        """)
        let counts = try XCTUnwrap(ProtectConfiguration.counts(plans: rows))
        XCTAssertEqual(counts.noUSBControl, .init(met: 1, of: 1), "never measured as a gap")
        XCTAssertEqual(counts.noPreventList, .init(met: 0, of: 1))
        let unread = try XCTUnwrap(ProtectConfiguration.counts(
            plans: try decode(#"[{"usbControlSet":[],"preventListSets":1}]"#)))
        XCTAssertNil(unread.noUSBControl)
        XCTAssertNil(unread.noPreventList)
        XCTAssertEqual(unread.reportRows[0].1, ProtectConfiguration.unreadableNote)
    }

    func testTheCapturedJamfCLI138PlanShapeReportsAnEmptyPreventList() throws {
        let rows = try JSONDecoder().decode([ProtectPlanRow].self, from: Data(contentsOf:
            TestFixtures.dir("protect-wave-e/protect-plans-1.38.json")))
        XCTAssertEqual(rows.first?.preventListSets, .names(""))
        let counts = try XCTUnwrap(ProtectConfiguration.counts(plans: rows))
        XCTAssertEqual(counts.noPreventList, .init(met: 1, of: 1))
        XCTAssertEqual(counts.noUSBControl, .init(met: 0, of: 1))
    }

    func testAJamfCLIBefore137DoesNotReportPreventLists() throws {
        let rows = try decode(#"[{"name":"A"},{"name":"B","usbControlSet":"Block"}]"#)
        let counts = try XCTUnwrap(ProtectConfiguration.counts(plans: rows))
        XCTAssertEqual(counts.noUSBControl, .init(met: 1, of: 2))
        XCTAssertNil(counts.noPreventList, "never N of N for a field jamf-cli did not send")
        XCTAssertEqual(counts.reportRows[1].1, ProtectConfiguration.notReportedNote)
        XCTAssertNil(ProtectConfiguration.counts(plans: []))
    }

    private func planGrid(_ rows: [[String: Any]]) throws -> [Int: [Int: String]] {
        let root = GoldenFleetWorkspace.freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "protect-plans", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(), rows: rows)
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
        try dash.writeProtectPlans()
        var grid: [Int: [Int: String]] = [:]
        for cell in try XCTUnwrap(dash.workbook.sheet(named: "Protect Plans")?.dedupedCells) {
            if case .string(let text) = cell.value { grid[cell.row, default: [:]][cell.col] = text }
        }
        return grid
    }

    func testTheWorkbookAppendsTheCountsAfterThePlanRows() throws {
        let grid = try planGrid([
            ["name": "Lab", "logLevel": "INFO", "autoUpdate": false,
             "unifiedLoggingFilterSets": "", "preventListSets": ""],
            ["name": "Standard", "logLevel": "INFO", "autoUpdate": true,
             "usbControlSet": "Block", "unifiedLoggingFilterSets": "", "preventListSets": "Dev"],
        ])
        XCTAssertEqual(grid[3]?[5], "USB Control Set", "existing columns stay put")
        XCTAssertEqual(grid[4]?[0], "Lab")
        XCTAssertEqual(grid[5]?[0], "Standard")
        XCTAssertNil(grid[6], "a blank row before the counts")
        XCTAssertEqual(grid[7]?[0], "Plans with no USB control set")
        XCTAssertEqual(grid[7]?[1], "1 of 2")
        XCTAssertEqual(grid[8]?[0], "Plans with no prevent list")
        XCTAssertEqual(grid[8]?[1], "1 of 2")
    }

    func testTheWorkbookSaysAnOlderJamfCLIDidNotReportPreventLists() throws {
        let grid = try planGrid([["name": "Lab", "usbControlSet": 3], ["name": "Standard"]])
        XCTAssertEqual(grid[7]?[1], "1 of 1", "the row that is not text is left out")
        XCTAssertEqual(grid[8]?[1], ProtectConfiguration.notReportedNote)
    }

    func testTheDemoPlansGiveCountsBelowTheTotal() throws {
        let counts = try XCTUnwrap(ProtectConfiguration.counts(
            plans: DemoData.protectSnapshot.plans))
        XCTAssertEqual(counts.noUSBControl, .init(met: 2, of: 3))
        XCTAssertEqual(counts.noPreventList, .init(met: 2, of: 3))
    }
}
