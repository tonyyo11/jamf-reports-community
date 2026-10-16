import Foundation
import XCTest
@testable import JamfReports

/// #290: a Mac first seen in a CSV import as an unenrolled "DEP - <serial>" record kept that
/// name, its security values and a 1970 check-in on Devices and Overview after it enrolled,
/// because the CSV was merged first and every field kept the first non-empty value.
final class DeviceInventorySourceOrderTests: XCTestCase {

    private var root: URL!
    private let profile = "sourceorder"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-source-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: URL {
        root.appendingPathComponent(profile, isDirectory: true)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// The reported case: the import still counts as current (no date in its name), and the
    /// newer `computers` snapshot holds the enrolled Mac.
    private func seedEnrolledDEPMac() throws -> String {
        try write(
            "Computer Name,Serial Number,Jamf ID,Department,Managed,Last Check-in,"
                + "FileVault 2 Status,System Integrity Protection\n"
                + "DEP - SER290,SER290,290,Engineering,Unmanaged,1970-01-01 00:00:00,"
                + "Not Encrypted,Disabled\n",
            to: "csv-inbox/inventory.csv"
        )
        let checkIn = iso(Date().addingTimeInterval(-3600))
        try write(
            """
            [{"id": "290", "udid": "UDID-290",
              "general": {"name": "Mac-290", "lastCheckIn": "\(checkIn)",
                          "reportDate": "\(checkIn)",
                          "remoteManagement": {"managed": true}},
              "hardware": {"serialNumber": "SER290"},
              "security": {"sipStatus": "ENABLED"},
              "diskEncryption": {"bootPartitionEncryptionDetails":
                                 {"partitionFileVault2State": "ENCRYPTED"}}}]
            """,
            to: "jamf-cli-data/computers/computers_20261016T060000.json"
        )
        return checkIn
    }

    func testSnapshotValuesWinOverTheImportedCSV() throws {
        let checkIn = try seedEnrolledDEPMac()
        let devices = DeviceInventoryService.load(profile: profile, demoMode: false).devices
        XCTAssertEqual(devices.count, 1, "the CSV row and the snapshot are one Mac")
        let mac = try XCTUnwrap(devices.first)
        XCTAssertEqual(mac.name, "Mac-290")
        XCTAssertEqual(mac.fileVault, "ENCRYPTED")
        XCTAssertEqual(mac.sip, "ENABLED")
        XCTAssertEqual(mac.managedState, "Managed")
        XCTAssertEqual(mac.lastContact, checkIn, "Last check-in must not stay at 1970")
        XCTAssertFalse(mac.isBinaryMissing)
    }

    func testCSVStillFillsWhatTheSnapshotLacks() throws {
        _ = try seedEnrolledDEPMac()
        let mac = try XCTUnwrap(
            DeviceInventoryService.load(profile: profile, demoMode: false).devices.first
        )
        XCTAssertEqual(mac.department, "Engineering", "computers carries no department name")
    }

    // MARK: - Date labels

    private func record(lastContact: String, lastInventory: String = "") -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "SER1", source: "test")
        record.lastContact = lastContact
        record.lastInventory = lastInventory
        return record
    }

    func testMergeKeepsTheNewerDateLabelInEitherOrder() {
        let old = "1970-01-01 00:00:00"
        let new = "2026-10-15T08:00:00Z"
        var first = record(lastContact: old, lastInventory: new)
        first.merge(record(lastContact: new, lastInventory: old))
        XCTAssertEqual(first.lastContact, new)
        XCTAssertEqual(first.lastInventory, new)

        var second = record(lastContact: new)
        second.merge(record(lastContact: old))
        XCTAssertEqual(second.lastContact, new)
    }

    func testMergePrefersAReadableDateOverText() {
        var unreadableFirst = record(lastContact: "Never")
        unreadableFirst.merge(record(lastContact: "2026-10-15 08:00:00"))
        XCTAssertEqual(unreadableFirst.lastContact, "2026-10-15 08:00:00")

        var readableFirst = record(lastContact: "2026-10-15 08:00:00")
        readableFirst.merge(record(lastContact: "Never"))
        XCTAssertEqual(readableFirst.lastContact, "2026-10-15 08:00:00")
    }

    func testMergeKeepsTheFirstLabelWhenNeitherIsADate() {
        var text = record(lastContact: "Never")
        text.merge(record(lastContact: "Unknown"))
        XCTAssertEqual(text.lastContact, "Never")

        var blank = record(lastContact: "")
        blank.merge(record(lastContact: "Unknown"))
        XCTAssertEqual(blank.lastContact, "Unknown")
    }
}
