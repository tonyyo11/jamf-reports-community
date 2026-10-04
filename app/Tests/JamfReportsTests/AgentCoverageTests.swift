import Foundation
import XCTest
@testable import JamfReports

/// Every configured security agent is read, not only the first: the daily summary records
/// each agent's coverage, the score counts the chosen EDR agent only, and the Overview and
/// Trends offer a metric per agent. Fleet, invented: ten Macs and three agents.
/// Falcon connected on 7 (3 report "error"), Scanner on all 10, Forwarder running on 4 and
/// stopped on 3 (3 Macs report nothing). Over the fleet: 70.0, 100.0 and 40.0.
@MainActor
final class AgentCoverageTests: XCTestCase {

    private var root: URL!
    /// Unique per test: the backfill remembers a decoded snapshot by profile, day and file name.
    private let profile = "agentcov-" + String(UUID().uuidString.lowercased().prefix(8))

    private static let agentsYAML = """
        security_agents:
          - name: Falcon
            column: Falcon State
            connected_value: connected
          - name: Scanner
            column: Scanner Status
            connected_value: Installed
          - name: Forwarder
            column: Forwarder Status
            connected_value: running
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-AgentCov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.scoreCardsKey)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private var workspace: URL { root.appendingPathComponent(profile, isDirectory: true) }
    private var dataDir: URL {
        workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
    }
    private var summariesDir: URL {
        workspace.appendingPathComponent("snapshots/summaries", isDirectory: true)
    }

    private func writeConfig(_ yaml: String = AgentCoverageTests.agentsYAML) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(yaml.utf8).write(to: workspace.appendingPathComponent("config.yaml"))
    }

    private func config() throws -> ReportConfig {
        try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
    }

    private func eaRows() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for index in 0..<10 {
            let mac = "mac-\(index)"
            rows.append(GoldenFleetWorkspace.eaRow(
                device: mac, ea: "Falcon State", value: index < 7 ? "connected" : "error"))
            rows.append(GoldenFleetWorkspace.eaRow(
                device: mac, ea: "Scanner Status", value: "Installed"))
            if index < 4 {
                rows.append(GoldenFleetWorkspace.eaRow(
                    device: mac, ea: "Forwarder Status", value: "running"))
            } else if index < 7 {
                rows.append(GoldenFleetWorkspace.eaRow(
                    device: mac, ea: "Forwarder Status", value: "stopped"))
            }
        }
        return rows
    }

    private func writeSecurity(at when: Date) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: when,
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 9, sip: 10, firewall: 8, gatekeeper: 10))
    }

    private func emit(_ yaml: String = AgentCoverageTests.agentsYAML) throws -> DailySummary {
        try writeConfig(yaml)
        let when = Date().addingTimeInterval(-3600)
        try writeSecurity(at: when)
        _ = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: when, rows: eaRows())
        let outDir = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        ReportEngine(config: try config(), dataDir: dataDir).emitSummaryJSON(summariesDir: outDir)
        return try XCTUnwrap(SummaryJSONParser.parseDirectory(outDir).first)
    }

    // MARK: - The summary records every agent

    func testTheSummaryRecordsEveryAgentOverTheFleet() throws {
        let summary = try emit()
        XCTAssertEqual(summary.securityAgentCoverage,
                       ["Falcon": 70.0, "Scanner": 100.0, "Forwarder": 40.0])
        XCTAssertEqual(summary.crowdstrikePct, 70.0, "the EDR agent, as before")
    }

    func testAnAgentNoMacReportsIsAbsentNotZero() throws {
        let yaml = Self.agentsYAML + """

              - name: Ghost
                column: Ghost Status
                connected_value: up
            """
        let summary = try emit(yaml)
        XCTAssertNil(summary.securityAgentCoverage?["Ghost"])
        XCTAssertEqual(summary.securityAgentCoverage?.count, 3)
    }

    // MARK: - Which agent is the EDR

    func testEDRAgentChoiceDrivesTheScoreAndCrowdstrikePct() throws {
        let first = try emit()
        let chosen = try emit(Self.agentsYAML + """

