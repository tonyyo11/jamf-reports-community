import XCTest
@testable import JamfReports

/// The Health Audit's contact-gap findings, the Devices records and screen helpers that carry
/// the three Jamf Pro dates, and the device-compliance row's side of the stale rule.
final class ContactGapFindingsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func record(
        _ name: String, checkIn: Double?, inventory: Double?, contact: Double?
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: name, source: "computers.json")
        record.name = name
        record.serial = "SER-\(name)"
        record.checkInDate = checkIn.map(ago)
        record.inventoryDate = inventory.map(ago)
        record.contactDate = contact.map(ago)
        record.carriesDates = true
        return record
    }

    private func snapshot(_ devices: [DeviceInventoryRecord], gapDays: Int = 14)
        -> DeviceInventorySnapshot {
        var snapshot = DeviceInventorySnapshot.empty
        snapshot.devices = devices
        snapshot.contactGapDays = gapDays
        return snapshot
    }

    // MARK: - Audit findings

    func testTwoFindingsCarryTheirCountsDevicesAndRecommendations() throws {
        let findings = contactGapFindings(snapshot([
            record("Zed", checkIn: 40, inventory: 1, contact: 1),
            record("Amy", checkIn: 50, inventory: 1, contact: 2),
            record("Lag", checkIn: 1, inventory: 40, contact: 1),
            record("Fine", checkIn: 1, inventory: 1, contact: 1),
        ]), now: now)

        XCTAssertEqual(findings.map(\.name), [
            "Jamf binary not checking in while MDM reaches the Mac",
            "Inventory not updating while the Mac checks in",
        ])
        let silent = findings[0], inventory = findings[1]
        XCTAssertEqual(silent.severity, "WARNING")
        XCTAssertEqual(silent.affected, 2)
        XCTAssertEqual(silent.devices, ["Amy (SER-Amy)", "Zed (SER-Zed)"], "sorted by name")
        XCTAssertEqual(silent.category, "Contact gap")
        XCTAssertTrue(silent.recommendation.contains("sudo jamf policy"))
        XCTAssertEqual(inventory.severity, "INFO")
        XCTAssertEqual(inventory.affected, 1)
        XCTAssertEqual(inventory.devices, ["Lag (SER-Lag)"])
        XCTAssertTrue(inventory.recommendation.contains("sudo jamf recon"))
        XCTAssertTrue(inventory.recommendation.contains("14 days"))
    }

    func testFindingsAreOKWhenNoMacShowsAGapButSomeMacCarriesALastContact() {
        let findings = contactGapFindings(snapshot([
            record("Fine", checkIn: 1, inventory: 1, contact: 1),
        ]), now: now)
        XCTAssertEqual(findings.map(\.severity), ["OK", "OK"])
        XCTAssertEqual(findings.map(\.affected), [0, 0])
        XCTAssertTrue(findings.allSatisfy { $0.devices.isEmpty })
    }

    func testNoFindingsWhenNoMacCarriesALastContact() {
        XCTAssertTrue(contactGapFindings(snapshot([
            record("Old", checkIn: 40, inventory: 40, contact: nil),
        ]), now: now).isEmpty, "Jamf Pro before 11.30 records none: nothing to say")
        XCTAssertTrue(contactGapFindings(.empty, now: now).isEmpty)
    }

    func testTheGapDaysAndTheStaleWindowComeFromTheSnapshot() {
        var devices = snapshot([record("Lag", checkIn: 30, inventory: 1, contact: 1)], gapDays: 40)
        XCTAssertEqual(contactGapFindings(devices, now: now).map(\.affected), [0, 0],
                       "a 29-day lag is within a 40-day gap")
        devices.contactGapDays = 14
        XCTAssertEqual(contactGapFindings(devices, now: now).map(\.affected), [1, 0])
        devices.staleDays = 0
        XCTAssertEqual(contactGapFindings(devices, now: now).map(\.affected), [0, 0],
                       "a contact 1 day old is not current when nothing under 0 days is")
    }

    func testTheDeviceListStaysOutOfTheAuditSnapshotAndOpensTheDevicesScreen() throws {
        let finding = AuditFinding(
            name: "x", affected: 1, category: "Contact gap", recommendation: "r",
            severity: "WARNING", devices: ["Mac (SER)"])
        let data = try JSONEncoder().encode(finding)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["devices"], "pro audit's findings carry counts only")
        XCTAssertEqual(try JSONDecoder().decode(AuditFinding.self, from: data).devices, [])
        XCTAssertEqual(auditActionDestination(for: finding)?.tab, .devices)
        let named = contactGapFindings(snapshot([
            record("Lag", checkIn: 40, inventory: 1, contact: 1),
        ]), now: now)
        XCTAssertTrue(named.allSatisfy { auditActionDestination(for: $0)?.tab == .devices })
    }

    // MARK: - Records from each source

    func testAComputersRecordCarriesTheThreeDatesAndMarksItselfDated() throws {
        func stamp(_ days: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400))
        }
        let record = DeviceInventoryService.recordFromComputer([
            "id": "7", "general": [
                "name": "M", "lastCheckIn": stamp(3), "reportDate": stamp(9),
                "lastContact": stamp(1),
            ], "hardware": ["serialNumber": "S7"],
        ], source: "computers.json")
        XCTAssertNotNil(record.checkInDate)
        XCTAssertNotNil(record.inventoryDate)
        XCTAssertNotNil(record.contactDate)
        XCTAssertTrue(record.carriesDates)
        XCTAssertEqual(record.daysSinceContact, 3)
        XCTAssertEqual(record.lastContact, stamp(3), "the check-in's text is unchanged")
        XCTAssertEqual(DevicesView.contactText(record),
                       ISO8601DateFormatter().string(from: try XCTUnwrap(record.contactDate)))
    }

    func testAComputersRecordWithoutALastContactHasNone() {
        let record = DeviceInventoryService.recordFromComputer([
            "general": [
                "name": "M", "lastCheckIn": "2026-01-01T00:00:00Z", "lastContact": NSNull(),
            ],
        ], source: "computers.json")
        XCTAssertNil(record.contactDate)
        XCTAssertEqual(DevicesView.contactText(record), "")
    }

    func testComplianceAndCSVRecordsCarryTheDatesTheySupplyAndNotMarkedDated() {
        let compliance = DeviceInventoryService.recordFromCompliance([
            "name": "C", "serial": "S", "days_since_contact": "5",
            "last_contact": "2026-01-01T00:00:00.000Z",
        ], source: "device-compliance.json")
        XCTAssertNotNil(compliance.checkInDate)
        XCTAssertNil(compliance.inventoryDate)
        XCTAssertFalse(compliance.carriesDates)

        let csv = DeviceInventoryService.recordFromCSV([
            "Computer Name": "V", "Serial Number": "S", "Last Check-in": "2026-01-02 10:00:00",
            "Last Inventory Update": "2026-01-01 10:00:00",
        ], source: "inventory.csv")
        XCTAssertNotNil(csv.checkInDate)
        XCTAssertNotNil(csv.inventoryDate)
        XCTAssertFalse(csv.carriesDates)
    }

    // MARK: - The stale rule on merged records

    func testARestatedRecordFollowsTheRule() {
        var merged = record("M", checkIn: 2, inventory: 60, contact: 1)
        merged.daysSinceContact = 2
        merged.stale = false
        let plain = DeviceInventoryService.restatingStale(
            merged, rule: StaleRule(days: 30), now: now)
        XCTAssertFalse(plain.stale)
        let widened = DeviceInventoryService.restatingStale(
            merged, rule: StaleRule(days: 30, basis: [.checkIn, .inventory]), now: now)
        XCTAssertTrue(widened.stale, "inventory 60 days old")
        XCTAssertTrue(merged.isStale(StaleRule(days: 30, basis: [.inventory]), now: now))
        let both = StaleRule(days: 30, basis: [.checkIn, .inventory])
        XCTAssertEqual(merged.staleAge(both, now: now), .days(60))
    }

    func testTheSnapshotCountsStaleMacsUnderItsBasis() {
        var devices = snapshot([
            record("A", checkIn: 2, inventory: 60, contact: 1),
            record("B", checkIn: 2, inventory: 2, contact: 1),
        ])
        XCTAssertEqual(devices.staleCount(StaleRule(days: 30), now: now), 0)
        devices.staleBasis = [.checkIn, .inventory]
        XCTAssertEqual(
            devices.staleCount(StaleRule(days: 30, basis: devices.staleBasis), now: now), 1)
        XCTAssertEqual(devices.staleCount(thresholdDays: 30), 1, "the snapshot's own basis")
    }

    // MARK: - Device-compliance rows

    private func row(_ json: String) throws -> DeviceComplianceRow {
        try JSONDecoder().decode(DeviceComplianceRow.self, from: Data(json.utf8))
    }

    func testARowReadsItsJamfIDAndCheckInDateWithoutFailingOnOddTypes() throws {
        let full = try row("""
        {"name":"M","serial":"S","id":"42","days_since_contact":"3",
         "last_contact":"2026-01-01T00:00:00Z"}
        """)
        XCTAssertEqual(full.jamfID, "42")
        XCTAssertEqual(full.lastContact, "2026-01-01T00:00:00Z")
        XCTAssertEqual(try row(#"{"jamf_id":7,"last_checkin":"2026-02-02"}"#).jamfID, "7")
        let odd = try row(#"{"id":{"a":1},"last_contact":[1],"serial":"S"}"#)
        XCTAssertNil(odd.jamfID)
        XCTAssertNil(odd.lastContact)
        XCTAssertNil(try row(#"{"serial":"S"}"#).jamfID, "current jamf-cli rows carry none")
    }

    func testTheDefaultRuleOnARowIsTodaysRuleAndNeverReadsTheSnapshot() throws {
        let computers = ComputerDateIndex([
            ComputerDates(serial: "S", checkIn: ago(1), inventory: ago(400), contact: nil),
        ])
        let aged = try row(#"{"serial":"S","days_since_contact":"31"}"#)
        XCTAssertTrue(aged.isStale(atDays: 30))
        XCTAssertFalse(try row(#"{"serial":"S","days_since_contact":"30"}"#).isStale(atDays: 30))
        XCTAssertTrue(try row(#"{"serial":"S","stale":true}"#).isStale(atDays: 30), "the flag")
        let fresh = try row(#"{"serial":"S","days_since_contact":"3"}"#)
        XCTAssertFalse(fresh.isStale(StaleRule(days: 30), computers: computers, now: now),
                       "the inventory date is read only when the rule counts it")
        XCTAssertTrue(fresh.isStale(StaleRule(days: 30, basis: [.checkIn, .inventory]),
                                    computers: computers, now: now))
        XCTAssertEqual(fresh.staleAge(StaleRule(days: 30, basis: [.checkIn, .inventory]),
                                      computers: computers, now: now), .days(400))
    }
}
