import Foundation
import XCTest
@testable import JamfReports

/// Two inventory rows are one Mac only when a stable identifier says so; a computer name
/// alone never does. Fixtures are hand-built and synthetic.
final class DeviceRecordMergerIdentityTests: XCTestCase {

    // MARK: Fixtures

    private func computer(
        _ id: Int, _ name: String, serial: String, udid: String? = nil, mgmt: String? = nil
    ) -> DeviceInventoryRecord {
        var general: [String: Any] = ["name": name]
        if let mgmt { general["managementId"] = mgmt }
        var item: [String: Any] = [
            "id": String(id), "general": general, "hardware": ["serialNumber": serial],
        ]
        if let udid { item["udid"] = udid }
        return DeviceInventoryService.recordFromComputer(item, source: "computers.json")
    }

    /// A device-compliance row: a name, a serial when given, and a check-in age.
    private func compliance(
        _ name: String, serial: String? = nil, days: Int = 3, os: String = "26.4"
    ) -> DeviceInventoryRecord {
        var item: [String: Any] = [
            "name": name, "days_since_contact": String(days), "os_version": os,
        ]
        if let serial { item["serial"] = serial }
        return DeviceInventoryService.recordFromCompliance(item, source: "device-compliance.json")
    }

    private func csv(_ cells: [String: String]) -> DeviceInventoryRecord {
        DeviceInventoryService.recordFromCSV(cells, source: "inventory.csv")
    }

    private func merged(_ records: DeviceInventoryRecord...) -> DeviceRecordMerger {
        var merger = DeviceRecordMerger()
        records.forEach { merger.upsert($0) }
        return merger
    }

    private func record(named name: String, in merger: DeviceRecordMerger, serial: String)
        -> DeviceInventoryRecord? {
        merger.records.first { $0.serial == serial && $0.name == name }
    }

    // MARK: Same name, different Macs

    func testTwoMacsSharingANameStayTwo() {
        let merger = merged(
            computer(1, "FIXTURE-MBP", serial: "FXTR0001AA", udid: "00008101-FIXTURE00000001"),
            computer(2, "FIXTURE-MBP", serial: "FXTR0002BB", udid: "00008101-FIXTURE00000002"))

        XCTAssertEqual(merger.records.count, 2)
        XCTAssertEqual(Set(merger.records.map(\.serial)), ["FXTR0001AA", "FXTR0002BB"])
        XCTAssertEqual(Set(merger.records.map(\.id)).count, 2)
    }

    func testComplianceRowsFollowTheirSerialNotTheirSharedName() {
        let merger = merged(
            computer(1, "FIXTURE-MBP", serial: "FXTR0001AA"),
            computer(2, "FIXTURE-MBP", serial: "FXTR0002BB"),
            compliance("FIXTURE-MBP", serial: "FXTR0002BB", days: 40),
            compliance("FIXTURE-MBP", serial: "FXTR0001AA", days: 1))

        XCTAssertEqual(merger.records.count, 2)
        XCTAssertEqual(record(named: "FIXTURE-MBP", in: merger, serial: "FXTR0001AA")?
            .daysSinceContact, 1)
        XCTAssertEqual(record(named: "FIXTURE-MBP", in: merger, serial: "FXTR0002BB")?
            .daysSinceContact, 40)
    }

    // MARK: Serial and Jamf ID

    func testSameSerialAndSameJamfIDMerge() {
        let merger = merged(
            computer(7, "FIXTURE-A", serial: "FXTR0007GG"),
            csv(["Computer Name": "FIXTURE-A", "Serial Number": "fxtr0007gg", "Jamf ID": "7",
                 "Department": "Fixture Dept"]))

        XCTAssertEqual(merger.records.count, 1)
        XCTAssertEqual(merger.records.first?.department, "Fixture Dept")
        XCTAssertEqual(merger.records.first?.source, "computers.json + inventory.csv")
    }

