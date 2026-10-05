import Foundation
import XCTest
@testable import JamfReports

final class OverviewLiveDataTests: XCTestCase {

    // MARK: - macOS distribution

    func testOSDistributionRanksVersionsAndRollsUpTheTail() {
        let built = OverviewLiveDataLoader.osDistribution(
            counts: ["15.7.10": 50, "15.7.2": 30, "14.7.6": 12, "13.7.8": 5, "12.7.6": 3],
            latestByMajor: [15: "15.7.10", 14: "14.7.6"],
            limit: 3
        )

        XCTAssertEqual(built.total, 100)
        XCTAssertEqual(built.versions, 5)
        XCTAssertEqual(built.rows.map(\.version),
                       ["macOS 15.7.10", "macOS 15.7.2", "Other (3 versions)"])
        XCTAssertEqual(built.rows.map(\.count), [50, 30, 20])
        XCTAssertEqual(built.rows.map(\.current), [true, false, false])
        // 15.7.10 and 14.7.6 are current: 62 of 100.
        XCTAssertEqual(built.currentShare, 62.0)
    }

    func testOSDistributionCannotJudgeCurrencyWithoutAFeed() {
        let built = OverviewLiveDataLoader.osDistribution(
            counts: ["15.7.10": 3, "": 4, "14.1": 0], latestByMajor: [:], limit: 6)

        XCTAssertNil(built.currentShare, "No SOFA feed means unknown, not 0% current")
        XCTAssertEqual(built.total, 3, "Blank versions and zero counts are dropped")
        XCTAssertEqual(built.rows.map(\.current), [false])
    }

    // MARK: - Failing rules

    private func eaRows(_ json: String) throws -> [EAResultRow] {
        try XCTUnwrap(EAResultRow.decodeSnapshot(Data(json.utf8)).rows)
    }

    func testFailingRulesCountEachRuleOncePerMac() throws {
        let rows = try eaRows("""
        [
          {"device": "mac-1", "ea_name": "mSCP Failed Rules", "value": "rule_b | rule_a|rule_a"},
          {"device": "mac-2", "ea_name": "mscp failed rules", "value": "rule_a"},
          {"device": "mac-3", "ea_name": "mSCP Failed Rules", "value": ""},
          {"device": "mac-4", "ea_name": "Other", "value": "rule_z"}
        ]
        """)

        let built = OverviewLiveDataLoader.failingRules(
            rows: rows, listColumn: "mSCP Failed Rules", baseline: "CIS Level 1")

        XCTAssertEqual(built.rules.map(\.ruleID), ["rule_a", "rule_b"])
        XCTAssertEqual(built.rules.map(\.fails), [2, 1])
        XCTAssertEqual(built.reportingMacs, 3, "A Mac with an empty list still reports")
        XCTAssertEqual(Set(built.rules.map(\.baseline)), ["CIS Level 1"])
    }

    /// Prod's list EA is newline-separated, and Macs with no scored baseline carry a status
    /// in place of a list. Both were ranked as rules: two IDs read as one rule, and "No
    /// Baseline Set" as the most-failed rule.
    func testFailingRulesSplitNewlinesAndIgnoreStatusValues() throws {
        let rows = try eaRows("""
        [
          {"device": "mac-1", "ea_name": "mSCP Failed Rules", "value": "rule_a\\nrule_b"},
          {"device": "mac-2", "ea_name": "mSCP Failed Rules", "value": "rule_a\\nrule_c\\n"},
          {"device": "mac-3", "ea_name": "mSCP Failed Rules", "value": "No Baseline Set"},
          {"device": "mac-4", "ea_name": "mSCP Failed Rules", "value": "Multiple Baselines Found"},
          {"device": "mac-5", "ea_name": "mSCP Failed Rules", "value": ""}
        ]
        """)

        let built = OverviewLiveDataLoader.failingRules(
            rows: rows, listColumn: "mSCP Failed Rules", baseline: "Baseline")

        XCTAssertEqual(built.rules.map(\.ruleID), ["rule_a", "rule_b", "rule_c"])
        XCTAssertEqual(built.rules.map(\.fails), [2, 1, 1])
        XCTAssertEqual(built.reportingMacs, 3, "Macs with a status were not evaluated")
    }

