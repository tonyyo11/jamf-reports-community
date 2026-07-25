import Foundation
import XCTest
@testable import JamfReports

/// Tests for the "OS Currency" CoreDashboard sheet and related SheetID/SectionID
/// registration requirements.
@MainActor
final class OSCurrencySheetTests: XCTestCase {

    private nonisolated(unsafe) var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSCurrencyTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - SheetID registration

    func testOSCurrencySheetIDExists() {
        XCTAssertEqual(SheetID.osCurrency.rawValue, "OS Currency")
    }

    func testOSCurrencySectionIDExists() {
        XCTAssertEqual(SectionID.osCurrency.rawValue, "os_currency")
    }

    func testFullInstanceTemplateIncludesOSCurrencySheet() {
        XCTAssertTrue(
            FullInstanceTemplate().includedSheets.contains(.osCurrency),
            "FullInstanceTemplate must include .osCurrency"
        )
    }

    func testFullInstanceTemplateIncludesOSCurrencySection() {
        XCTAssertTrue(
            FullInstanceTemplate().htmlSections.contains(.osCurrency),
            "FullInstanceTemplate must include .osCurrency HTML section"
        )
    }

    // MARK: - Sheet plan registration

    func testSheetPlanContainsOSCurrency() {
        let config = ReportConfig()
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        let planNames = dashboard.sheetPlan.map { $0.name }
        XCTAssertTrue(planNames.contains("OS Currency"),
                      "CoreDashboard.sheetPlan must contain 'OS Currency'")
    }

    // MARK: - Note row when SOFA cache absent

    func testWritesNoteRowWhenNoSOFACache() {
        let config = ReportConfig()
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        // Should not throw — graceful empty state
        XCTAssertNoThrow(try dashboard.writeOSCurrency())
        let ws = workbook.sheet(named: "OS Currency")
        XCTAssertNotNil(ws, "Worksheet should exist even without SOFA cache")
        // The note row must be present
        let cells = ws?.dedupedCells ?? []
        let noteCell = cells.first { cell in
            if case let .string(s) = cell.value {
                return s.contains("SOFA feed unavailable")
            }
            return false
        }
        XCTAssertNotNil(noteCell, "Note row must contain 'SOFA feed unavailable'")
    }

    // MARK: - Sheet writes data when SOFA cache present

    func testWritesDataWhenSOFACachePresent() throws {
        // Copy the macos fixture into the expected location.
        try copyMacOSFixture()

        let config = ReportConfig()
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        XCTAssertNoThrow(try dashboard.writeOSCurrency())

        let ws = try XCTUnwrap(workbook.sheet(named: "OS Currency"))
        let cells = ws.dedupedCells
        // Headers must be present
        let hasLatestVersionHeader = cells.contains { cell in
            if case let .string(s) = cell.value { return s == "Latest Version" }
            return false
        }
        XCTAssertTrue(hasLatestVersionHeader, "Header row must include 'Latest Version'")
        // Platform label must match Python's SOFA_PLATFORM_LABELS["macos"]
        let hasMacOSPlatform = cells.contains { cell in
            if case let .string(s) = cell.value { return s == "macOS" }
            return false
        }
        XCTAssertTrue(hasMacOSPlatform, "Platform label must be 'macOS' (matches Python parity)")
    }

    // MARK: - EOL row emitted for old-major devices

    func testEOLRowEmittedWhenOldMajorDevicesPresent() throws {
        try copyMacOSFixture()
        // Write a minimal security snapshot with a device on macOS 13.
        try writeSecuritySnapshot()

        let config = ReportConfig()
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        XCTAssertNoThrow(try dashboard.writeOSCurrency())

        let ws = try XCTUnwrap(workbook.sheet(named: "OS Currency"))
        let cells = ws.dedupedCells
        let hasEOLRow = cells.contains { cell in
            if case let .string(s) = cell.value { return s.contains("Out of support (EOL)") }
            return false
        }
        XCTAssertTrue(hasEOLRow,
                      "EOL row must be emitted when devices are on majors older than SOFA families")
    }

    // MARK: - Helpers

    private func copyMacOSFixture() throws {
        let fixtureURL = TestFixtures.dir("sofa/macos_data_feed.json")
        let sofaDir = tmpDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: sofaDir, withIntermediateDirectories: true)
        let dest = sofaDir.appendingPathComponent("macos_data_feed.json")
        try TestFixtures.copyFile(fixtureURL, to: dest)
    }

    /// Write a minimal security snapshot containing macOS 13 devices (EOL).
    private func writeSecuritySnapshot() throws {
        let json = """
        [
          {"section": "summary", "data": {"total_devices": 110,
           "filevault_encrypted": 100, "sip_enabled": 105,
           "firewall_enabled": 108, "gatekeeper_enabled": 110}},
          {"section": "os_version", "os_version": "15.7.3", "count": 100, "pct": "90%"},
          {"section": "os_version", "os_version": "13.7.0", "count": 10, "pct": "9%"}
        ]
        """
        let dir = tmpDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("security_20260601T120000.json")
        try Data(json.utf8).write(to: file)
    }
}
