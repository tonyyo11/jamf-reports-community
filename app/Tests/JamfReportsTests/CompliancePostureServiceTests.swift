import XCTest
@testable import JamfReports

@MainActor
final class CompliancePostureServiceTests: XCTestCase {

    func testLoadWithNonexistentProfileReturnsEmpty() {
        let snapshot = CompliancePostureService.load(profile: "nonexistent")
        XCTAssertEqual(snapshot, CompliancePostureService.Snapshot.empty)
        XCTAssertEqual(snapshot.totalDevices, 0)
    }

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = CompliancePostureService.Snapshot(
            totalDevices: 0,
            bands: [],
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = CompliancePostureService.Snapshot(
            totalDevices: 100,
            bands: [],
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = CompliancePostureService.Snapshot(
            totalDevices: 100,
            bands: [],
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }

    private func decodeDevice(_ json: String) throws -> SecurityDevice {
        try JSONDecoder().decode(SecurityDevice.self, from: Data(json.utf8))
    }

    func testNotCollectedControlsAreUnknownNotFailing() throws {
        // "NOT_COLLECTED" used to count as a failing control, making the
        // compliance proxy report a measured 0% on partially-collected tenants
        // (real shape from a live `pro report security` snapshot).
        let device = try decodeDevice("""
        {"section": "device", "name": "Mac-1", "serial": "X1",
         "filevault": "ENCRYPTED", "sip": "NOT_COLLECTED",
         "gatekeeper": "NOT_COLLECTED", "os_version": "15.0"}
        """)
        let policy = SecurityControlPolicy.default
        XCTAssertEqual(policy.verdict(for: .sip, value: device.sip, hardwareEncrypted: nil),
                       .unknown)
        XCTAssertEqual(
            policy.verdict(for: .gatekeeper, value: device.gatekeeper, hardwareEncrypted: nil),
            .unknown)
        XCTAssertEqual(
            CompliancePostureService.deviceGapCount(device, policy: policy, hardwareEncrypted: nil),
            0, "only the measured (passing) FileVault control participates")

        let allUnknown = try decodeDevice("""
        {"section": "device", "name": "Mac-2", "serial": "X2",
         "filevault": "NOT_COLLECTED", "sip": "UNKNOWN", "gatekeeper": ""}
        """)
        XCTAssertNil(
            CompliancePostureService.deviceGapCount(
                allUnknown, policy: policy, hardwareEncrypted: nil),
            "a device with no measured controls is No Data, not compliant")
    }

    // MARK: - Characterization: jamf-cli security fixture

    /// A real `pro report security` snapshot: 100 rows ENCRYPTED / NOT_COLLECTED /
    /// firewall false / NOT_COLLECTED, and one UNENCRYPTED / ENABLED / false / DISABLED.
    private var securityFixture: URL {
        TestFixtures.root.appendingPathComponent("jamf-cli-data/security/security.json")
    }

    private func fixtureDevices() throws -> [SecurityDevice] {
        let data = try Data(contentsOf: securityFixture)
        return try JSONDecoder().decode([SecurityReportItem].self, from: data).compactMap {
            if case .device(let device) = $0 { return device }
            return nil
        }
    }

    /// Gap count → number of devices with that count (nil keyed as -1).
    private func gapHistogram(_ policy: SecurityControlPolicy) throws -> [Int: Int] {
        try fixtureDevices().reduce(into: [:]) { histogram, device in
            let gaps = CompliancePostureService.deviceGapCount(
                device, policy: policy, hardwareEncrypted: nil)
            histogram[gaps ?? -1, default: 0] += 1
        }
    }

    private func failing(_ snapshot: CompliancePostureService.Snapshot) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: snapshot.controlGaps.map {
            ($0.control, $0.failingDevices)
        })
    }