    func testBenchmarkRulesUseTheFirstBenchmarkAndSkipUnevaluatedRules() {
        typealias Rule = ComplianceBenchmarksService.Snapshot.Rule
        let snapshot = ComplianceBenchmarksService.Snapshot(
            rules: [
                Rule(rule: "Audit logging", passed: 5, failed: 7, unknown: 0, devices: 12,
                     passRate: "41%", benchmark: "CIS Level 1"),
                Rule(rule: "Firewall", passed: 12, failed: 0, unknown: 0, devices: 12,
                     passRate: "100%", benchmark: "CIS Level 1"),
                Rule(rule: "Screen lock", passed: 0, failed: nil, unknown: 12, devices: 12,
                     passRate: "0%", benchmark: "CIS Level 1"),
                Rule(rule: "Audit logging", passed: 1, failed: 11, unknown: 0, devices: 12,
                     passRate: "8%", benchmark: "NIST 800-53"),
            ],
            devices: [], rulesSourceFile: nil, devicesSourceFile: nil, snapshotDate: nil
        )

        let built = OverviewLiveDataLoader.failingRules(benchmarks: snapshot)

        XCTAssertEqual(built.label, "CIS Level 1")
        XCTAssertEqual(built.rules.map(\.ruleID), ["Audit logging"])
        XCTAssertEqual(built.rules.map(\.fails), [7], "Never summed across benchmarks")
        XCTAssertEqual(built.reportingMacs, 12, "the Macs the first benchmark evaluated")
    }

    // MARK: - Loading a workspace

