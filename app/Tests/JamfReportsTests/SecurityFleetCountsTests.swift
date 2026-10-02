import XCTest
@testable import JamfReports

final class SecurityFleetCountsTests: XCTestCase {

    private typealias Control = SecurityFleetCounts.Control

    // MARK: - Characterization: the summary writer

    private var securityFixture: URL {
        TestFixtures.root.appendingPathComponent("jamf-cli-data/security/security.json")
    }

    /// Runs the summary writer over one security snapshot and returns what it wrote.
    private func writtenSummary(
        config: ReportConfig = ReportConfig(), security: Data? = nil,
        computers: [[String: Any]]? = nil
    ) throws -> DailySummary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-fleet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"
        let name = stamp.string(from: Date().addingTimeInterval(-3600))
        let securityDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)
        try (security ?? Data(contentsOf: securityFixture))
            .write(to: securityDir.appendingPathComponent("security_\(name).json"))
        if let computers {
            let dir = dataDir.appendingPathComponent("computers", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: computers)
                .write(to: dir.appendingPathComponent("computers_\(name).json"))
        }
        let summaries = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summaries)
        return try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
    }

    /// The fixture's summary: 101 Macs, FileVault 100, SIP 1, Firewall 0, Gatekeeper 100.
    /// P0 = 1 + 100 + 101; P1 = 1; score = mean of 99.0, 1.0 and 0.0 percent.
    func testSecurityFixtureThroughTheSummaryWriterKeepsTodaysNumbers() throws {
        let summary = try writtenSummary()
        XCTAssertEqual(summary.actionItemsP0, 202)
        XCTAssertEqual(summary.actionItemsP1, 1)
        XCTAssertEqual(try XCTUnwrap(summary.securityScore), 33.3, accuracy: 0.001)
    }

    // MARK: - Fixtures

    private func fixtureItems() throws -> [SecurityReportItem] {
        try JSONDecoder().decode(
            [SecurityReportItem].self, from: Data(contentsOf: securityFixture))
    }

    private func fixtureCounts(_ policy: SecurityControlPolicy) throws -> SecurityFleetCounts {
        try XCTUnwrap(SecurityFleetCounts.build(
            items: fixtureItems(), hardware: [:], policy: policy))
    }

    private func score(_ fleet: SecurityFleetCounts, _ policy: SecurityControlPolicy)
        -> SecurityScore {
        SecurityScoreCalculator.score(
            input: fleet.scoreInput(), weights: policy.effectiveScoreWeights(.defaultWeights))
    }

    private func controls(_ yaml: String) throws -> SecurityControlPolicy {
        try ConfigLoader.loadFromString(yaml).resolvedSecurityPolicy
    }

    // MARK: - Default policy

    func testDefaultPolicyIsTodaysArithmetic() throws {
        let fleet = try fixtureCounts(.default)
        XCTAssertEqual(fleet.totalDevices, 101)
        XCTAssertEqual(fleet.controls, [
            .fileVault: Control(level: .fail, on: 100, fail: 1, warning: 0),
            .sip: Control(level: .fail, on: 1, fail: 100, warning: 0),
            .firewall: Control(level: .fail, on: 0, fail: 101, warning: 0),
            .gatekeeper: Control(level: .fail, on: 100, fail: 1, warning: 0),
        ])
        XCTAssertEqual(fleet.p0, 202)
        XCTAssertEqual(fleet.p1, 1)
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 0)
        XCTAssertEqual(fleet.scoreInput(), SecurityScoreCalculator.Input(
            totalDevices: 101, compliantCounts: [.fileVault: 100, .sip: 1, .firewall: 0]))
        XCTAssertEqual(SecurityControlPolicy.default.effectiveScoreWeights(.defaultWeights),
                       .defaultWeights)
        XCTAssertEqual(score(fleet, .default).value, 33.3, accuracy: 0.001)

        // GoldenFleet case A's counts: P0 = 10 + 0 + 5, P1 = 2, score (96 + 100 + 98) / 3.
        let golden = SecurityFleetCounts.build(
            totalDevices: 250,
            onCounts: [.fileVault: 240, .sip: 250, .firewall: 245, .gatekeeper: 248],
            devices: [], hardware: [:], policy: .default)
        XCTAssertEqual(golden.p0, 15)
        XCTAssertEqual(golden.p1, 2)
        XCTAssertEqual(score(golden, .default).value, 98.0, accuracy: 0.001)
    }

    func testOnCountsReadTheSummaryKeys() throws {
        let summary = try XCTUnwrap(fixtureItems().lazy.compactMap { item -> SecuritySummaryData? in
            if case .summary(let section) = item { return section.data }
            return nil
        }.first)
        XCTAssertEqual(SecurityFleetCounts.onCounts(summary),
                       [.fileVault: 100, .sip: 1, .firewall: 0, .gatekeeper: 100])
    }

    /// A control the summary carries no count for is left out: no P0 without FileVault (as
    /// before), no P1 without Gatekeeper, and the score lists the control as missing.
    func testAControlWithoutASummaryCountIsAbsent() {
        let fleet = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.sip: 9], devices: [], hardware: [:], policy: .default)
        XCTAssertEqual(Set(fleet.controls.keys), [.sip])
        XCTAssertNil(fleet.p0)
        XCTAssertNil(fleet.p1)
        let withFileVault = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.fileVault: 7, .sip: 9], devices: [], hardware: [:],
            policy: .default)
        XCTAssertEqual(withFileVault.p0, 4)
        XCTAssertTrue(score(withFileVault, .default).missing.contains(.firewall))
    }

    func testBuildFromItemsIsNilWithoutASummarySection() throws {
        let devicesOnly = try fixtureItems().filter {
            if case .summary = $0 { return false }
            return true
        }
        XCTAssertNil(SecurityFleetCounts.build(items: devicesOnly, hardware: [:], policy: .default))
        XCTAssertNil(SecurityFleetCounts.build(items: [], hardware: [:], policy: .default))
    }

    /// Intended change: a summary count above the total gives no off Macs. Before, the
    /// difference went negative and lowered P0.
    func testACountAboveTheTotalIsNotANegativeGap() {
        let fleet = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.fileVault: 12, .sip: 8], devices: [], hardware: [:],
            policy: .default)
        XCTAssertEqual(fleet.controls[.fileVault]?.fail, 0)
        XCTAssertEqual(fleet.p0, 2)
    }

    // MARK: - Levels

    func testSIPAtWarningLeavesP0AndScoresAsCompliant() throws {
        let policy = try controls("security_policy:\n  controls:\n    sip: warning\n")
        let fleet = try fixtureCounts(policy)
        XCTAssertEqual(fleet.controls[.sip], Control(level: .warning, on: 1, fail: 0, warning: 100))
        XCTAssertEqual(fleet.p0, 1 + 101, "FileVault and Firewall only")
        XCTAssertEqual(fleet.scoreInput().compliantCounts[.sip], 101, "every Mac")
        // (99.01 + 100 + 0) / 3
        XCTAssertEqual(score(fleet, policy).value, 66.3, accuracy: 0.001)
    }

    func testFirewallAtIgnoreHasNoWeightAndIsNotMissing() throws {
        let policy = try controls("security_policy:\n  controls:\n    firewall: ignore\n")
        let fleet = try fixtureCounts(policy)
        XCTAssertEqual(fleet.controls[.firewall],
                       Control(level: .ignore, on: 0, fail: 0, warning: 0))
        XCTAssertEqual(fleet.p0, 1 + 100)
        let weights = policy.effectiveScoreWeights(.defaultWeights)
        XCTAssertEqual(weights.firewall, 0)
        var others = weights
        others.firewall = SecurityScoreWeights.defaultWeights.firewall
        XCTAssertEqual(others, .defaultWeights, "only the ignored control's weight changes")
        let result = score(fleet, policy)
        XCTAssertFalse(result.missing.contains(.firewall))
        XCTAssertEqual(result.available, [.fileVault, .sip])
        XCTAssertEqual(result.value, 50.0, accuracy: 0.001)
    }

    func testEachIgnoredScoredControlLosesItsWeight() {
        let policy = SecurityControlPolicy(
            fileVault: .ignore, sip: .ignore, firewall: .warning, gatekeeper: .ignore)
        let weights = policy.effectiveScoreWeights(.defaultWeights)
        XCTAssertEqual(weights.fileVault, 0)
        XCTAssertEqual(weights.sip, 0)
        XCTAssertEqual(weights.firewall, SecurityScoreWeights.defaultWeights.firewall)
        XCTAssertEqual(weights.mscp, SecurityScoreWeights.defaultWeights.mscp)
    }

    func testGatekeeperLevelsMoveP1() {
        let onCounts: [SecurityControl: Int] = [.fileVault: 10, .gatekeeper: 7]
        let p1 = SecurityControlLevel.allCases.map { level in
            SecurityFleetCounts.build(
                totalDevices: 10, onCounts: onCounts, devices: [], hardware: [:],
                policy: SecurityControlPolicy(gatekeeper: level)).p1
        }
        XCTAssertEqual(p1, [3, 0, 0], "fail, warning, ignore")
    }

    // MARK: - Hardware rule

    /// Real `pro report security` device row: FileVault as given, every other control on.
    private func row(_ name: String, serial: String, fileVault: String) -> [String: Any] {
        ["section": "device", "name": name, "serial": serial, "os_version": "15.4.1",
         "filevault": fileVault, "sip": "ENABLED", "firewall": true,
         "gatekeeper": "APP_STORE_AND_IDENTIFIED_DEVELOPERS"]
    }

    /// Four Macs, FileVault on one: Apple silicon and a T2 Mac (hardware-encrypted), an
    /// Intel Mac without T2, and one with no serial matched by its unique name.
    private func hardwareFleetJSON(fileVaultOn: Int = 1) throws -> Data {
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 5, "filevault_encrypted": fileVaultOn, "sip_enabled": 5,
            "firewall_enabled": 5, "gatekeeper_enabled": 5,
        ]]
        return try JSONSerialization.data(withJSONObject: [summary,
            row("on-mac", serial: "ON1", fileVault: "ENCRYPTED"),
            row("as-mac", serial: "AS1", fileVault: "UNENCRYPTED"),
            row("t2-mac", serial: "T21", fileVault: "UNENCRYPTED"),
            row("intel-mac", serial: "IN1", fileVault: "UNENCRYPTED"),
            row("lab-mac", serial: "", fileVault: "UNENCRYPTED"),
        ])
    }

    private let computers: [[String: Any]] = [
        ["general": ["name": "as-mac"], "hardware": ["serialNumber": "AS1", "appleSilicon": true]],
        ["general": ["name": "t2-mac"],
         "hardware": ["serialNumber": "T21", "modelIdentifier": "MacBookPro16,2"]],
        ["general": ["name": "intel-mac"],
         "hardware": ["serialNumber": "IN1", "appleSilicon": false,
                      "modelIdentifier": "MacBookPro14,1"]],
        ["general": ["name": "lab-mac"], "hardware": ["appleSilicon": true]],
    ]

    private func hardwareCounts(
        _ policy: SecurityControlPolicy, fileVaultOn: Int = 1
    ) throws -> SecurityFleetCounts {
        let items = try JSONDecoder().decode(
            [SecurityReportItem].self, from: hardwareFleetJSON(fileVaultOn: fileVaultOn))
        return try XCTUnwrap(SecurityFleetCounts.build(
            items: items, hardware: HardwareEncryption.index(computers: computers),
            policy: policy))
    }

    /// Apple silicon, T2 and the no-serial Mac matched by name move to warning; Intel stays.
    func testHardwareRuleAtWarningMovesHardwareEncryptedMacsToWarning() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let fleet = try hardwareCounts(policy)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .fail, on: 1, fail: 1, warning: 3))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 3)
        XCTAssertEqual(fleet.p0, 1)
        XCTAssertEqual(fleet.scoreInput().compliantCounts[.fileVault], 4)
        XCTAssertEqual(fleet.scoreInput().metricTotals, [:], "a share of the whole fleet")
    }

    func testHardwareRuleAtIgnoreDropsHardwareEncryptedMacs() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let fleet = try hardwareCounts(policy)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .fail, on: 1, fail: 1, warning: 0))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 3)
        XCTAssertEqual(fleet.p0, 1)
        XCTAssertEqual(fleet.scoreInput().compliantCounts[.fileVault], 1)
        XCTAssertEqual(fleet.scoreInput().metricTotals, [.fileVault: 2])
    }

    /// Not counted means not counted in the score either: FileVault's share is the same as
    /// for a fleet without the three Macs the rule dropped (1 of the 2 left).
    func testHardwareRuleAtIgnoreLeavesThoseMacsOutOfTheFileVaultShare() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let withDropped = score(try hardwareCounts(policy), policy)
        let without = score(SecurityFleetCounts.build(
            totalDevices: 2,
            onCounts: [.fileVault: 1, .sip: 2, .firewall: 2, .gatekeeper: 2],
            devices: [], hardware: [:], policy: policy), policy)
        XCTAssertEqual(withDropped, without)
        // (50 + 100 + 100) / 3
        XCTAssertEqual(withDropped.value, 83.3, accuracy: 0.001)
    }

    /// Every Mac hardware-encrypted with FileVault off and dropped: FileVault has no share
    /// this run, neither 0% nor 100%, so the score leaves it out.
    func testHardwareRuleAtIgnoreOverTheWholeFleetDropsTheFileVaultMetric() throws {
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 2, "filevault_encrypted": 0, "sip_enabled": 2,
            "firewall_enabled": 1, "gatekeeper_enabled": 2,
        ]]
        let json = try JSONSerialization.data(withJSONObject: [summary,
            row("as-mac", serial: "AS1", fileVault: "UNENCRYPTED"),
            row("t2-mac", serial: "T21", fileVault: "UNENCRYPTED"),
        ])
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let fleet = try XCTUnwrap(SecurityFleetCounts.build(
            items: JSONDecoder().decode([SecurityReportItem].self, from: json),
            hardware: HardwareEncryption.index(computers: computers), policy: policy))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 2)
        XCTAssertNil(fleet.scoreInput().compliantCounts[.fileVault])
        let result = score(fleet, policy)
        XCTAssertEqual(result.available, [.sip, .firewall])
        XCTAssertTrue(result.missing.contains(.fileVault))
        // (100 + 50) / 2
        XCTAssertEqual(result.value, 75.0, accuracy: 0.001)
    }

    /// A typed hardware level stricter than FileVault's moves those Macs to fail, and the
    /// "more hardware-encrypted" count does not name them, since they are plain failures.
    func testHardwareRuleAtFailWithFileVaultAtWarningMovesThemToFail() throws {
        let policy = SecurityControlPolicy(
            fileVault: .warning, fileVaultOffHardwareEncrypted: .fail)
        let fleet = try hardwareCounts(policy)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .warning, on: 1, fail: 3, warning: 1))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 0)
        XCTAssertEqual(fleet.p0, 3)
        XCTAssertEqual(fleet.scoreInput().compliantCounts[.fileVault], 2)
        XCTAssertEqual(fleet.scoreInput().metricTotals, [:], "a share of the whole fleet")
    }

    func testFileVaultAtIgnoreWithTheRuleMovesNothing() throws {
        let policy = SecurityControlPolicy(
            fileVault: .ignore, fileVaultOffHardwareEncrypted: .warning)
        let fleet = try hardwareCounts(policy)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .ignore, on: 1, fail: 0, warning: 0))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 0)
        XCTAssertEqual(fleet.p0, 0)
    }

    /// Without the rule, or with a hardware level equal to FileVault's, rows move nothing.
    func testWithoutTheRuleRowsMoveNothing() throws {
        for policy in [SecurityControlPolicy.default,
                       SecurityControlPolicy(fileVaultOffHardwareEncrypted: .fail)] {
            let fleet = try hardwareCounts(policy)
            XCTAssertEqual(fleet.controls[.fileVault],
                           Control(level: .fail, on: 1, fail: 4, warning: 0))
            XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 0)
        }
    }

    /// The summary counts the fleet; rows only pick which of its off Macs move. Three rows
    /// qualify, but the summary says only two Macs have FileVault off.
    func testMovedMacsNeverExceedTheSummarysOffCount() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let fleet = try hardwareCounts(policy, fileVaultOn: 3)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .fail, on: 3, fail: 0, warning: 2))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 2)
    }

    // MARK: - The summary writer

    func testSummaryWriterFollowsTheWorkspacePolicy() throws {
        let config = try ConfigLoader.loadFromString("""
        security_policy:
          controls:
            sip: warning
            gatekeeper: ignore
        """)
        let summary = try writtenSummary(config: config)
        XCTAssertEqual(summary.actionItemsP0, 1 + 101)
        XCTAssertEqual(summary.actionItemsP1, 0)
        XCTAssertEqual(try XCTUnwrap(summary.securityScore), 66.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.sipPct), 1.0, accuracy: 0.05, "facts stay facts")

        let ignored = try writtenSummary(config: ConfigLoader.loadFromString(
            "security_policy:\n  controls:\n    firewall: ignore\n"))
        XCTAssertEqual(ignored.actionItemsP0, 1 + 100)
        // Firewall carries no weight: (99.01 + 0.99) / 2.
        XCTAssertEqual(try XCTUnwrap(ignored.securityScore), 50.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ignored.firewallPct), 0, accuracy: 0.001)
    }

    /// The writer reads the computers snapshot once, for the proxy and the counts alike.
    func testSummaryWriterMovesHardwareEncryptedMacs() throws {
        let config = try ConfigLoader.loadFromString(
            "security_policy:\n  filevault_off_hardware_encrypted: warning\n")
        let summary = try writtenSummary(
            config: config, security: hardwareFleetJSON(), computers: computers)
        XCTAssertEqual(summary.actionItemsP0, 1, "only the Intel Mac")
        // FileVault 4 of 5 compliant, SIP and Firewall 5 of 5: (80 + 100 + 100) / 3.
        XCTAssertEqual(try XCTUnwrap(summary.securityScore), 93.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.compliancePct), 80, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.fileVaultPct), 20, accuracy: 0.01)

        let ignored = try writtenSummary(
            config: ConfigLoader.loadFromString(
                "security_policy:\n  filevault_off_hardware_encrypted: ignore\n"),
            security: hardwareFleetJSON(), computers: computers)
        XCTAssertEqual(ignored.actionItemsP0, 1)
        // FileVault 1 of the 2 Macs left counted: (50 + 100 + 100) / 3.
        XCTAssertEqual(try XCTUnwrap(ignored.securityScore), 83.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ignored.fileVaultPct), 20, accuracy: 0.01, "the fact")
    }

    // MARK: - The Security Posture service

    func testPostureSnapshotCarriesThePolicyAndItsCounts() throws {
        let policy = SecurityControlPolicy(sip: .warning)
        let snapshot = try SecurityPostureService.load(
            from: securityFixture, policy: policy, hardware: [:])
        XCTAssertEqual(snapshot.policy, policy)
        XCTAssertEqual(snapshot.fleetCounts, try fixtureCounts(policy))
        XCTAssertEqual(snapshot.sipEnabled, 1, "the tile's value is the summary's count")
    }

    func testPostureLoadForAProfileUsesItsPolicyAndComputers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-fleet-profile-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "fleet-counts"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let dataDir = workspace.appendingPathComponent("jamf-cli-data")
        for kind in ["security", "computers"] {
            try FileManager.default.createDirectory(
                at: dataDir.appendingPathComponent(kind), withIntermediateDirectories: true)
        }
        try hardwareFleetJSON().write(
            to: dataDir.appendingPathComponent("security/security_20261001T090000.json"))
        try JSONSerialization.data(withJSONObject: computers).write(
            to: dataDir.appendingPathComponent("computers/computers_20261001T090000.json"))

        let without = SecurityPostureService.load(profile: profile)
        XCTAssertEqual(without.policy, .default)
        XCTAssertEqual(without.fleetCounts.p0, 4)

        try "security_policy:\n  filevault_off_hardware_encrypted: ignore\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let with = SecurityPostureService.load(profile: profile)
        XCTAssertEqual(with.policy, SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore))
        XCTAssertEqual(with.fleetCounts.p0, 1)
        XCTAssertEqual(with.fleetCounts.fileVaultOffHardwareEncrypted, 3)
    }
}
