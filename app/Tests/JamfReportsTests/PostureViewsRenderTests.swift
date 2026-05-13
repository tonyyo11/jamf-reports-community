import XCTest
import SwiftUI
@testable import JamfReports

/// Smoke tests for the new Posture views. SwiftUI's `xctest` host does not
/// drive a real view tree, so these confirm the views and their helpers can
/// be instantiated without crashing — the same harness `LightModeRenderTests`
/// uses for the existing screens.
@MainActor
final class PostureViewsRenderTests: XCTestCase {

    func testPostureViewsInstantiateInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = SecurityPostureView().environment(workspace)
        _ = CompliancePostureView().environment(workspace)
    }

    func testPostureViewsInstantiateOutsideDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false

        _ = SecurityPostureView().environment(workspace)
        _ = CompliancePostureView().environment(workspace)
    }

    // MARK: - Service decode parity

    /// Confirms the production v1.7 security report shape (flat per-device
    /// fields) decodes through `SecurityDevice` without losing data and
    /// produces the expected gap counts.
    func testCompliancePostureServiceDerivesGapCountsFromDeviceRows() throws {
        let json = """
        [
          {"section": "summary", "data": {"total_devices": 4, "filevault_encrypted": 2,
            "gatekeeper_enabled": 4, "sip_enabled": 3, "firewall_enabled": 3}},
          {"section": "device", "name": "clean-device", "serial": "C1",
            "os_version": "15.4.1",
            "filevault": "ENCRYPTED", "sip": "ENABLED", "firewall": true,
            "gatekeeper": "APP_STORE_AND_IDENTIFIED_DEVELOPERS"},
          {"section": "device", "name": "fv-fail", "serial": "C2",
            "os_version": "15.4.1",
            "filevault": "NOT_ENCRYPTED", "sip": "ENABLED", "firewall": true,
            "gatekeeper": "APP_STORE_AND_IDENTIFIED_DEVELOPERS"},
          {"section": "device", "name": "fw-and-sip-fail", "serial": "C3",
            "os_version": "14.7.5",
            "filevault": "ENCRYPTED", "sip": "DISABLED", "firewall": false,
            "gatekeeper": "ENABLED"},
          {"section": "device", "name": "all-fail", "serial": "C4",
            "os_version": "14.7.5",
            "filevault": "NOT_ENCRYPTED", "sip": "DISABLED", "firewall": false,
            "gatekeeper": "DISABLED"},
          {"section": "os_version", "os_version": "15.4.1", "count": 2, "pct": "50%"},
          {"section": "os_version", "os_version": "14.7.5", "count": 2, "pct": "50%"}
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(CompliancePostureService.load(from: tmp))

        XCTAssertEqual(snapshot.totalDevices, 4)

        let byLabel = Dictionary(uniqueKeysWithValues:
            snapshot.bands.map { ($0.label, $0.count) }
        )
        XCTAssertEqual(byLabel["Pass"], 1, "Exactly one all-pass device")
        XCTAssertEqual(byLabel["Low"], 3, "Three devices in 1-3 failing-control range")
        XCTAssertEqual(byLabel["No Data"], 0)

        // Control gap rates should be: FV 2/4, SIP 2/4, Firewall 2/4, Gatekeeper 1/4
        let gaps = Dictionary(uniqueKeysWithValues:
            snapshot.controlGaps.map { ($0.control, $0.failingDevices) }
        )
        XCTAssertEqual(gaps["FileVault"], 2)
        XCTAssertEqual(gaps["SIP"], 2)
        XCTAssertEqual(gaps["Firewall"], 2)
        XCTAssertEqual(gaps["Gatekeeper"], 1)

        // Per-OS breakdown: 15 → {Pass: 1, Low: 1}, 14 → {Low: 2}
        let fifteenBands = try XCTUnwrap(
            snapshot.perOSMajor.first(where: { $0.osMajor == 15 })?.bands
        )
        let fifteenByLabel = Dictionary(uniqueKeysWithValues:
            fifteenBands.map { ($0.label, $0.count) }
        )
        XCTAssertEqual(fifteenByLabel["Pass"], 1)
        XCTAssertEqual(fifteenByLabel["Low"], 1)

        let fourteenBands = try XCTUnwrap(
            snapshot.perOSMajor.first(where: { $0.osMajor == 14 })?.bands
        )
        let fourteenByLabel = Dictionary(uniqueKeysWithValues:
            fourteenBands.map { ($0.label, $0.count) }
        )
        XCTAssertEqual(fourteenByLabel["Low"], 2)
    }

    func testSecurityPostureServiceLoadsSummarySection() throws {
        let json = """
        [
          {"section": "summary", "data": {"total_devices": 100, "filevault_encrypted": 95,
            "gatekeeper_enabled": 90, "sip_enabled": 100, "firewall_enabled": 80}},
          {"section": "os_version", "os_version": "15.4.1", "count": 60, "pct": "60%"},
          {"section": "os_version", "os_version": "14.7.5", "count": 40, "pct": "40%"}
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("security-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try SecurityPostureService.load(from: tmp)

        XCTAssertEqual(snapshot.totalDevices, 100)
        XCTAssertEqual(snapshot.fileVaultEncrypted, 95)
        XCTAssertEqual(snapshot.sipEnabled, 100)
        XCTAssertEqual(snapshot.firewallEnabled, 80)
        XCTAssertEqual(snapshot.osVersions.count, 2)

        // SecurityScoreCalculator should still produce a useful score from
        // the limited counts even though several score-bearing metrics are
        // absent from this snapshot (mSCP, CrowdStrike, etc.).
        let score = SecurityScoreCalculator.score(
            input: SecurityScoreCalculator.input(from: snapshot)
        )
        XCTAssertFalse(score.available.isEmpty)
        XCTAssertTrue(score.missing.contains(.mscp))
        XCTAssertTrue(score.missing.contains(.crowdstrike))
    }
}