    func testSameSerialWithDifferentJamfIDsStayTwo() {
        // One serial on two Jamf records, as after a logic-board swap.
        let merger = merged(
            computer(5, "FIXTURE-OLD", serial: "FXTR0005EE"),
            computer(9, "FIXTURE-NEW", serial: "FXTR0005EE"))

        XCTAssertEqual(merger.records.count, 2)
        XCTAssertEqual(Set(merger.records.compactMap(\.jamfID)), ["5", "9"])
        XCTAssertEqual(Set(merger.records.map(\.id)).count, 2,
                       "rows need distinct ids even when they share a serial")
    }

    func testSameJamfIDWithDifferentSerialsStaysTwo() {
        let merger = merged(
            computer(5, "FIXTURE-A", serial: "FXTR0005EE"),
            csv(["Computer Name": "FIXTURE-A", "Serial Number": "FXTR0006FF", "Jamf ID": "5"]))

        XCTAssertEqual(merger.records.count, 2)
    }

    func testSerialOnlyRowMergesIntoTheRecordWithThatSerial() {
        let merger = merged(
            computer(3, "FIXTURE-C", serial: "FXTR0003CC"),
            csv(["Serial Number": "FXTR0003CC", "Department": "Fixture Dept"]))

        XCTAssertEqual(merger.records.count, 1)
        XCTAssertEqual(merger.records.first?.department, "Fixture Dept")
        XCTAssertEqual(merger.records.first?.jamfID, "3")
    }

    func testSerialOnlyRowOnTwoSameSerialRecordsIsChosenByNameOrLeftOut() {
        var merger = merged(
            computer(5, "FIXTURE-OLD", serial: "FXTR0005EE"),
            computer(9, "FIXTURE-NEW", serial: "FXTR0005EE"))

        merger.upsert(compliance("FIXTURE-NEW", serial: "FXTR0005EE", days: 12))
        XCTAssertEqual(merger.records.count, 2)
        XCTAssertEqual(merger.records.first { $0.jamfID == "9" }?.daysSinceContact, 12)
        XCTAssertNil(merger.records.first { $0.jamfID == "5" }?.daysSinceContact)

        merger.upsert(compliance("FIXTURE-OTHER", serial: "FXTR0005EE", days: 99))
        XCTAssertEqual(merger.records.count, 2, "a row that fits both is not a third Mac")
        XCTAssertEqual(merger.leftOutRows["device-compliance.json"], 1)
        XCTAssertEqual(merger.records.first { $0.jamfID == "9" }?.daysSinceContact, 12)
        XCTAssertNil(merger.records.first { $0.jamfID == "5" }?.daysSinceContact)
    }

    // MARK: UDID, management ID, Platform ID

    func testUDIDMatchesAcrossSourcesWithoutASerialOrName() {
        let merger = merged(
            computer(1, "FIXTURE-A", serial: "FXTR0001AA", udid: "00008101-FIXTURE00000001"),
            csv(["UDID": "00008101-fixture00000001", "Department": "Fixture Dept"]))

        XCTAssertEqual(merger.records.count, 1)
        XCTAssertEqual(merger.records.first?.department, "Fixture Dept")
    }

    func testManagementIDMatchesAcrossSources() {
        let mgmt = "4f1d7c52-0000-4000-8000-00000000f001"
        let merger = merged(
            computer(1, "FIXTURE-A", serial: "FXTR0001AA", mgmt: mgmt),
            csv(["Management ID": mgmt.uppercased(), "Department": "Fixture Dept"]))

        XCTAssertEqual(merger.records.count, 1)
        XCTAssertEqual(merger.records.first?.department, "Fixture Dept")
    }

    func testDifferingUDIDsKeepTwoMacsThatShareASerial() {
        let merger = merged(
            computer(1, "FIXTURE-A", serial: "FXTR0001AA", udid: "00008101-FIXTURE00000001"),
            csv(["Serial Number": "FXTR0001AA", "UDID": "00008101-FIXTURE00000002"]))

        XCTAssertEqual(merger.records.count, 2)
    }

