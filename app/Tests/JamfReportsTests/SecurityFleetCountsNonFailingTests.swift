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

    /// Hardware-encrypted Macs the rule moves to a warning are not failing; the Intel Mac
    /// still is. Without the rule all three fail. At `ignore` the two moved Macs are not in
    /// the share at all: one of the two Macs left fails.
    func testHardwareRuleMovesMacsOutOfTheFailingShare() throws {
        let share = { (policy: SecurityControlPolicy) throws -> Double in
            try XCTUnwrap(self.hardwareFleet(policy).nonFailingPct(.fileVault))
        }
        XCTAssertEqual(try share(.default), 25, accuracy: 0.001)
        XCTAssertEqual(try share(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)),
                       75, accuracy: 0.001)
        XCTAssertEqual(try share(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)),
                       50, accuracy: 0.001)
    }

    /// `encrypted` Macs with FileVault on, then Apple silicon and Intel Macs with it off.
    private func mixedFleet(
        encrypted: Int, silicon: Int, intel: Int, policy: SecurityControlPolicy
    ) throws -> SecurityFleetCounts {
        func device(_ serial: String, _ fileVault: String) -> [String: Any] {
            ["section": "device", "name": serial.lowercased(), "serial": serial,
             "os_version": "15.4.1", "filevault": fileVault, "sip": "ENABLED", "firewall": true,
             "gatekeeper": "APP_STORE"]
        }
        let total = encrypted + silicon + intel
        var items: [[String: Any]] = [["section": "summary", "data": [
            "total_devices": total, "filevault_encrypted": encrypted, "sip_enabled": total,
            "firewall_enabled": total, "gatekeeper_enabled": total,
        ]]]
        var computers: [[String: Any]] = []
        for n in 0..<encrypted { items.append(device("ON\(n)", "ENCRYPTED")) }
        for n in 0..<silicon {
            items.append(device("AS\(n)", "UNENCRYPTED"))
            computers.append(["general": ["name": "as\(n)"],
                              "hardware": ["serialNumber": "AS\(n)", "appleSilicon": true]])
        }
        for n in 0..<intel {
            items.append(device("IN\(n)", "UNENCRYPTED"))
            computers.append(["general": ["name": "in\(n)"],
                              "hardware": ["serialNumber": "IN\(n)", "appleSilicon": false,
                                           "modelIdentifier": "MacBookPro14,1"]])
        }
        return try XCTUnwrap(SecurityFleetCounts.build(
            items: JSONDecoder().decode(
                [SecurityReportItem].self, from: JSONSerialization.data(withJSONObject: items)),
            hardware: HardwareEncryption.index(computers: computers), policy: policy))
    }

    /// Ten Macs: five encrypted, three Apple silicon and two Intel with FileVault off, the
    /// hardware level at `ignore`. The three are not counted, so the share is 5 of 7, the
    /// same as the score's FileVault share (it was 8 of 10).
    func testHardwareIgnoredMacsLeaveTheShareAsTheyLeaveTheScore() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let fleet = try mixedFleet(encrypted: 5, silicon: 3, intel: 2, policy: policy)
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.fileVault)), 5.0 / 7.0 * 100,
                       accuracy: 0.001)
        let input = fleet.scoreInput()
        XCTAssertEqual(input.compliantCounts[.fileVault], 5)
        XCTAssertEqual(input.metricTotals[.fileVault], 7)
        // Other controls keep the whole fleet.
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.sip)), 100, accuracy: 0.001)
    }

    /// At warning the three stay in the share, as not failing.
    func testHardwareWarningMacsStayInTheShare() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let fleet = try mixedFleet(encrypted: 5, silicon: 3, intel: 2, policy: policy)
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.fileVault)), 80, accuracy: 0.001)
    }

    /// Every Mac with FileVault off is hardware-encrypted and not counted: no Mac is left to
    /// grade FileVault over, so it has no share (the score leaves it out too).
    func testNoShareWhenEveryMacIsNotCounted() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let fleet = try mixedFleet(encrypted: 0, silicon: 2, intel: 0, policy: policy)
        XCTAssertNil(fleet.nonFailingPct(.fileVault))
        XCTAssertNotNil(fleet.nonFailingPct(.sip))
    }
}
