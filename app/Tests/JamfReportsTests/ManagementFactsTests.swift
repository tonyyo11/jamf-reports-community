import Foundation
import XCTest
@testable import JamfReports

/// Rows are parsed from JSON text so a boolean and a number arrive as they do from disk.
/// Every identifier is a placeholder. `appleEnrollmentType` is the value Jamf Pro 11.34 reports
/// after a Mac's inventory update (seen on a cloud and an on-prem server, 2026-11-27).
enum ManagementFixture {
    static func row(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { preconditionFailure("fixture is not a JSON object") }
        return row
    }

    static let full = """
    {"general": {"name": "mac-placeholder", "jamfBinaryVersion": "11.33.3-t1700000000000",
      "mdmProfileExpiration": "2028-11-11T10:42:56Z", "userApprovedMdm": true,
      "mdmCapable": {"capable": true, "capableUsers": []}, "supervised": true,
      "enrolledViaAutomatedDeviceEnrollment": false, "appleEnrollmentType": "supervised",
      "lastCloudBackupDate": "2026-11-01T00:00:00Z", "awaitingConfiguration": false},
     "security": {"attestationStatus": "PENDING", "lastSuccessfulAttestation": null,
      "recoveryLockEnabled": false, "activationLockEnabled": true,
      "externalBootLevel": "ALLOW_BOOTING_FROM_EXTERNAL_MEDIA", "autoLoginDisabled": false,
      "remoteDesktopEnabled": true, "lockdownModeEnabled": null},
     "hardware": {"batteryHealth": "UNSUPPORTED", "batteryCapacityPercent": -1}}
    """
}

final class ManagementFactsTests: XCTestCase {
    func testReadsEveryField() {
        let facts = ManagementFacts(item: ManagementFixture.row(ManagementFixture.full))
        XCTAssertEqual(facts.binaryVersion, BinaryVersion("11.33"))
        XCTAssertEqual(facts.jamfBinaryVersion, "11.33.3-t1700000000000")
        XCTAssertNotNil(facts.mdmProfileExpiration)
        XCTAssertEqual(facts.userApprovedMDM, true)
        XCTAssertEqual(facts.mdmCapable, true)
        XCTAssertEqual(facts.enrolledViaADE, false)
        XCTAssertEqual(facts.appleEnrollmentType, "supervised")
        XCTAssertEqual(facts.attestationStatus, "PENDING")
        XCTAssertEqual(facts.activationLockEnabled, true)
        XCTAssertEqual(facts.externalBootLevel, "ALLOW_BOOTING_FROM_EXTERNAL_MEDIA")
        XCTAssertEqual(facts.batteryHealth, "UNSUPPORTED")
    }

    func testNullAbsentAndWrongTypeAreNotReported() {
        let facts = ManagementFacts(item: ManagementFixture.row("""
        {"general": {"supervised": "yes", "userApprovedMdm": 1, "mdmCapable": {"capable": null},
          "mdmProfileExpiration": 5, "jamfBinaryVersion": "unknown"},
         "security": {"attestationStatus": "", "lockdownModeEnabled": null},
         "hardware": {"batteryHealth": 3, "batteryCapacityPercent": -1}}
        """))
        XCTAssertNil(facts.supervised)
        XCTAssertNil(facts.userApprovedMDM)
        XCTAssertNil(facts.mdmCapable)
        XCTAssertNil(facts.mdmProfileExpiration)
        XCTAssertEqual(facts.jamfBinaryVersion, "unknown")
        XCTAssertNil(facts.binaryVersion)
        XCTAssertNil(facts.attestationStatus)
        XCTAssertNil(facts.lockdownModeEnabled)
        XCTAssertNil(facts.recoveryLockEnabled)
        XCTAssertNil(facts.batteryHealth)
        XCTAssertNil(facts.batteryCapacityPercent)
    }

    func testRecordFromComputerCarriesFacts() {
        let record = DeviceInventoryService.recordFromComputer(
            ManagementFixture.row(ManagementFixture.full), source: "test")
        XCTAssertEqual(record.management?.supervised, true)
    }

    func testMergeWithDifferingFactsIsNil() {
        var first = DeviceInventoryRecord.empty(id: "a", source: "x")
        var second = DeviceInventoryRecord.empty(id: "a", source: "y")
        first.management = ManagementFacts(item: ["general": ["supervised": true]])
        second.management = ManagementFacts(item: ["general": ["supervised": false]])
        var merged = first
        merged.merge(second)
        XCTAssertNil(merged.management)

        var oneSided = DeviceInventoryRecord.empty(id: "a", source: "x")
        oneSided.merge(first)
        XCTAssertEqual(oneSided.management, first.management)
        var same = first
        same.merge(first)
        XCTAssertEqual(same.management, first.management)
    }
}
