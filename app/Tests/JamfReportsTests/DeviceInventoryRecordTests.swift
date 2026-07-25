import Foundation
import XCTest
@testable import JamfReports

final class DeviceInventoryRecordTests: XCTestCase {

    func testComputerListRecordKeepsStableIdentityAndCapturesJamfID() {
        let item: [String: Any] = [
            "general": [
                "id": 42,
                "name": "MERIDIAN-JS-MBP",
                "serialNumber": "C02XK9PHJG5J",
            ],
            "hardware": [
                "serialNumber": "C02XK9PHJG5J",
            ],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertEqual(record.id, "serial:c02xk9phjg5j")
        XCTAssertEqual(record.jamfID, "42")
        XCTAssertEqual(record.numericJamfID, "42")
    }

    func testPatchFailureRecordCapturesDeviceID() {
        let item: [String: Any] = [
            "device_id": "123",
            "device": "MERIDIAN-JS-MBP",
            "serial": "C02XK9PHJG5J",
            "policy": "Google Chrome",
            "last_action": "Retrying",
        ]

        let record = DeviceInventoryService.recordFromPatchFailure(item, source: "patch-failures.json")

        XCTAssertEqual(record.id, "serial:c02xk9phjg5j")
        XCTAssertEqual(record.jamfID, "123")
        XCTAssertEqual(record.numericJamfID, "123")
        XCTAssertEqual(record.patchFailures.first?.title, "Google Chrome")
    }

    func testMergeUsesFirstNonEmptyJamfID() {
        var existing = DeviceInventoryRecord.empty(id: "serial:c02xk9phjg5j", source: "computers-list.json")
        existing.jamfID = "42"

        var incoming = DeviceInventoryRecord.empty(id: "serial:c02xk9phjg5j", source: "patch-failures.json")
        incoming.jamfID = "123"

        existing.merge(incoming)

        XCTAssertEqual(existing.jamfID, "42")

        var missing = DeviceInventoryRecord.empty(id: "serial:c02xk9phjg5j", source: "csv.csv")
        missing.merge(incoming)

        XCTAssertEqual(missing.jamfID, "123")
    }

    func testSerialAndNameIDsAreNotJamfURLIDs() {
        var record = DeviceInventoryRecord.empty(id: "serial:c02xk9phjg5j", source: "csv.csv")
        record.jamfID = "serial:c02xk9phjg5j"

        XCTAssertNil(record.numericJamfID)

        let row = DeviceRow(
            name: "MERIDIAN-JS-MBP",
            serial: "C02XK9PHJG5J",
            jamfID: "C02XK9PHJG5J",
            os: "15.4",
            user: "j.silva@meridian.health",
            dept: "Engineering",
            lastSeen: "12 min ago",
            fileVault: true,
            fails: 0,
            model: "MacBook Pro 14\""
        )

        XCTAssertNil(row.numericJamfID)
    }

    func testIDOnlyRecordsAreDistinctAndPreferJamfPrefix() {
        let item1: [String: Any] = [
            "device_id": "101",
            "device": "",
            "serial": "",
        ]
        let item2: [String: Any] = [
            "device_id": "102",
            "device": "",
            "serial": "",
        ]

        let record1 = DeviceInventoryService.recordFromPatchFailure(item1, source: "p1.json")
        let record2 = DeviceInventoryService.recordFromPatchFailure(item2, source: "p2.json")

        XCTAssertEqual(record1.id, "jamf:101")
        XCTAssertEqual(record2.id, "jamf:102")
        XCTAssertNotEqual(record1.id, record2.id)
    }

    // MARK: - jamf-cli underscore enum classification (FileVault misclassification bug)

    private func goodDevice(id: String) -> DeviceInventoryRecord {
        var device = DeviceInventoryRecord.empty(id: id, source: "computers")
        device.fileVault = "ALL_ENCRYPTED"
        device.sip = "ENABLED"
        device.firewall = "ENABLED"
        device.gatekeeper = "ENABLED"
        device.bootstrapToken = "ESCROWED"
        return device
    }

    func testNotEncryptedUnderscoreEnumCountsAsSecurityGap() {
        let good = goodDevice(id: "serial:good")
        XCTAssertEqual(good.securityGapCount, 0)

        var bad = goodDevice(id: "serial:bad")
        bad.fileVault = "NOT_ENCRYPTED"
        XCTAssertEqual(bad.securityGapCount, 1)
    }

    func testNotEnabledUnderscoreEnumCountsAsSecurityGap() {
        var bad = goodDevice(id: "serial:bad")
        bad.sip = "NOT_ENABLED"
        XCTAssertEqual(bad.securityGapCount, 1)
    }

    func testAllEncryptedUnderscoreEnumIsNotFlaggedAsBad() {
        // Regression guard: a generic "not " substring check must not fire on
        // ALL_ENCRYPTED/ENCRYPTED/ENABLED — only on genuine "not X" values.
        let good = goodDevice(id: "serial:good")
        XCTAssertEqual(good.securityGapCount, 0)
    }

    func testFileVaultPercentReflectsRealFleetSplitNotAllOrNothing() {
        // Regression for the 101-device fleet (100 ALL_ENCRYPTED, 1 NOT_ENCRYPTED)
        // that previously rounded to a false 100%/0-gap reading.
        var devices: [DeviceInventoryRecord] = (0..<100).map { goodDevice(id: "serial:good\($0)") }
        var bad = goodDevice(id: "serial:bad")
        bad.fileVault = "NOT_ENCRYPTED"
        devices.append(bad)

        let snapshot = DeviceInventorySnapshot(
            devices: devices,
            patchTitles: [],
            sourceFiles: [],
            warnings: [],
            generatedAt: "",
            generatedDate: nil,
            isDemo: false
        )

        XCTAssertEqual(snapshot.fileVaultPercent, 100.0 * 100.0 / 101.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.securityGapCount, 1)
    }
}
