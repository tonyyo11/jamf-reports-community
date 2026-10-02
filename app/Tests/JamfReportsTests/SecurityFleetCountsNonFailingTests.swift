import XCTest
@testable import JamfReports

/// `SecurityFleetCounts.nonFailingPct`: the share the workbook's Compliance Posture rows
/// and the HTML report's tiles grade a control by.
final class SecurityFleetCountsNonFailingTests: XCTestCase {

    private func fleet(
        total: Int = 10, onCounts: [SecurityControl: Int], policy: SecurityControlPolicy = .default
    ) -> SecurityFleetCounts {
        SecurityFleetCounts.build(
            totalDevices: total, onCounts: onCounts, devices: [], hardware: [:], policy: policy)
    }

    func testDefaultPolicyIsTheShareOfMacsWithTheControlOn() throws {
        let counts = fleet(onCounts: [.fileVault: 10, .sip: 8, .gatekeeper: 0])
        XCTAssertEqual(try XCTUnwrap(counts.nonFailingPct(.fileVault)), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(counts.nonFailingPct(.sip)), 80, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(counts.nonFailingPct(.gatekeeper)), 0, accuracy: 0.001)
    }

    func testNilWhenTheSummaryHasNoCountForTheControl() {
        XCTAssertNil(fleet(onCounts: [.sip: 8]).nonFailingPct(.firewall))
    }

    func testNilForAnIgnoredControl() {
        let counts = fleet(
            onCounts: [.sip: 8, .firewall: 8], policy: SecurityControlPolicy(firewall: .ignore))
        XCTAssertNil(counts.nonFailingPct(.firewall))
        XCTAssertNotNil(counts.nonFailingPct(.sip))
    }

    func testNilWithoutAnyMacs() {
        XCTAssertNil(fleet(total: 0, onCounts: [.sip: 0]).nonFailingPct(.sip))
    }

    /// A warning is not a failure, so the Macs that only warn count as not failing.
    func testAWarningIsNotAFailure() throws {
        let counts = fleet(onCounts: [.sip: 8], policy: SecurityControlPolicy(sip: .warning))
        XCTAssertEqual(try XCTUnwrap(counts.nonFailingPct(.sip)), 100, accuracy: 0.001)
    }

    func testACountAboveTheTotalIsNotMoreThanAllMacs() throws {
        let counts = fleet(onCounts: [.fileVault: 12])
        XCTAssertEqual(try XCTUnwrap(counts.nonFailingPct(.fileVault)), 100, accuracy: 0.001)
    }

    /// Four Macs, FileVault on for one; the other three are Apple silicon, a T2 Mac and an
    /// Intel Mac without T2.
    private func hardwareFleet(_ policy: SecurityControlPolicy) throws -> SecurityFleetCounts {
        func device(_ serial: String, _ fileVault: String) -> [String: Any] {
            ["section": "device", "name": serial.lowercased(), "serial": serial,
             "os_version": "15.4.1", "filevault": fileVault, "sip": "ENABLED", "firewall": true,
             "gatekeeper": "APP_STORE"]
        }
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 4, "filevault_encrypted": 1, "sip_enabled": 4,
            "firewall_enabled": 4, "gatekeeper_enabled": 4,
        ]]
        let json = try JSONSerialization.data(withJSONObject: [
            summary, device("ON1", "ENCRYPTED"), device("AS1", "UNENCRYPTED"),
            device("T21", "UNENCRYPTED"), device("IN1", "UNENCRYPTED"),
        ])
        let computers: [[String: Any]] = [
            ["general": ["name": "as1"], "hardware": ["serialNumber": "AS1", "appleSilicon": true]],
            ["general": ["name": "t21"],
             "hardware": ["serialNumber": "T21", "modelIdentifier": "MacBookPro16,2"]],
            ["general": ["name": "in1"],
             "hardware": ["serialNumber": "IN1", "appleSilicon": false,
                          "modelIdentifier": "MacBookPro14,1"]],
        ]
        return try XCTUnwrap(SecurityFleetCounts.build(
            items: JSONDecoder().decode([SecurityReportItem].self, from: json),
            hardware: HardwareEncryption.index(computers: computers), policy: policy))
    }

    /// Hardware-encrypted Macs the rule moves are not failing, whether they warn or are not
    /// counted; the Intel Mac still is. Without the rule all three fail.
    func testHardwareRuleMovesMacsOutOfTheFailingShare() throws {
        let share = { (policy: SecurityControlPolicy) throws -> Double in
            try XCTUnwrap(self.hardwareFleet(policy).nonFailingPct(.fileVault))
        }
        XCTAssertEqual(try share(.default), 25, accuracy: 0.001)
        XCTAssertEqual(try share(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)),
                       75, accuracy: 0.001)
        XCTAssertEqual(try share(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)),
                       75, accuracy: 0.001)
    }
}