    /// A workspace under a temporary root holding `config` and one ea-results snapshot.
    private func workspace(profile: String, config: String, eaResults: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverviewLiveData-\(UUID().uuidString)", isDirectory: true)
        let eaDir = root.appendingPathComponent("\(profile)/jamf-cli-data/ea-results",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: root.appendingPathComponent("\(profile)/config.yaml"))
        try Data(eaResults.utf8).write(
            to: eaDir.appendingPathComponent("ea-results_20260930T120000.json"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Two Macs that share a name are two Macs, and the card's share is of the whole
    /// fleet, as the daily summary's EDR figure is: a Mac with no value is not connected.
    func testAgentCardsCountRepeatedNamesAndShareTheFleet() async throws {
        try workspace(profile: "acme", config: """
            security_agents:
              - name: "CrowdStrike Falcon"
                column: "Falcon - Status"
                connected_value: "Running"
            """, eaResults: """
            [
              {"definition_id": "4", "device": "MacBook Pro",
               "ea_name": "Falcon - Status", "value": "Running"},
              {"definition_id": "4", "device": "MacBook Pro",
               "ea_name": "Falcon - Status", "value": "Running"},
              {"definition_id": "4", "device": "mac-3",
               "ea_name": "Falcon - Status", "value": "Stopped"},
              {"definition_id": "4", "device": "mac-4", "ea_name": "Falcon - Status", "value": ""}
            ]
            """)

        let data = try await OverviewLiveDataLoader.load(
            profile: "acme", sections: [.securityAgents])

        XCTAssertEqual(data.agents.map(\.installed), [2])
        XCTAssertEqual(OverviewLiveDataLoader.agents(data.agents, overFleet: 4).map(\.pct), [50])
        XCTAssertEqual(OverviewLiveDataLoader.agents(data.agents, overFleet: 0).map(\.pct),
                       data.agents.map(\.pct), "an unknown fleet leaves the loader's share")
    }

    /// "Across N active devices" printed the security report's device count, not the Macs
    /// whose failures list the card counted.
    func testFailingRulesCarryTheMacsTheyCounted() async throws {
        try workspace(profile: "acme", config: """
            compliance:
              failures_count_column: "mSCP Failed Count"
              failures_list_column: "mSCP Failed Rules"
              baseline_label: "CIS Level 1"
            """, eaResults: """
            [
              {"definition_id": "9", "device": "mac-1", "ea_name": "mSCP Failed Rules",
               "value": "rule_a|rule_b"},
              {"definition_id": "9", "device": "mac-2", "ea_name": "mSCP Failed Rules",
               "value": "rule_a"},
              {"definition_id": "9", "device": "mac-3", "ea_name": "mSCP Failed Rules",
               "value": ""},
              {"definition_id": "3", "device": "mac-4", "ea_name": "Other", "value": "x"}
            ]
            """)

        let data = try await OverviewLiveDataLoader.load(
            profile: "acme", sections: [.topFailingRules])

        XCTAssertEqual(data.failingRules.map(\.ruleID), ["rule_a", "rule_b"])
        XCTAssertEqual(data.failingRulesReportingMacs, 3)
    }

    /// The Overview's `.task` is cancelled when the profile or the visible sections change;
    /// a load it started must stop rather than paint the old selection's data.
    func testACancelledLoadThrowsRatherThanReturningData() async throws {
        try workspace(profile: "acme", config: """
            security_agents:
              - name: "CrowdStrike Falcon"
                column: "Falcon - Status"
            """, eaResults: """
            [{"definition_id": "4", "device": "mac-1", "ea_name": "Falcon - Status",
              "value": "Running"}]
            """)
        let load = Task { () async throws -> OverviewLiveData in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OverviewLiveDataLoader.load(
                profile: "acme", sections: [.securityAgents, .recentActivity])
        }

        do {
            _ = try await load.value
            XCTFail("a cancelled load returned data")
        } catch is CancellationError {}
    }

    // MARK: - Recent activity

    private func record(
        _ name: String, days: Int?, lastContact: String = "", source: String = "computers.json"
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: name, source: source)
        record.name = name
        record.serial = "S-\(name)"
        record.daysSinceContact = days
        record.lastContact = lastContact
        return record
    }

    func testRecentDevicesOrderByDaysThenTimestampThenName() {
        let records = [
            record("old", days: 12),
            record("unknown", days: nil),
            record("today-early", days: 0, lastContact: "2026-09-24T08:00:00Z"),
            record("today-late", days: 0, lastContact: "2026-09-24T09:30:00.250Z"),
            record("today-undated-b", days: 0),
            record("today-undated-a", days: 0),
        ]

        let recent = OverviewLiveDataLoader.recentDevices(records, limit: 5)

        XCTAssertEqual(recent.map(\.name), [
            "today-late", "today-early", "today-undated-a", "today-undated-b", "old",
        ])
    }

    func testFailedRulesComeFromTheExtensionAttributeFirst() {
        var mac = record("mac-1", days: 0, source: "export.csv + computers.json")
        mac.failedRules = 4
        let counts = OverviewLiveDataLoader.failureCounts(
            rows: (try? eaRows(#"[{"device": "MAC-1", "ea_name": "Failed Count", "value": 9}]"#))
                ?? [],
            countColumn: "failed count")

        XCTAssertEqual(OverviewLiveDataLoader.failedRules(
            for: mac, eaCounts: counts, baselineConfigured: true), 9)
        XCTAssertEqual(OverviewLiveDataLoader.failedRules(
            for: mac, eaCounts: [:], baselineConfigured: true), 4, "CSV count as fallback")
        XCTAssertNil(OverviewLiveDataLoader.failedRules(
            for: mac, eaCounts: [:], baselineConfigured: false),
                     "Without a compliance column every CSV row reads 0; that is not a pass")
        XCTAssertNil(OverviewLiveDataLoader.failedRules(
            for: record("jamf-only", days: 0), eaCounts: [:], baselineConfigured: true))
    }

    func testRecentRowShowsUnknownsAsUnknown() {
        var mac = record("mac-1", days: 1)
        mac.user = "jdoe"
        let row = RecentDeviceRow(record: mac, failedRules: nil, policy: .default)

        XCTAssertNil(row.department)
        XCTAssertNil(row.fileVault, "No FileVault value is not a failed check")
        XCTAssertEqual(row.user, "jdoe")
        XCTAssertEqual(row.lastSeen, "1 day")

        mac.email = "jdoe@example.org"
        mac.fileVault = "ENCRYPTED"
        let withEmail = RecentDeviceRow(record: mac, failedRules: 0, policy: .default)
        XCTAssertEqual(withEmail.user, "jdoe@example.org")
        XCTAssertEqual(withEmail.fileVault, true)
    }

    func testRecentRowReadsFileVaultByTheWorkspaceVocabulary() {
        var mac = record("mac-1", days: 1)
        mac.fileVault = "Wrapped"
        let words = SecurityControlPolicy(
            onValues: [.fileVault: ["Wrapped"]], offValues: [.fileVault: ["Bare"]])
        func shown(_ policy: SecurityControlPolicy) -> Bool? {
            RecentDeviceRow(record: mac, failedRules: nil, policy: policy).fileVault
        }
        XCTAssertEqual(shown(words), true)
        XCTAssertNil(shown(.default))
        mac.fileVault = "Bare"
        XCTAssertEqual(shown(words), false)
    }

    /// jamf-cli fills `fileVault` from `partitionFileVault2State`. A Mac still encrypting, or
    /// one Jamf could not read, showed a red "FileVault off" here while Devices showed it as
    /// unknown.
    func testRecentRowReadsFileVaultStatesLikeTheDevicesTable() {
        var mac = record("mac-1", days: 1)
        let cases: [(String, Bool?)] = [
            ("ENCRYPTED", true), ("NOT_ENCRYPTED", false), ("DECRYPTING", false),
            ("ENCRYPTING", nil), ("UNKNOWN", nil), ("INELIGIBLE", nil), ("RESTART_NEEDED", nil),
        ]
        for (state, expected) in cases {
            mac.fileVault = state
            let row = RecentDeviceRow(record: mac, failedRules: nil, policy: .default)
            XCTAssertEqual(row.fileVault, expected, state)
        }
    }
}