    func testPlatformIDMatchesAndDisagreementSeparates() {
        var first = DeviceInventoryRecord.empty(id: "device:unknown", source: "a.json")
        first.platformID = "FIXTURE-PLATFORM-0001"
        var same = DeviceInventoryRecord.empty(id: "device:unknown", source: "b.json")
        same.platformID = "fixture-platform-0001"
        same.department = "Fixture Dept"
        var other = DeviceInventoryRecord.empty(id: "device:unknown", source: "b.json")
        other.platformID = "FIXTURE-PLATFORM-0002"

        let merger = merged(first, same, other)

        XCTAssertEqual(merger.records.count, 2)
        XCTAssertEqual(merger.records.first?.department, "Fixture Dept")
    }

    // MARK: Rows with a name only

    func testNameOnlyRowJoinsTheOneRecordWithThatName() {
        let merger = merged(
            computer(1, "FIXTURE-A", serial: "FXTR0001AA"),
            computer(2, "FIXTURE-B", serial: "FXTR0002BB"),
            compliance("fixture-a", os: "26.4"))

        XCTAssertEqual(merger.records.count, 2)
        XCTAssertEqual(record(named: "FIXTURE-A", in: merger, serial: "FXTR0001AA")?.osVersion,
                       "26.4")
        XCTAssertEqual(record(named: "FIXTURE-B", in: merger, serial: "FXTR0002BB")?.osVersion,
                       "")
    }

    func testNameOnlyRowWithAnAmbiguousNameJoinsNeitherRecord() {
        let merger = merged(
            computer(1, "FIXTURE-MBP", serial: "FXTR0001AA"),
            computer(2, "FIXTURE-MBP", serial: "FXTR0002BB"),
            compliance("FIXTURE-MBP", os: "26.4"))

        XCTAssertEqual(merger.records.count, 2, "no third Mac is invented")
        XCTAssertEqual(merger.records.map(\.osVersion), ["", ""])
        XCTAssertEqual(merger.leftOutRows["device-compliance.json"], 1)
    }

    func testNameOnlyRowWithNoMatchingNameIsItsOwnMac() {
        let merger = merged(
            computer(1, "FIXTURE-A", serial: "FXTR0001AA"),
            compliance("FIXTURE-Z"))

        XCTAssertEqual(merger.records.count, 2)
        XCTAssertTrue(merger.leftOutRows.isEmpty)
    }

    func testRowWithIdentifiersTakesOverALoneNameOnlyRecord() {
        let merger = merged(
            compliance("FIXTURE-A", os: "26.4"),
            computer(1, "FIXTURE-A", serial: "FXTR0001AA"))

        XCTAssertEqual(merger.records.count, 1)
        XCTAssertEqual(merger.records.first?.serial, "FXTR0001AA")
        XCTAssertEqual(merger.records.first?.osVersion, "26.4")
    }

    func testRowWithIdentifiersDoesNotTakeOverAnIdentifiedRecordByName() {
        let merger = merged(
            computer(1, "FIXTURE-MBP", serial: "FXTR0001AA"),
            csv(["Computer Name": "FIXTURE-MBP", "Serial Number": "FXTR0002BB"]))

        XCTAssertEqual(merger.records.count, 2)
    }

    // MARK: Through the loader

