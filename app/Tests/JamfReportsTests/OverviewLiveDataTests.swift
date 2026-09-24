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
        let row = RecentDeviceRow(record: mac, failedRules: nil)

        XCTAssertNil(row.department)
        XCTAssertNil(row.fileVault, "No FileVault value is not a failed check")
        XCTAssertEqual(row.user, "jdoe")
        XCTAssertEqual(row.lastSeen, "1 day")

        mac.email = "jdoe@example.org"
        mac.fileVault = "ENCRYPTED"
        let withEmail = RecentDeviceRow(record: mac, failedRules: 0)
        XCTAssertEqual(withEmail.user, "jdoe@example.org")
        XCTAssertEqual(withEmail.fileVault, true)
    }
}