    private func warnings(_ snapshot: CompliancePostureService.Snapshot) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: snapshot.controlGaps.map {
            ($0.control, $0.warningDevices)
        })
    }

    func testSecurityFixtureAtDefaultPolicyKeepsTodaysNumbers() throws {
        let snapshot = try XCTUnwrap(
            CompliancePostureService.load(from: securityFixture, policy: .default))
        XCTAssertEqual(snapshot.totalDevices, 101)
        XCTAssertEqual(try gapHistogram(.default), [1: 100, 3: 1])
        XCTAssertEqual(failing(snapshot),
                       ["FileVault": 1, "SIP": 0, "Firewall": 101, "Gatekeeper": 1])
        XCTAssertEqual(warnings(snapshot),
                       ["FileVault": 0, "SIP": 0, "Firewall": 0, "Gatekeeper": 0])
        XCTAssertEqual(snapshot.controlGaps.map(\.control),
                       ["Firewall", "FileVault", "Gatekeeper", "SIP"],
                       "sorted by failing devices, ties in control order")
    }

    func testIgnoredFirewallHasNoRowAndNoGaps() throws {
        let policy = SecurityControlPolicy(firewall: .ignore)
        let snapshot = try XCTUnwrap(
            CompliancePostureService.load(from: securityFixture, policy: policy))
        XCTAssertEqual(failing(snapshot), ["FileVault": 1, "SIP": 0, "Gatekeeper": 1])
        XCTAssertEqual(try gapHistogram(policy), [0: 100, 2: 1])
    }

    /// `load(profile:)` takes the policy from the workspace's config.yaml.
    func testLoadForAProfileUsesItsConfiguredPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cps-profile-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "compliance-policy"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let securityDir = workspace.appendingPathComponent("jamf-cli-data/security")
        try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: securityFixture,
            to: securityDir.appendingPathComponent("security_20261001T090000.json"))
        try "security_policy:\n  controls:\n    firewall: ignore\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let snapshot = CompliancePostureService.load(profile: profile)
        XCTAssertEqual(snapshot.totalDevices, 101)
        XCTAssertEqual(failing(snapshot), ["FileVault": 1, "SIP": 0, "Gatekeeper": 1])
    }

    func testFirewallAtWarningCountsWarningsNotFailures() throws {
        let policy = SecurityControlPolicy(firewall: .warning)
        let snapshot = try XCTUnwrap(
            CompliancePostureService.load(from: securityFixture, policy: policy))
        XCTAssertEqual(failing(snapshot),
                       ["FileVault": 1, "SIP": 0, "Firewall": 0, "Gatekeeper": 1])
        XCTAssertEqual(warnings(snapshot),
                       ["FileVault": 0, "SIP": 0, "Firewall": 101, "Gatekeeper": 0])
        XCTAssertEqual(try gapHistogram(policy), [0: 100, 2: 1])
    }

    // MARK: - summary.json compliance proxy

    /// A device row in the `pro report security` shape, passing every control
    /// unless told otherwise.
    private func deviceRow(
        _ name: String, fileVault: String = "ENCRYPTED", sip: String = "ENABLED",
        firewall: Bool = true
    ) -> [String: Any] {
        ["section": "device", "name": name, "serial": "", "os_version": "15.4.1",
         "filevault": fileVault, "sip": sip, "firewall": firewall,
         "gatekeeper": "APP_STORE_AND_IDENTIFIED_DEVELOPERS"]
    }

    /// The default policy's gap count for one row.
    private func defaultGapCount(_ row: [String: Any]) throws -> Int? {
        let data = try JSONSerialization.data(withJSONObject: row)
        let device = try JSONDecoder().decode(SecurityDevice.self, from: data)
        return CompliancePostureService.deviceGapCount(
            device, policy: .default, hardwareEncrypted: nil)
    }

    /// Runs the summary writer over one security snapshot and returns its proxy.
    private func summaryProxyPct(config: ReportConfig, rows: [[String: Any]]) throws -> Double? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let securityDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": rows.count, "filevault_encrypted": rows.count,
            "sip_enabled": rows.count, "firewall_enabled": rows.count,
            "gatekeeper_enabled": rows.count,
        ]]
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"
        let file = securityDir.appendingPathComponent(
            "security_\(stamp.string(from: Date().addingTimeInterval(-3600))).json")
        try JSONSerialization.data(withJSONObject: [summary] + rows).write(to: file)

        let summaries = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summaries)
        let written = try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
        XCTAssertEqual(written.complianceIsProxy, true)
        return written.compliancePct
    }

    /// Intended change at the default policy: FileVault mid-encryption, or a Mac that
    /// cannot report it, reads unknown, so it is no longer a FileVault gap. This moves
    /// the summary.json compliance proxy.
    func testFileVaultTransitionStatesAreNoLongerGaps() throws {
        let states = ["ENCRYPTING", "INELIGIBLE", "RESTART_NEEDED"]
        for state in states {
            XCTAssertEqual(try defaultGapCount(deviceRow("m", fileVault: state)), 0, state)
        }
        let rows = states.map { deviceRow($0, fileVault: $0) }
        let pct = try summaryProxyPct(config: ReportConfig(), rows: rows)
        XCTAssertEqual(try XCTUnwrap(pct), 100, accuracy: 0.01)
    }

    /// Intended change at the default policy: FileVault OPTIMIZING reads unknown, so it
    /// is no longer a FileVault gap (it was one before).
    func testFileVaultOptimizingIsNoLongerAGap() throws {
        let row = deviceRow("m", fileVault: "OPTIMIZING")
        XCTAssertEqual(try defaultGapCount(row), 0)
        let pct = try summaryProxyPct(config: ReportConfig(), rows: [row])
        XCTAssertEqual(try XCTUnwrap(pct), 100, accuracy: 0.01)
    }

    /// Intended change at the default policy: SIP NOT_AVAILABLE is unmeasured, like
    /// NOT_COLLECTED, so it is no longer a SIP gap (it was one before).
    func testSIPNotAvailableIsNoLongerAGap() throws {
        let row = deviceRow("m", sip: "NOT_AVAILABLE")
        XCTAssertEqual(try defaultGapCount(row), 0)
        let pct = try summaryProxyPct(config: ReportConfig(), rows: [row])
        XCTAssertEqual(try XCTUnwrap(pct), 100, accuracy: 0.01)
    }

    /// Unchanged at the default policy: a paused encryption stays paused until someone
    /// resumes it, so unlike ENCRYPTING it is still a FileVault gap.
    func testFileVaultEncryptingPausedIsStillAGap() throws {
        let row = deviceRow("m", fileVault: "ENCRYPTING_PAUSED")
        XCTAssertEqual(try defaultGapCount(row), 1)
        let pct = try summaryProxyPct(config: ReportConfig(), rows: [row])
        XCTAssertEqual(try XCTUnwrap(pct), 0, accuracy: 0.01)
    }

    /// The summary writer reads the workspace's policy from config.yaml.
    func testSummaryProxyFollowsTheWorkspacePolicy() throws {
        let rows = [deviceRow("a", firewall: false), deviceRow("b", firewall: false)]
        let strict = try summaryProxyPct(config: ReportConfig(), rows: rows)
        XCTAssertEqual(try XCTUnwrap(strict), 0, accuracy: 0.01)

        let config = try ConfigLoader.loadFromString("""
        security_policy:
          controls:
            firewall: ignore
        """)
        let lenient = try summaryProxyPct(config: config, rows: rows)
        XCTAssertEqual(try XCTUnwrap(lenient), 100, accuracy: 0.01)
    }
}
