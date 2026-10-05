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

    /// The control bar's visible count and its VoiceOver label both carry warnings.
    func testControlBarTextCountsWarnings() {
        typealias Gap = CompliancePostureService.Snapshot.ControlGap
        let none = Gap(control: "Firewall", failingDevices: 3, totalDevices: 10)
        let one = Gap(control: "Firewall", failingDevices: 3, totalDevices: 10, warningDevices: 1)
        let two = Gap(control: "Firewall", failingDevices: 3, totalDevices: 10, warningDevices: 2)
        XCTAssertEqual(CompliancePostureView.controlBarCountText(none), "3 failing")
        XCTAssertEqual(CompliancePostureView.controlBarCountText(one), "3 failing · 1 warning")
        XCTAssertEqual(CompliancePostureView.controlBarCountText(two), "3 failing · 2 warnings")

        let label = "Firewall control coverage, 30.0 percent failing, 3 of 10 devices"
        XCTAssertEqual(CompliancePostureView.controlBarAccessibilityLabel(none), label)
        XCTAssertEqual(CompliancePostureView.controlBarAccessibilityLabel(one),
                       label + ", 1 warning")
        XCTAssertEqual(CompliancePostureView.controlBarAccessibilityLabel(two),
                       label + ", 2 warnings")
    }

    /// A Security Posture KPI tile keeps its value; its sub-line says how the workspace's
    /// policy counts the Macs where the control is off.
    func testSecurityKPITileSubFollowsThePolicy() {
        let policy = SecurityControlPolicy(sip: .warning, firewall: .ignore, gatekeeper: .warning)
        let fleet = SecurityFleetCounts.build(
            totalDevices: 10,
            onCounts: [.fileVault: 8, .sip: 7, .firewall: 4, .gatekeeper: 9],
            devices: [], hardware: [:], policy: policy)
        func sub(_ control: SecurityControl, _ on: Int, _ fleet: SecurityFleetCounts) -> String {
            SecurityPostureView.kpiTileSub(control, on: on, total: 10, fleet: fleet)
        }
        XCTAssertEqual(sub(.fileVault, 8, fleet), "8 of 10")
        XCTAssertEqual(sub(.sip, 7, fleet), "7 of 10 · 3 warnings")
        XCTAssertEqual(sub(.gatekeeper, 9, fleet), "9 of 10 · 1 warning")
        XCTAssertEqual(sub(.firewall, 4, fleet), "Not counted by this workspace's policy")

        typealias Control = SecurityFleetCounts.Control
        let lowered = SecurityFleetCounts(
            totalDevices: 10,
            controls: [.fileVault: Control(level: .fail, on: 8, fail: 0, warning: 2)],
            fileVaultOffHardwareEncrypted: 2)
        XCTAssertEqual(sub(.fileVault, 8, lowered),
                       "8 of 10 · 2 more hardware-encrypted, FileVault off")
        let stricter = SecurityFleetCounts(
            totalDevices: 10,
            controls: [.fileVault: Control(level: .warning, on: 8, fail: 2, warning: 0)],
            fileVaultOffHardwareEncrypted: 0)
        XCTAssertEqual(sub(.fileVault, 8, stricter), "8 of 10",
                       "at hardware level fail those Macs are plain failures")
    }

    /// Without a FileVault count summary.json writes no P0, but the tile still sums the SIP
    /// and Firewall failures, as it did before the counts moved to the policy.
    func testP0TileSumsThePresentControlsWithoutAFileVaultCount() {
        let noFileVault = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.sip: 9, .firewall: 7, .gatekeeper: 8],
            devices: [], hardware: [:], policy: .default)
        XCTAssertNil(noFileVault.p0)
        XCTAssertEqual(SecurityPostureView.p0TileCount(noFileVault), 1 + 3)

        let sipWarning = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.sip: 9, .firewall: 7], devices: [], hardware: [:],
            policy: SecurityControlPolicy(sip: .warning))
        XCTAssertEqual(SecurityPostureView.p0TileCount(sipWarning), 3, "a warning is not a gap")

        let withFileVault = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.fileVault: 6, .sip: 9], devices: [], hardware: [:],
            policy: .default)
        XCTAssertEqual(SecurityPostureView.p0TileCount(withFileVault), withFileVault.p0)
        XCTAssertEqual(SecurityPostureView.p0TileCount(.empty), 0)
    }

    /// The report carries FileVault even when the hardware rule leaves no Mac to score it
    /// over, so the hero card gives it its own reason instead of calling it missing.
    func testMissingTextSaysWhyFileVaultIsNotScored() {
        typealias Control = SecurityFleetCounts.Control
        // Only the security report is collected, so the other factors have no data.
        let rest = "Secure Boot at full security, Bootstrap token escrowed, "
            + "macOS current (30-day grace), XProtect current (14-day grace), "
            + "Patch compliance, Checked in recently"
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let on = Control(level: .fail, on: 2, fail: 0, warning: 0)
        let allDropped = SecurityFleetCounts(
            totalDevices: 2,
            controls: [.fileVault: Control(level: .fail, on: 0, fail: 0, warning: 0),
                       .sip: on, .firewall: on],
            fileVaultOffHardwareEncrypted: 2)
        let dropped = SecurityScoreTestSupport.score(allDropped, policy: policy)
        XCTAssertTrue(dropped.missing.contains { $0.kind == .fileVault })
        XCTAssertEqual(
            SecurityPostureView.missingText(dropped, fleet: allDropped),
            "No data for Gatekeeper, \(rest), so not scored. "
                + "FileVault is not scored: every Mac with it off is hardware-encrypted "
                + "and not counted by this workspace's policy.")

        let noFileVault = SecurityFleetCounts(
            totalDevices: 2, controls: [.sip: on, .firewall: on], fileVaultOffHardwareEncrypted: 0)
        let absent = SecurityScoreTestSupport.score(noFileVault)
        XCTAssertEqual(
            SecurityPostureView.missingText(absent, fleet: noFileVault),
            "No data for FileVault, Gatekeeper, \(rest), so not scored.")
    }

    /// The check-in factor is named for the workspace's own stale window.
    func testMissingTextNamesTheCheckInWindow() {
        let score = SecurityScoreTestSupport.score(.empty)
        XCTAssertTrue(
            SecurityPostureView.missingText(score, fleet: .empty, staleDays: 45)
                .contains("Checked in within 45 days"))
    }

    // MARK: - Reading off the main actor

    /// Both posture screens read in a detached task, so the readers must not need the main
    /// actor, and must answer there as they do on it.
    func testPostureReadsRunOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-posture-off-main-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "posture-off-main"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let dataDir = workspace.appendingPathComponent("jamf-cli-data")
        for kind in ["security", "ea-results"] {
            try FileManager.default.createDirectory(
                at: dataDir.appendingPathComponent(kind), withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(
            at: TestFixtures.root.appendingPathComponent("jamf-cli-data/security/security.json"),
            to: dataDir.appendingPathComponent("security/security_20261001T090000.json"))
        let eaRows: [[String: Any]] = [
            ["device": "mac-1", "ea_name": "Failed Rules Count", "value": 0],
            ["device": "mac-2", "ea_name": "Failed Rules Count", "value": 12],
        ]
        try JSONSerialization.data(withJSONObject: eaRows).write(
            to: dataDir.appendingPathComponent("ea-results/ea-results_20261001T090000.json"))
        try """
        compliance:
          baselines:
            - name: "Baseline"
              failures_count_column: "Failed Rules Count"
        """.write(to: workspace.appendingPathComponent("config.yaml"),
                  atomically: true, encoding: .utf8)

        let compliance = await Task.detached {
            CompliancePostureService.load(profile: profile)
        }.value
        XCTAssertEqual(compliance, CompliancePostureService.load(profile: profile))
        XCTAssertEqual(compliance.totalDevices, 101)

        let security = await Task.detached { SecurityPostureService.load(profile: profile) }.value
        XCTAssertEqual(security, SecurityPostureService.load(profile: profile))
        XCTAssertEqual(security.totalDevices, 101)

        let baselines = await Task.detached {
            CompliancePostureView.loadBaselineResults(profile: profile)
        }.value
        XCTAssertEqual(baselines.map(\.name), ["Baseline"])
        XCTAssertEqual(baselines.first?.devicesWithData, 2)
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

        let snapshot = try XCTUnwrap(
            CompliancePostureService.load(from: tmp, policy: .default, hardware: [:]))

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

        let snapshot = try SecurityPostureService.load(from: tmp, policy: .default, hardware: [:])

        XCTAssertEqual(snapshot.totalDevices, 100)
        XCTAssertEqual(snapshot.fileVaultEncrypted, 95)
        XCTAssertEqual(snapshot.sipEnabled, 100)
        XCTAssertEqual(snapshot.firewallEnabled, 80)
        XCTAssertEqual(snapshot.osVersions.count, 2)
        // P0 = (100 - 95) + 0 + (100 - 80); P1 = 100 - 90.
        XCTAssertEqual(snapshot.fleetCounts.p0, 25)
        XCTAssertEqual(snapshot.fleetCounts.p1, 10)

        // The score is still useful from the limited counts even though most factors have no
        // data in this snapshot: the four controls at 15, 10, 10 and 5 over 95, 100, 80 and 90
        // percent, (1425 + 1000 + 800 + 450) / 40 = 91.875, shown to a tenth.
        let score = SecurityScoreTestSupport.score(snapshot.fleetCounts, policy: snapshot.policy)
        XCTAssertEqual(score.value, 91.9, accuracy: 0.001)
        XCTAssertEqual(score.available.map(\.id), ["filevault", "sip", "firewall", "gatekeeper"])
        XCTAssertTrue(score.missing.contains { $0.kind == .secureBoot })
        XCTAssertFalse(score.missing.contains { $0.kind == .mscp },
                       "no baseline is configured, so mSCP is not a factor to be missing")
    }
}