            security_policy:
              edr_agent: scanner
            """)
        XCTAssertEqual(first.crowdstrikePct, 70.0)
        XCTAssertEqual(chosen.crowdstrikePct, 100.0, "matched case-insensitively")
        // Same Macs, other EDR input: the score moves with the chosen agent only.
        XCTAssertGreaterThan(try XCTUnwrap(chosen.securityScore),
                             try XCTUnwrap(first.securityScore))
        XCTAssertEqual(chosen.securityAgentCoverage, first.securityAgentCoverage,
                       "every agent is still tracked")
    }

    func testANameThatMatchesNoAgentCountsTheFirst() throws {
        let summary = try emit(Self.agentsYAML + """

            security_policy:
              edr_agent: Nonesuch
            """)
        XCTAssertEqual(summary.crowdstrikePct, 70.0)
    }

    func testPolicyDecodesAndTrimsTheEDRAgent() throws {
        func policy(_ yaml: String) throws -> SecurityControlPolicy {
            try ConfigLoader.loadFromString(yaml).resolvedSecurityPolicy
        }
        XCTAssertEqual(try policy("security_policy:\n  edr_agent: \"  Scanner \"\n").edrAgent,
                       "Scanner")
        XCTAssertNil(try policy("security_policy:\n  edr_agent: \"\"\n").edrAgent)
        XCTAssertNil(try policy("security_policy:\n  controls:\n    sip: warning\n").edrAgent)
        XCTAssertNil(try policy("security_policy:\n  edr_agent: [a, b]\n").edrAgent)
    }

    func testTheKeyIsOneTheAppReads() throws {
        let yaml = "security_policy:\n  edr_agent: Falcon\n"
        let unknown = ConfigSchema.unknownKeys(in: try XCTUnwrap(
            try ConfigLoader.rawMapping(fromYAML: yaml)))
        XCTAssertTrue(unknown.isEmpty, "\(unknown)")
    }

    func testDoctorWarnsOnlyForANameThatMatchesNoAgent() throws {
        let agents = try XCTUnwrap(try config(forYAML: Self.agentsYAML).securityAgents)
        func rows(_ chosen: String?) -> [DoctorRow] {
            ConfigDoctorService.edrAgentRows(
                policy: SecurityControlPolicy(edrAgent: chosen), agents: agents)
        }
        XCTAssertTrue(rows(nil).isEmpty)
        XCTAssertTrue(rows("Scanner").isEmpty)
        XCTAssertTrue(rows(" scanner ").isEmpty)
        let warn = try XCTUnwrap(rows("Nonesuch").first)
        XCTAssertEqual(warn.severity, .warn)
        XCTAssertTrue(warn.detail.contains("\"Falcon\" counts as the EDR agent"), warn.detail)
        XCTAssertEqual(
            ConfigDoctorService.edrAgentRows(
                policy: SecurityControlPolicy(edrAgent: "X"), agents: []).count, 1)
    }

    private func config(forYAML yaml: String) throws -> ReportConfig {
        try ConfigLoader.loadFromString(yaml)
    }

    func testTheStoreFollowsThePolicyForItsEDRName() {
        let store = WorkspaceStore(demoMode: false)
        store.configState.securityAgents = [
            ConfigSecurityAgent(name: "Falcon", column: "a", connectedValue: "x"),
            ConfigSecurityAgent(name: "Scanner", column: "b", connectedValue: "x"),
            ConfigSecurityAgent(name: "Forwarder", column: "c", connectedValue: "x"),
        ]
        XCTAssertEqual(store.edrAgentName, "Falcon")
        store.securityPolicy.edrAgent = "scanner"
        XCTAssertEqual(store.edrAgentName, "Scanner")
        XCTAssertEqual(store.agentMetrics, [.agent("Falcon"), .agent("Forwarder")],
                       "the EDR agent is .edrAgent, not a second card")
        XCTAssertTrue(store.isOffered(.agent("Forwarder")))
        XCTAssertFalse(store.isOffered(.agent("Scanner")))
        XCTAssertFalse(store.isOffered(.agent("Gone")))
        XCTAssertEqual(store.availableMetrics.suffix(2), [.agent("Falcon"), .agent("Forwarder")])
        store.securityPolicy.edrAgent = "Nonesuch"
        XCTAssertEqual(store.edrAgentName, "Falcon")
    }

    // MARK: - The writer

    func testWriterSetsAndRemovesTheEDRAgentAndKeepsTheRestOfTheBlock() throws {
        try writeConfig(Self.agentsYAML + """

