import XCTest
@testable import JamfReports

/// The posture insight: each posture screen sends only the counts it shows, under the
/// workspace's security policy. Class-level `@MainActor` because the P0 check reads the
/// Security Posture view's own tile count.
@MainActor
final class PostureInsightInputTests: XCTestCase {

    private let gapNote = "Failing is a gap under this workspace's security policy. A warning "
        + "is a Mac with the control off that the policy does not count as a gap."
    private let actionNote = "P0 and P1 add up each control's gaps, so a Mac failing two of "
        + "their controls counts twice."
    private let bandNote = "Bands count the controls a Mac fails: Pass is none, Low and above "
        + "one or more, No Data none measured."

    // MARK: - Fixtures

    private func summary(_ counts: [String: Int]) -> [String: Any] {
        ["section": "summary", "data": counts]
    }

    private func device(
        _ name: String, serial: String, os: String = "15.4.1", fileVault: String = "ENCRYPTED",
        sip: String = "ENABLED", firewall: Bool = true, gatekeeper: String = "ENABLED",
        data: [String: Any]? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "section": "device", "name": name, "serial": serial, "os_version": os,
            "filevault": fileVault, "sip": sip, "firewall": firewall, "gatekeeper": gatekeeper,
        ]
        if let data { row["data"] = data }
        return row
    }

    /// `computers` snapshot rows: one Apple silicon Mac and one Intel Mac without a T2.
    private func computers() -> [[String: Any]] {
        [["general": ["name": "as-mac"],
          "hardware": ["serialNumber": "AS1", "appleSilicon": true]],
         ["general": ["name": "intel-mac"],
          "hardware": ["serialNumber": "IN1", "appleSilicon": false,
                       "modelIdentifier": "MacBookPro14,1"]]]
    }

    /// Both screens' snapshots, read from one security report the way the screens read it.
    private func snapshots(
        _ rows: [[String: Any]], policy: SecurityControlPolicy = .default,
        hardware: [String: Bool] = [:]
    ) throws -> (security: SecurityPostureService.Snapshot,
                 compliance: CompliancePostureService.Snapshot) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-posture-insight-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        let security = try SecurityPostureService.load(
            from: url, policy: policy, hardware: hardware)
        let compliance = try XCTUnwrap(
            CompliancePostureService.load(from: url, policy: policy, hardware: hardware))
        return (security, compliance)
    }

    private func lines(_ input: FleetInsightInput?) -> [String] {
        input?.promptContext().components(separatedBy: "\n") ?? []
    }

    // MARK: - Security Posture

    func testSecurityFactsUnderTheDefaultPolicyAreTheScreensCounts() throws {
        let security = try snapshots([summary([
            "total_devices": 10, "filevault_encrypted": 8, "sip_enabled": 9,
            "firewall_enabled": 7, "gatekeeper_enabled": 6,
        ])]).security
        let input = FleetInsightInput.posture(.security(security))
        XCTAssertEqual(lines(input), [
            "Posture insight",
            "Focus: which control accounts for most of the gap, and what to do first.",
            "- Macs in the security report: 10",
            // Most Macs failing first, as the Control Coverage Gaps bars order them.
            "- Gatekeeper enabled on 60.0% of devices; off on 40.0%",
            "- Macs failing Gatekeeper: 4",
            "- Firewall enabled on 70.0% of devices; off on 30.0%",
            "- Macs failing Firewall: 3",
            "- FileVault enabled on 80.0% of devices; off on 20.0%",
            "- Macs failing FileVault: 2",
            "- System Integrity Protection (SIP) enabled on 90.0% of devices; off on 10.0%",
            "- Macs failing SIP: 1",
            "- P0 action items (FileVault, SIP and Firewall gaps): 6",
            "- P1 action items (Gatekeeper gaps): 4",
            gapNote,
            actionNote,
        ])
        XCTAssertEqual(SecurityPostureView.p0TileCount(security.fleetCounts), 6,
                       "the P0 fact is the tile's number")
    }

    func testSecurityHardwareWarningIsAWarningNeverAFailureOrUnencrypted() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let security = try snapshots([
            summary(["total_devices": 3, "filevault_encrypted": 1, "sip_enabled": 3,
                     "firewall_enabled": 3, "gatekeeper_enabled": 3]),
            device("as-mac", serial: "AS1", fileVault: "UNENCRYPTED"),
            device("intel-mac", serial: "IN1", fileVault: "UNENCRYPTED"),
            device("other-mac", serial: "OT1"),
        ], policy: policy, hardware: HardwareEncryption.index(computers: computers())).security
        let context = lines(FleetInsightInput.posture(.security(security)))
        XCTAssertEqual(Array(context.prefix(6)), [
            "Posture insight",
            "Focus: which control accounts for most of the gap, and what to do first.",
            "- Macs in the security report: 3",
            "- FileVault enabled on 33.3% of devices; off on 66.7%",
            "- Macs failing FileVault: 1",
            "- Macs with FileVault off, hardware-encrypted (a warning, not failing): 1",
        ])
        XCTAssertTrue(context.contains("- P0 action items (FileVault, SIP and Firewall gaps): 1"))
        XCTAssertEqual(SecurityPostureView.p0TileCount(security.fleetCounts), 1)
        XCTAssertFalse(context.contains { $0.contains("not counted by this workspace's policy") })
        let text = context.joined(separator: "\n").lowercased()
        XCTAssertFalse(text.contains("unencrypted") || text.contains("not encrypted"))
    }

    func testSecurityHardwareIgnoreIsOneNeutralCount() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let security = try snapshots([
            summary(["total_devices": 4, "filevault_encrypted": 2, "sip_enabled": 4,
                     "firewall_enabled": 4, "gatekeeper_enabled": 4]),
            device("as-mac", serial: "AS1", fileVault: "UNENCRYPTED"),
            device("intel-mac", serial: "IN1", fileVault: "UNENCRYPTED"),
        ], policy: policy, hardware: HardwareEncryption.index(computers: computers())).security
        let context = lines(FleetInsightInput.posture(.security(security)))
        // The share is the FileVault tile's 2 of 4; of the two Macs off, one fails and the
        // policy does not count the other.
        XCTAssertEqual(Array(context[3...6]), [
            "- FileVault enabled on 50.0% of devices; off on 50.0%",
            "- Macs failing FileVault: 1",
            "- Macs with FileVault off, hardware-encrypted, not counted by this workspace's "
                + "policy: 1",
            "- System Integrity Protection (SIP) enabled on 100.0% of devices; off on 0.0%",
        ])
        XCTAssertFalse(context.contains { $0.contains("a warning, not failing") })
    }

    /// The share is the tile's (Macs with the control on); the policy shows in the counts.
    func testSecurityControlAtWarningKeepsTheTilesShare() throws {
        let security = try snapshots([summary([
            "total_devices": 10, "filevault_encrypted": 10, "sip_enabled": 7,
            "firewall_enabled": 10, "gatekeeper_enabled": 10,
        ])], policy: SecurityControlPolicy(sip: .warning)).security
        let context = lines(FleetInsightInput.posture(.security(security)))
        let sip = "- System Integrity Protection (SIP) enabled on 70.0% of devices; off on 30.0%"
        let start = try XCTUnwrap(context.firstIndex(of: sip))
        XCTAssertEqual(Array(context[start...(start + 2)]), [
            sip, "- Macs failing SIP: 0", "- Macs with SIP off (a warning, not failing): 3",
        ])
    }

    func testSecurityLeavesOutIgnoredControlsAndControlsWithoutACount() throws {
        let policy = SecurityControlPolicy(firewall: .ignore)
        // No gatekeeper_enabled: Gatekeeper has no count, so neither it nor P1 is sent.
        let security = try snapshots([summary([
            "total_devices": 10, "filevault_encrypted": 9, "sip_enabled": 8, "firewall_enabled": 1,
        ])], policy: policy).security
        let text = lines(FleetInsightInput.posture(.security(security))).joined(separator: "\n")
        XCTAssertFalse(text.contains("- Firewall"))
        XCTAssertFalse(text.contains("Macs failing Firewall"))
        XCTAssertFalse(text.contains("Gatekeeper failing"))
        XCTAssertFalse(text.contains("P1 action items"))
        XCTAssertTrue(text.contains("- P0 action items (FileVault, SIP and Firewall gaps): 3"))
    }

    func testSecurityWithNothingToSendIsNil() throws {
        XCTAssertNil(FleetInsightInput.posture(.security(.empty)))
        let everyControlIgnored = SecurityControlPolicy(
            fileVault: .ignore, sip: .ignore, firewall: .ignore, gatekeeper: .ignore)
        let security = try snapshots([summary([
            "total_devices": 10, "filevault_encrypted": 9, "sip_enabled": 8,
            "firewall_enabled": 1, "gatekeeper_enabled": 5,
        ])], policy: everyControlIgnored).security
        XCTAssertNil(FleetInsightInput.posture(.security(security)))
    }

    // MARK: - Compliance Posture

    /// Four Macs: one clean, one FileVault off on macOS 15; SIP and Firewall off, and all
    /// four off, on macOS 14.
    private var fourMacs: [[String: Any]] {
        [device("clean", serial: "C1"),
         device("fv-off", serial: "C2", fileVault: "NOT_ENCRYPTED"),
         device("sip-fw-off", serial: "C3", os: "14.7.5", sip: "DISABLED", firewall: false),
         device("all-off", serial: "C4", os: "14.7.5", fileVault: "NOT_ENCRYPTED",
                sip: "DISABLED", firewall: false, gatekeeper: "DISABLED")]
    }

    func testComplianceFactsUnderTheDefaultPolicyAreTheScreensCounts() throws {
        let compliance = try snapshots(fourMacs).compliance
        let input = FleetInsightInput.posture(.compliance(compliance, showsBands: true))
        XCTAssertEqual(lines(input), [
            "Posture insight",
            "Focus: which control and which macOS major account for most of the gap, and what "
                + "to do first.",
            "- Macs in the security report: 4",
            "- FileVault failing on 50.0% of devices; not failing on 50.0%",
            "- Macs failing FileVault: 2",
            "- System Integrity Protection (SIP) failing on 50.0% of devices; not failing on 50.0%",
            "- Macs failing SIP: 2",
            "- Firewall failing on 50.0% of devices; not failing on 50.0%",
            "- Macs failing Firewall: 2",
            "- Gatekeeper failing on 25.0% of devices; not failing on 75.0%",
            "- Macs failing Gatekeeper: 1",
            "- All Macs: 3 of 4 Macs fail at least one control (Pass 1, Low 3)",
            // The screen lists macOS 15 first; the major with more Macs failing leads here.
            "- macOS 14: 2 of 2 Macs fail at least one control (Low 2)",
            "- macOS 15: 1 of 2 Macs fail at least one control (Pass 1, Low 1)",
            gapNote,
            bandNote,
        ])
    }

    func testComplianceHardwareWarningIsAWarningNeverAFailure() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let compliance = try snapshots([
            device("as-mac", serial: "AS1", fileVault: "UNENCRYPTED"),
            device("intel-mac", serial: "IN1", os: "14.1", fileVault: "UNENCRYPTED"),
            device("other-mac", serial: "OT1"),
        ], policy: policy, hardware: HardwareEncryption.index(computers: computers())).compliance
        let context = lines(FleetInsightInput.posture(.compliance(compliance, showsBands: true)))
        XCTAssertEqual(Array(context[3...5]), [
            "- FileVault failing on 33.3% of devices; not failing on 66.7%",
            "- Macs failing FileVault: 1",
            "- Macs with FileVault off, hardware-encrypted (a warning, not failing): 1",
        ])
        XCTAssertTrue(
            context.contains("- All Macs: 1 of 3 Macs fail at least one control (Pass 2, Low 1)"))
        let text = context.joined(separator: "\n").lowercased()
        XCTAssertFalse(text.contains("unencrypted") || text.contains("not encrypted"))
    }

    func testComplianceWithoutTheBandsCardSendsNoFleetBands() throws {
        let compliance = try snapshots(fourMacs).compliance
        let context = lines(FleetInsightInput.posture(.compliance(compliance, showsBands: false)))
        XCTAssertFalse(context.contains { $0.hasPrefix("- All Macs:") })
        XCTAssertTrue(context.contains("- macOS 14: 2 of 2 Macs fail at least one control (Low 2)"),
                      "the per-OS card shows under mSCP donuts too")
    }

    func testComplianceWithNothingToSendIsNil() {
        XCTAssertNil(FleetInsightInput.posture(.compliance(.empty, showsBands: true)))
    }

    // MARK: - Privacy

    func testNoDeviceNameSerialOrUsernameReachesThePrompt() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let hardware = HardwareEncryption.index(computers: [
            ["general": ["name": "Johns-MacBook-Pro"],
             "hardware": ["serialNumber": "C02XK1ABCDEF", "appleSilicon": true],
             "userAndLocation": ["username": "jdoe", "email": "jdoe@example.org"]],
        ])
        let both = try snapshots([
            summary(["total_devices": 2, "filevault_encrypted": 1, "sip_enabled": 2,
                     "firewall_enabled": 1, "gatekeeper_enabled": 2]),
            device("Johns-MacBook-Pro", serial: "C02XK1ABCDEF", os: "15.4.1 jdoe",
                   fileVault: "UNENCRYPTED", data: ["username": "jdoe",
                                                    "email": "jdoe@example.org"]),
            device("jdoe-mini", serial: "C02JDOE00001", firewall: false),
        ], policy: policy, hardware: hardware)
        let inputs = [FleetInsightInput.posture(.security(both.security)),
                      FleetInsightInput.posture(.compliance(both.compliance, showsBands: true))]
        for input in inputs {
            let context = try XCTUnwrap(input).promptContext()
            XCTAssertTrue(context.contains("hardware-encrypted (a warning, not failing): 1"),
                          "the device rows were read")
            for secret in ["Johns-MacBook-Pro", "C02XK1ABCDEF", "jdoe", "C02JDOE00001"] {
                XCTAssertFalse(context.contains(secret), "\(secret) reached the prompt")
            }
        }
    }
}
