import Foundation
import XCTest
@testable import JamfReports

/// Verifies the per-device security state surfacing added in v2.1.0 PR 2.
///
/// The Excel sheet, the DevicesView per-control glyph row, and the detail-panel
/// "Security State" section all read the five fields populated here. These tests
/// cover the model layer; the view layer wraps these values in icons whose
/// tone follows the same compliant/noncompliant classification as
/// `DeviceInventoryRecord.securityGapCount`.
final class DeviceSecurityStateTests: XCTestCase {

    func testRecordFromComputerExtractsAllFiveSecurityControls() {
        let item: [String: Any] = [
            "general": ["id": 7, "name": "Lab-Mac-OK"],
            "hardware": ["serialNumber": "OK7"],
            "diskEncryption": [
                "fileVault2Enabled": true,
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "ENCRYPTED"],
            ],
            "security": [
                "sipStatus": "ENABLED",
                "firewallEnabled": true,
                "gatekeeperStatus": "APP_STORE_AND_IDENTIFIED_DEVELOPERS",
                "bootstrapTokenEscrowed": true,
            ],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertFalse(record.fileVault.isEmpty)
        XCTAssertEqual(record.sip, "ENABLED")
        XCTAssertEqual(record.firewall.lowercased(), "true")
        XCTAssertEqual(record.gatekeeper, "APP_STORE_AND_IDENTIFIED_DEVELOPERS")
        XCTAssertEqual(record.bootstrapToken.lowercased(), "true")
        XCTAssertEqual(record.securityGapCount, 0)
    }

    func testRecordFromComputerFlagsAllDisabledControls() {
        let item: [String: Any] = [
            "general": ["id": 8, "name": "Lab-Mac-Bad"],
            "hardware": ["serialNumber": "BAD8"],
            "diskEncryption": [
                "fileVault2Enabled": false,
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "UNENCRYPTED"],
            ],
            "security": [
                "sipStatus": "DISABLED",
                "firewallEnabled": false,
                "gatekeeperStatus": "DISABLED",
                "bootstrapTokenEscrowed": false,
            ],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertEqual(record.fileVault, "UNENCRYPTED")
        XCTAssertEqual(record.sip, "DISABLED")
        XCTAssertEqual(record.firewall.lowercased(), "false")
        XCTAssertEqual(record.gatekeeper, "DISABLED")
        XCTAssertEqual(record.bootstrapToken.lowercased(), "false")
        XCTAssertEqual(record.securityGapCount, 5)
    }

    func testRecordWithMissingSecuritySectionLeavesFieldsEmpty() {
        let item: [String: Any] = [
            "general": ["id": 9, "name": "Lab-Mac-NoSecurity"],
            "hardware": ["serialNumber": "NODATA9"],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertTrue(record.fileVault.isEmpty)
        XCTAssertTrue(record.sip.isEmpty)
        XCTAssertTrue(record.firewall.isEmpty)
        XCTAssertTrue(record.gatekeeper.isEmpty)
        XCTAssertTrue(record.bootstrapToken.isEmpty)
        XCTAssertEqual(record.securityGapCount, 0, "empty values are unknown, not failed")
    }
}
