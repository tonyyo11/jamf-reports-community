import Foundation
import XCTest
@testable import JamfReports

/// The workbook's Mobile Fleet Summary and Mobile Inventory sheets read the same
/// fields as the Mobile Fleet screen, and write a value the snapshot never measured
/// as blank or "Unknown", not 0, "Unmanaged" or "Clean" (#207 G18).
///
/// Shapes: the `fixtureDir` files are the collected `mobile-device-inventory-details`
/// and `mobile-devices-list` snapshots (hardware and security null on every row). The
/// inline `hardware` and `security` sections follow the Jamf Pro API v2
/// `/mobile-devices/detail` schema (`MobileDeviceHardware`, `MobileDeviceSecurity`),
/// which jamf-cli 1.29 passes through when asked for those sections.
final class CoreDashboardMobileReportTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-mobile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// The collected inventory and list, with the inventory stamped as the newer
    /// snapshot (the order a collect that fetches the list first leaves on disk).
    /// The workbook must not depend on which of the two sorts newest.
    private func inventoryNewerThanList() throws -> URL {
        let tmp = try makeTempDir()
        for (kind, stamp) in [("mobile-devices-list", "T120000000000"),
                              ("mobile-device-inventory-details", "T130000000000")] {
            let kindDir = tmp.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
            try TestFixtures.copyFile(
                TestFixtures.dir("jamf-cli-data/\(kind)/\(kind).json"),
                to: kindDir.appendingPathComponent("\(kind)_2026-04-13\(stamp).json")
            )
        }
        return tmp
    }

    /// Copy collected fixture kinds into a fresh data dir.
    private func dataDir(copying kinds: [String]) throws -> URL {
        let tmp = try makeTempDir()
        for kind in kinds {
            try TestFixtures.copyDir(
                TestFixtures.dir("jamf-cli-data/\(kind)"),
                to: tmp.appendingPathComponent(kind, isDirectory: true)
            )
        }
        return tmp
    }

    /// Write inline JSON as the only snapshot of `kind`.
    private func dataDir(kind: String, json: String) throws -> URL {
        let tmp = try makeTempDir()
        let kindDir = tmp.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try json.write(
            to: kindDir.appendingPathComponent("\(kind).json"), atomically: true, encoding: .utf8
        )
        return tmp
    }

    private func dashboard(_ dir: URL) -> CoreDashboard {
        CoreDashboard(config: ReportConfig(), dataDir: dir, workbook: Workbook())
    }

    private func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return ""
        }
    }

    /// Column 1 of the row whose column 0 reads `label`.
    private func summaryValue(_ ws: Worksheet, _ label: String) -> String? {
        let cells = ws.dedupedCells
        guard let row = cells.first(where: { $0.col == 0 && text($0.value) == label })?.row
        else { return nil }
        return cells.first { $0.row == row && $0.col == 1 }.map { text($0.value) }
    }

    /// The label and count rows under a titled counter block.
    private func counterBlock(_ ws: Worksheet, title: String) -> [String: String] {
        let cells = ws.dedupedCells
        guard let start = cells.first(where: { $0.col == 0 && text($0.value) == title })?.row
        else { return [:] }
        var block: [String: String] = [:]
        var row = start + 2
        while let label = cells.first(where: { $0.row == row && $0.col == 0 }) {
            block[text(label.value)] = cells.first { $0.row == row && $0.col == 1 }
                .map { text($0.value) } ?? ""
            row += 1
        }
        return block
    }

    /// One Mobile Inventory data row, keyed by header.
    private func inventoryRow(_ ws: Worksheet, jamfID: String) throws -> [String: String] {
        let cells = ws.dedupedCells
        let headerRow = try XCTUnwrap(
            cells.first { $0.col == 0 && text($0.value) == "Jamf Pro ID" }?.row)
        let headers = cells.filter { $0.row == headerRow }
            .sorted { $0.col < $1.col }.map { text($0.value) }
        let dataRow = try XCTUnwrap(
            cells.first { $0.row > headerRow && $0.col == 0 && text($0.value) == jamfID }?.row,
            "no inventory row for Jamf Pro ID \(jamfID)")
        var row: [String: String] = [:]
        for (col, header) in headers.enumerated() {
            row[header] = cells.first { $0.row == dataRow && $0.col == col }
                .map { text($0.value) } ?? ""
        }
        return row
    }

    // MARK: - Fields come from the section that carries them

    func testInventoryReadsModelSerialFromHardwareAndPostureFromSecurity() throws {
        let dir = try dataDir(kind: "mobile-device-inventory-details", json: """
        [{"mobileDeviceId": "7", "deviceType": "iOS",
          "hardware": {"model": "iPad Pro 11-inch", "modelIdentifier": "iPad14,3",
                       "serialNumber": "SER-IPAD-7"},
          "security": {"activationLockEnabled": true, "passcodeCompliant": false,
                       "dataProtected": true, "jailBreakDetected": false},
          "general": {"displayName": "Lab iPad 7", "managed": true, "supervised": true,
                      "osVersion": "18.2"}}]
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileInventory()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Inventory"))
        let row = try inventoryRow(ws, jamfID: "7")

        XCTAssertEqual(row["Model"], "iPad Pro 11-inch")
        XCTAssertEqual(row["Serial Number"], "SER-IPAD-7")
        XCTAssertEqual(row["Device Family"], "iPad")
        XCTAssertEqual(row["Activation Lock"], "Yes")
        XCTAssertEqual(row["Passcode Compliant"], "No")
        XCTAssertEqual(row["Data Protection"], "Yes")
        XCTAssertEqual(row["Jailbreak Status"], "None")
    }

    /// Older snapshots put the posture flags and serial under `general`.
    func testInventoryFallsBackToGeneralForPostureAndSerial() throws {
        let dir = try dataDir(kind: "mobile-device-inventory-details", json: """
        [{"mobileDeviceId": "3", "deviceType": "iOS",
          "general": {"displayName": "Old Shape", "serialNumber": "SER-OLD-3",
                      "activationLockEnabled": false, "passcodeCompliant": true,
                      "dataProtectionEnabled": true, "jailbreakDetected": "Not Jailbroken"}}]
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileInventory()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Inventory"))
        let row = try inventoryRow(ws, jamfID: "3")

        XCTAssertEqual(row["Serial Number"], "SER-OLD-3")
        XCTAssertEqual(row["Activation Lock"], "No")
        XCTAssertEqual(row["Passcode Compliant"], "Yes")
        XCTAssertEqual(row["Data Protection"], "Yes")
        XCTAssertEqual(row["Jailbreak Status"], "Not Jailbroken")
    }

    // MARK: - Collected snapshot: the list row supplies what hardware lacks

    /// The collected inventory has no hardware section; model, serial and form factor
    /// come from the list row with the same id, as on the Mobile Fleet screen.
    func testInventoryJoinsTheListRowForModelSerialAndFamily() throws {
        let dir = try inventoryNewerThanList()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileInventory()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Inventory"))

        let first = try inventoryRow(ws, jamfID: "1")
        XCTAssertEqual(first["Model"], "iPhone 5 (CDMA)")
        XCTAssertEqual(first["Serial Number"], "CA44FE1260A3")
        XCTAssertEqual(first["Device Family"], "iPhone")
        let last = try inventoryRow(ws, jamfID: "105")
        XCTAssertEqual(last["Device Family"], "iPad")
    }

    /// Same counts the screen's tiles show for this fixture: 62 iPhone, 41 iPad,
    /// 2 not classifiable. No device lands in a catch-all "Mobile" family.
    func testFleetSummaryFamilyDistributionMatchesTheScreen() throws {
        let dir = try inventoryNewerThanList()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileFleetSummary()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Fleet Summary"))
        let families = counterBlock(ws, title: "Device Family Distribution")

        XCTAssertEqual(families["iPhone"], "62")
        XCTAssertEqual(families["iPad"], "41")
        XCTAssertNil(families["Mobile"])
        let snapshot = MobileFleetService.load(
            listURL: FileManager.newestJSONFile(
                in: dir.appendingPathComponent("mobile-devices-list")),
            inventoryURL: FileManager.newestJSONFile(
                in: dir.appendingPathComponent("mobile-device-inventory-details")),
            profilesURL: nil)
        XCTAssertEqual(families["iPhone"], String(snapshot.iPhoneCount))
        XCTAssertEqual(families["iPad"], String(snapshot.iPadCount))
    }

    // MARK: - Unmeasured values are not zero

    /// The collected inventory carries no security section, so passcode compliance and
    /// activation lock were never measured. The two devices without a general section
    /// have no management state, so they are not "unmanaged" either.
    func testFleetSummaryWritesUnknownForUnmeasuredAndDoesNotCallUnknownUnmanaged() throws {
        let dir = try inventoryNewerThanList()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileFleetSummary()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Fleet Summary"))

        XCTAssertEqual(summaryValue(ws, "Activation Lock Enabled"), "Unknown")
        XCTAssertEqual(summaryValue(ws, "Passcode Compliant"), "Unknown")
        XCTAssertEqual(summaryValue(ws, "Managed Rows"), "103")
        XCTAssertEqual(summaryValue(ws, "Unmanaged Rows"), "0")
        XCTAssertEqual(summaryValue(ws, "Management State Unknown"), "2")
    }

    /// The list snapshot has no management state at all: every row used to read
    /// "Unmanaged".
    func testFleetSummaryFromListOnlyDoesNotCallEveryDeviceUnmanaged() throws {
        let dir = try dataDir(copying: ["mobile-devices-list"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileFleetSummary()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Fleet Summary"))

        XCTAssertEqual(summaryValue(ws, "Inventory Rows Returned"), "105")
        XCTAssertEqual(summaryValue(ws, "Managed Rows"), "Unknown")
        XCTAssertEqual(summaryValue(ws, "Unmanaged Rows"), "Unknown")
        XCTAssertEqual(summaryValue(ws, "Supervised Devices"), "Unknown")
        let families = counterBlock(ws, title: "Device Family Distribution")
        XCTAssertEqual(families["iPhone"], "62")
        XCTAssertEqual(families["iPad"], "41")
    }

    /// A field one device reports still counts, even as `false`; the others are unknown.
    func testFleetSummaryCountsOnlyDevicesThatReportAField() throws {
        let dir = try dataDir(kind: "mobile-device-inventory-details", json: """
        [{"mobileDeviceId": "1", "deviceType": "iOS",
          "security": {"passcodeCompliant": true, "activationLockEnabled": false},
          "general": {"displayName": "A", "managed": true}},
         {"mobileDeviceId": "2", "deviceType": "iOS",
          "general": {"displayName": "B", "managed": false}},
         {"mobileDeviceId": "3", "deviceType": "iOS",
          "general": {"displayName": "C"}}]
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileFleetSummary()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Fleet Summary"))

        XCTAssertEqual(summaryValue(ws, "Passcode Compliant"), "1")
        XCTAssertEqual(summaryValue(ws, "Activation Lock Enabled"), "0")
        XCTAssertEqual(summaryValue(ws, "Managed Rows"), "1")
        XCTAssertEqual(summaryValue(ws, "Unmanaged Rows"), "1")
        XCTAssertEqual(summaryValue(ws, "Management State Unknown"), "1")
    }

    /// The Mobile Inventory sheet's own summary block follows the same rule.
    func testInventorySummaryWritesUnknownForUnmeasuredCounts() throws {
        let dir = try dataDir(copying: ["mobile-devices-list"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = dashboard(dir)
        try dash.writeMobileInventory()
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Mobile Inventory"))

        XCTAssertEqual(summaryValue(ws, "Managed"), "Unknown")
        XCTAssertEqual(summaryValue(ws, "Unmanaged"), "Unknown")
        XCTAssertEqual(summaryValue(ws, "Total Mobile Devices"), "105")
    }
}