    func testLoaderKeepsTwoSameNameMacsAndTheirOwnComplianceRows() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-identity-\(UUID().uuidString)", isDirectory: true)
        let profile = "identity"
        let data = root.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        func row(_ id: String, serial: String) -> [String: Any] {
            [
                "id": id, "udid": "00008101-FIXTURE0000000\(id)",
                "general": ["name": "FIXTURE-MBP", "managementId": mgmt(id)],
                "hardware": ["serialNumber": serial],
            ]
        }
        try writeJSON(
            [row("1", serial: "FXTR0001AA"), row("2", serial: "FXTR0002BB")],
            to: data.appendingPathComponent("computers/computers_20261005T110504.json"))
        try writeJSON(
            [["name": "FIXTURE-MBP", "serial": "FXTR0002BB", "days_since_contact": "40"],
             ["name": "FIXTURE-MBP", "serial": "FXTR0001AA", "days_since_contact": "1"],
             ["name": "FIXTURE-MBP", "days_since_contact": "9"]],
            to: data.appendingPathComponent(
                "device-compliance/device-compliance_20261005T110417.json"))
        try writeJSON(
            [["device": "FIXTURE-MBP", "device_id": "2", "serial": "FXTR0002BB",
              "policy": "Fixture App", "last_action": "Retrying"]],
            to: data.appendingPathComponent(
                "patch-device-failures/patch-device-failures_20261005T110344.json"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)

        XCTAssertEqual(snapshot.devices.count, 2)
        let first = try XCTUnwrap(snapshot.devices.first { $0.jamfID == "1" })
        let second = try XCTUnwrap(snapshot.devices.first { $0.jamfID == "2" })
        XCTAssertEqual(first.daysSinceContact, 1)
        XCTAssertEqual(second.daysSinceContact, 40)
        XCTAssertEqual(first.patchFailureCount, 0)
        XCTAssertEqual(second.patchFailureCount, 1)
        XCTAssertEqual(first.udid, "00008101-FIXTURE00000001")
        XCTAssertEqual(second.managementID, mgmt("2"))
        // The compliance row with no serial fits both Macs by name, so it is reported (as a
        // count, never a name) instead of becoming a third Mac or a guess.
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].hasPrefix(
            "device-compliance_20261005T110417.json: left out 1 row that could not be matched"))
        XCTAssertFalse(snapshot.warnings[0].contains("FIXTURE"))
    }

    // MARK: Sources carry the identifiers

    func testComputerRowReadsUDIDAndManagementIDButNotTheProvisioningUDID() {
        let record = DeviceInventoryService.recordFromComputer([
            "id": "4", "udid": "00008101-FIXTURE00000004",
            "general": ["name": "FIXTURE-D", "managementId": mgmt("4")],
            "hardware": ["serialNumber": "FXTR0004DD",
                         "provisioningUdid": "00008101-PROVISION0000004"],
        ], source: "computers.json")

        XCTAssertEqual(record.udid, "00008101-FIXTURE00000004")
        XCTAssertEqual(record.managementID, mgmt("4"))
        XCTAssertEqual(record.jamfID, "4")
        XCTAssertNil(record.platformID)
    }

    func testCSVRowReadsJSSComputerIDUDIDAndManagementID() {
        let record = csv([
            "Computer Name": "FIXTURE-E", "JSS Computer ID": "8", "UDID": "FIXTURE-UDID-8",
            "Management ID": mgmt("8"),
        ])

        XCTAssertEqual(record.numericJamfID, "8")
        XCTAssertEqual(record.udid, "FIXTURE-UDID-8")
        XCTAssertEqual(record.managementID, mgmt("8"))
        XCTAssertNil(csv(["Computer Name": "FIXTURE-F"]).udid)
    }

    func testMergeFillsAnIdentifierTheRecordLacked() {
        var merger = merged(csv(["Serial Number": "FXTR0001AA"]))
        merger.upsert(computer(1, "FIXTURE-A", serial: "FXTR0001AA", udid: "FIXTURE-UDID-1"))
        // The UDID now identifies the merged record, so a UDID-only row finds it.
        merger.upsert(csv(["UDID": "FIXTURE-UDID-1", "Department": "Fixture Dept"]))

        XCTAssertEqual(merger.records.count, 1)
        XCTAssertEqual(merger.records.first?.department, "Fixture Dept")
    }

    // MARK: Helpers

    private func mgmt(_ id: String) -> String { "4f1d7c52-0000-4000-8000-00000000000\(id)" }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