            security_policy:
              controls:
                sip: warning
            """)
        try SecurityPolicyConfigWriter.save(.edrAgent(" Scanner "), profile: profile)
        let text = try String(contentsOf: workspace.appendingPathComponent("config.yaml"))
        XCTAssertTrue(text.contains("edr_agent: Scanner"), text)
        XCTAssertTrue(text.contains("sip: warning"), text)
        let loaded = SecurityPolicyConfigLoader.load(profile: profile)
        XCTAssertEqual(loaded.edrAgent, "Scanner")
        XCTAssertEqual(loaded.sip, .warning)

        try SecurityPolicyConfigWriter.save(.edrAgent(nil), profile: profile)
        XCTAssertNil(SecurityPolicyConfigLoader.load(profile: profile).edrAgent)
        XCTAssertFalse(try String(contentsOf: workspace.appendingPathComponent("config.yaml"))
            .contains("edr_agent"))
    }

    func testANonTextEDRAgentIsReportedAndATextOneIsNot() throws {
        try writeConfig("security_policy:\n  edr_agent: [a, b]\n")
        let issues = SecurityPolicyConfigLoader.issues(profile: profile)
        XCTAssertEqual(issues.map(\.keyPath), [SecurityPolicyConfigLoader.edrAgentPath])
        XCTAssertEqual(issues.first?.used, "the first agent")
        try writeConfig("security_policy:\n  edr_agent: Scanner\n")
        XCTAssertTrue(SecurityPolicyConfigLoader.issues(profile: profile).isEmpty)
    }

    // MARK: - Metrics and persisted selections

    func testAgentMetricsKeepTheirNameInTheRawValue() {
        let metric = TrendSeries.Metric.agent("Nessus Agent, 10%")
        XCTAssertEqual(metric.rawValue, "agent:Nessus Agent%2C 10%25")
        XCTAssertEqual(TrendSeries.Metric(rawValue: metric.rawValue), metric)
        XCTAssertEqual(TrendSeries.Metric(rawValue: "agent:Splunk UF"), .agent("Splunk UF"))
        XCTAssertNil(TrendSeries.Metric(rawValue: "agent:"))
        XCTAssertNil(TrendSeries.Metric(rawValue: "agent:   "))
        XCTAssertNil(TrendSeries.Metric(rawValue: "bogus"))
        XCTAssertFalse(TrendSeries.Metric.allCases.contains(.agent("x")))
    }

    func testPersistedSelectionKeepsAgentCardsAndDropsUnknownKeys() {
        WorkspaceStore.persistScoreCards(
            [.stability, .agent("Nessus Agent, 10%"), .edrAgent, .agent("Splunk UF")])
        XCTAssertEqual(
            WorkspaceStore.loadPersistedScoreCards(),
            [.stability, .agent("Nessus Agent, 10%"), .edrAgent, .agent("Splunk UF")])
        UserDefaults.standard.set(
            "stability,from-a-future-build,agent:Splunk UF", forKey: WorkspaceStore.scoreCardsKey)
        XCTAssertEqual(WorkspaceStore.loadPersistedScoreCards(),
                       [.stability, .agent("Splunk UF")])
    }

    func testCustomizeRowsListOfferedAgentsAndHideOtherAgentKeys() {
        let rows = OverviewCustomizeSheet.scoreCardRows(
            selected: [.agent("Splunk UF"), .agent("Removed"), .stability],
            policy: .default, agents: [.agent("Nessus"), .agent("Splunk UF")])
        XCTAssertEqual(rows.prefix(2), [.agent("Splunk UF"), .stability])
        XCTAssertTrue(rows.contains(.agent("Nessus")))
        XCTAssertFalse(rows.contains(.agent("Removed")), "kept in the selection, not listed")
    }

    func testLabelsSayCoverageNotInstalled() {
        XCTAssertEqual(
            TrendSeries.Metric.agent("Nessus").displayLabel(
                benchmarkLabel: nil, edrAgentName: "Falcon"), "Nessus coverage")
        XCTAssertEqual(
            TrendSeries.Metric.edrAgent.displayLabel(
                benchmarkLabel: nil, edrAgentName: "Falcon"), "Falcon coverage")
        XCTAssertEqual(TrendSeries.Metric.agent("Nessus").unit, "%")
        XCTAssertEqual(TrendSeries.Metric.agent("Nessus").colorHex,
                       TrendSeries.Metric.agent("Nessus").colorHex, "stable per name")
    }

    func testTheTrendStoreReadsEachAgentFromTheSummary() {
        let day = DailySummary(
            date: "2026-10-04", totalDevices: 10, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: 70, patchPct: nil,
            source: "jamf-cli", securityAgentCoverage: ["Scanner": 100, "Forwarder": 40])
        let store = TrendStore(summaries: [day], range: .all)
        XCTAssertEqual(store.values(metric: .agent("Scanner")), [100])
        XCTAssertEqual(store.values(metric: .agent("Forwarder")), [40])
        XCTAssertEqual(store.values(metric: .edrAgent), [70])
        XCTAssertEqual(store.values(metric: .agent("Absent")), [])
    }

    // MARK: - Same-day rebuild keeps agents a run could not read

    func testARebuildKeepsAnAgentTheRunSkipped() {
        func summary(_ coverage: [String: Double]?) -> DailySummary {
            DailySummary(
                date: "2026-10-04", totalDevices: 10, fileVaultPct: nil, compliancePct: nil,
                staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                source: "jamf-cli", securityAgentCoverage: coverage)
        }
        let morning = summary(["Falcon": 70, "Scanner": 100])
        XCTAssertEqual(summary(nil).filling(from: morning).securityAgentCoverage,
                       ["Falcon": 70, "Scanner": 100])
        XCTAssertEqual(summary(["Falcon": 75]).filling(from: morning).securityAgentCoverage,
                       ["Falcon": 75, "Scanner": 100], "this run's reading wins")
    }

    // MARK: - History from dated ea-results snapshots

    private func writeSummary(_ date: String, coverage: [String: Double]? = nil) throws {
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        var payload: [String: Any] = [
            "date": date, "totalDevices": 10, "source": "jamf-cli", "patchPct": 50.0,
        ]
        if let coverage { payload["securityAgentCoverage"] = coverage }
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: summariesDir.appendingPathComponent("summary_\(date).json"))
    }

    private func day(_ offset: Int, hour: Int = 9) -> Date {
        GoldenFleetClock.timestamp(
            dayOffset: offset, hour: hour, minute: 0, relativeTo: GoldenFleetClock.anchorNoon())
    }

    private func dayString(_ offset: Int) -> String {
        GoldenFleetClock.daySummaryString(day(offset))
    }

    func testOlderDaysGetAgentHistoryFromTheirOwnSnapshot() throws {
        try writeConfig()
        try writeSummary(dayString(-3))
        try writeSummary(dayString(-2), coverage: ["Falcon": 11])
        for offset in [-3, -2] {
            _ = try GoldenFleetWorkspace.writeEAResults(
                dataDir: dataDir, at: day(offset), rows: eaRows())
        }

        let resolved = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)

        let backfilled = try XCTUnwrap(resolved.first { $0.date == dayString(-3) })
        XCTAssertEqual(backfilled.securityAgentCoverage,
                       ["Falcon": 70.0, "Scanner": 100.0, "Forwarder": 40.0])
        XCTAssertEqual(backfilled.crowdstrikePct, 70.0, "the EDR agent's history too")
        let recorded = try XCTUnwrap(resolved.first { $0.date == dayString(-2) })
        XCTAssertEqual(recorded.securityAgentCoverage, ["Falcon": 11],
                       "a day the app recorded is left alone")
    }

    func testTheNewestSnapshotOfTheDayIsUsedAndConflictCopiesAreNot() throws {
        try writeConfig()
        try writeSummary(dayString(-1))
        var morning = eaRows()
        morning.append(
            GoldenFleetWorkspace.eaRow(device: "mac-x", ea: "Falcon State", value: "connected"))
        _ = try GoldenFleetWorkspace.writeEAResults(
            dataDir: dataDir, at: day(-1, hour: 6), rows: morning)
        _ = try GoldenFleetWorkspace.writeEAResults(
            dataDir: dataDir, at: day(-1, hour: 18), rows: eaRows())
        let evening = "ea-results_\(GoldenFleetClock.stamp(day(-1, hour: 18))) 2.json"
        try GoldenFleetWorkspace.writeJSON(
            [GoldenFleetWorkspace.eaRow(device: "m", ea: "Falcon State", value: "connected")],
            to: dataDir.appendingPathComponent("ea-results").appendingPathComponent(evening))

        let resolved = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        XCTAssertEqual(resolved.first?.securityAgentCoverage?["Falcon"], 70.0)
    }

    func testNothingIsReadWithoutAgentsOrWhenNothingIsMissing() throws {
        try writeConfig("columns:\n  computer_name: Computer Name\n")
        try writeSummary(dayString(-1))
        _ = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: day(-1), rows: eaRows())
        var resolved = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        XCTAssertNil(resolved.first?.securityAgentCoverage, "no agents configured")

        try writeConfig()
        try writeSummary(dayString(-1), coverage: ["Falcon": 1])
        // Garbage under the day's name would trip a read: none happens.
        let garbage = "ea-results_\(GoldenFleetClock.stamp(day(-1, hour: 20))).json"
        try Data("not json".utf8).write(
            to: dataDir.appendingPathComponent("ea-results").appendingPathComponent(garbage))
        resolved = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        XCTAssertEqual(resolved.first?.securityAgentCoverage, ["Falcon": 1])
    }

    func testOnlyTheNewestDaysAreRead() throws {
        try writeConfig()
        let days = TrendStore.agentBackfillMaxDays + 3
        for offset in 1...days {
            try writeSummary(dayString(-offset))
            _ = try GoldenFleetWorkspace.writeEAResults(
                dataDir: dataDir, at: day(-offset), rows: eaRows())
        }
        let resolved = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        let filled = resolved.filter { $0.securityAgentCoverage != nil }
        XCTAssertEqual(filled.count, TrendStore.agentBackfillMaxDays)
        XCTAssertEqual(Set(filled.map(\.date)),
                       Set((1...TrendStore.agentBackfillMaxDays).map { dayString(-$0) }),
                       "the newest days")
    }

    func testASnapshotIsDecodedOncePerSession() throws {
        try writeConfig()
        try writeSummary(dayString(-1))
        let url = try GoldenFleetWorkspace.writeEAResults(
            dataDir: dataDir, at: day(-1), rows: eaRows())
        let first = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        XCTAssertEqual(first.first?.securityAgentCoverage?["Falcon"], 70.0)

        // The same file name is not decoded again, whatever it holds now.
        try Data("not json".utf8).write(to: url)
        let second = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        XCTAssertEqual(second.first?.securityAgentCoverage?["Falcon"], 70.0)
    }

    func testATruncatedSnapshotIsNotUsed() throws {
        try writeConfig()
        try writeSummary(dayString(-1))
        try GoldenFleetWorkspace.writeTruncatedEAResults(
            dataDir: dataDir, at: day(-1), column: "Falcon State", completeObjects: 5)
        let resolved = TrendStore.resolvingAgentCoverage(
            TrendStore.readSummaries(profile: profile), profile: profile)
        XCTAssertNil(resolved.first?.securityAgentCoverage,
                     "a partial row set would understate coverage")
    }

    func testTheSecondPhaseRepublishesTheStoreWithHistory() async throws {
        try writeConfig()
        try writeSummary(dayString(-1))
        _ = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: day(-1), rows: eaRows())
        let store = TrendStore()
        let generation = store.beginLoading()
        store.apply(
            TrendStore.computeSnapshot(profile: profile), profile: profile, range: .all,
            generation: generation)
        XCTAssertEqual(store.values(metric: .agent("Scanner")), [])

        await store.backfillAgentCoverage(profile: profile)

        XCTAssertEqual(store.values(metric: .agent("Scanner")), [100.0])
        XCTAssertEqual(store.values(metric: .edrAgent), [70.0])
    }
}
