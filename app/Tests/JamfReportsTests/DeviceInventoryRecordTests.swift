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

    func testComputerRecordUsesAnAddressShapedUsernameAsTheEmail() {
        func record(_ userAndLocation: [String: Any]) -> DeviceInventoryRecord {
            DeviceInventoryService.recordFromComputer([
                "general": ["id": 7, "name": "MERIDIAN-AB-MBP"],
                "hardware": ["serialNumber": "C02ABCDEFGHI"],
                "userAndLocation": userAndLocation,
            ], source: "computers.json")
        }
        XCTAssertEqual(record(["username": "a.b@example.org"]).email, "a.b@example.org")
        XCTAssertEqual(record(["username": "ab", "email": ""]).email, "")
        XCTAssertEqual(record(["username": "a.b@example.org", "email": "real@example.org"]).email,
                       "real@example.org", "an explicit email always wins")
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
        XCTAssertEqual(good.securityGapCount(policy: .default), 0)

        var bad = goodDevice(id: "serial:bad")
        bad.fileVault = "NOT_ENCRYPTED"
        XCTAssertEqual(bad.securityGapCount(policy: .default), 1)
    }

    func testNotEnabledUnderscoreEnumCountsAsSecurityGap() {
        var bad = goodDevice(id: "serial:bad")
        bad.sip = "NOT_ENABLED"
        XCTAssertEqual(bad.securityGapCount(policy: .default), 1)
    }

    func testAllEncryptedUnderscoreEnumIsNotFlaggedAsBad() {
        // Regression guard: a generic "not " substring check must not fire on
        // ALL_ENCRYPTED/ENCRYPTED/ENABLED — only on genuine "not X" values.
        let good = goodDevice(id: "serial:good")
        XCTAssertEqual(good.securityGapCount(policy: .default), 0)
    }

    func testFileVaultPercentReflectsRealFleetSplitNotAllOrNothing() throws {
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

        XCTAssertEqual(try XCTUnwrap(snapshot.fileVaultPercent), 100.0 * 100.0 / 101.0,
                       accuracy: 0.01)
        XCTAssertEqual(snapshot.securityGapCount, 1)
    }

    // MARK: - Hardware encryption

    /// `hardware.appleSilicon` and `hardware.modelIdentifier` from the `computers` snapshot.
    func testComputerRecordReadsHardwareEncryption() {
        func record(_ hardware: [String: Any]) -> DeviceInventoryRecord {
            DeviceInventoryService.recordFromComputer(
                ["general": ["id": 5, "name": "Lab-Mac"], "hardware": hardware],
                source: "computers.json")
        }
        XCTAssertEqual(record(["serialNumber": "AS1", "appleSilicon": true,
                               "modelIdentifier": "Mac14,2"]).hardwareEncrypted, true)
        XCTAssertEqual(record(["serialNumber": "T21", "appleSilicon": false,
                               "modelIdentifier": "MacBookPro16,2"]).hardwareEncrypted, true)
        XCTAssertEqual(record(["serialNumber": "IN1", "appleSilicon": false,
                               "modelIdentifier": "MacBookPro14,1"]).hardwareEncrypted, false)
        XCTAssertNil(record(["serialNumber": "NONE1"]).hardwareEncrypted)
    }

    func testBuiltinCSVAppleSiliconRowsAreHardwareEncrypted() throws {
        let url = TestFixtures.dir("csv/jamf1128_computers_builtin.csv")
        let (_, rows) = try CSVParser.parse(Data(contentsOf: url))
        let records = rows.map {
            DeviceInventoryService.recordFromCSV($0, source: "jamf1128_computers_builtin.csv")
        }
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.map(\.hardwareEncrypted), [true, true, true, true])
    }

    /// `Apple Silicon` is Yes or No; the model and architecture decide when it is blank.
    func testCSVHardwareColumns() {
        func encrypted(_ row: [String: String]) -> Bool? {
            DeviceInventoryService.recordFromCSV(
                row.merging(["Computer Name": "Lab-Mac", "Serial Number": "S1"]) { a, _ in a },
                source: "computers.csv"
            ).hardwareEncrypted
        }
        XCTAssertEqual(encrypted(["Apple Silicon": "true"]), true)
        XCTAssertEqual(encrypted(["Apple Silicon": "No", "Model Identifier": "MacBookPro16,2"]),
                       true)
        XCTAssertEqual(encrypted(["Apple Silicon": "No", "Model Identifier": "MacBookPro14,1"]),
                       false)
        XCTAssertEqual(encrypted(["Apple Silicon": "FALSE", "Model Identifier": "iMac19,1"]), false)
        XCTAssertNil(encrypted(["Apple Silicon": "No"]), "an Intel Mac could still have a T2")
        XCTAssertEqual(encrypted(["Apple Silicon": "", "Architecture Type": "arm64"]), true)
        // The app's default `columns.architecture` header.
        XCTAssertEqual(encrypted(["Architecture": "x86_64", "Model Identifier": "MacBookPro14,1"]),
                       false)
        XCTAssertNil(encrypted(["Apple Silicon": "Unknown"]))
        XCTAssertNil(encrypted([:]))
    }

    /// One source with an answer gives it; two that agree keep it; two that disagree are
    /// unknown, so FileVault off stays at the FileVault level rather than the first guess.
    func testMergeTreatsDisagreeingHardwareAnswersAsUnknown() {
        let cases: [(Bool?, Bool?, Bool?)] = [
            (nil, true, true), (true, nil, true), (nil, false, false), (false, nil, false),
            (true, true, true), (false, false, false),
            (true, false, nil), (false, true, nil),
            (nil, nil, nil),
        ]
        for (first, second, merged) in cases {
            var csv = DeviceInventoryRecord.empty(id: "serial:s1", source: "csv.csv")
            csv.hardwareEncrypted = first
            var computers = DeviceInventoryRecord.empty(id: "serial:s1", source: "computers.json")
            computers.hardwareEncrypted = second
            csv.merge(computers)
            XCTAssertEqual(csv.hardwareEncrypted, merged,
                           "\(String(describing: first)) + \(String(describing: second))")
        }
    }
}
