import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 H1: the stored Security Score counts every factor the run has data for, through
/// the one function the daily summary, the Security Posture screen and the workbook share.
///
/// Fleet, invented and worked by hand: ten Macs. FileVault on 9, SIP on 10, Firewall on 8,
/// Gatekeeper on 9; the EDR agent connected on 7 (3 report "error"); the primary mSCP baseline
/// has a valid count for all ten, zero failures on 6. The workspace configures one agent and
/// one baseline, so the default factors are the ten native ones, mSCP at 10 and the agent at 5.
/// Only the security report and ea-results are collected, so the shares are 90, 100, 80 and 90
/// for the controls, 60 for mSCP and 70 for the agent:
/// (90 x 15 + 100 x 10 + 80 x 10 + 90 x 5 + 60 x 10 + 70 x 5) / 55 = 4550 / 55 = 82.7.
/// Without the agent and mSCP it is (1350 + 1000 + 800 + 450) / 40 = 90.0.
@MainActor
final class SecurityScoreInputsTests: XCTestCase {

    private nonisolated(unsafe) var root: URL!
    private let profile = "scoreinputs"

    private static let yaml = """
        security_agents:
          - name: Falcon
            column: Falcon State
            connected_value: connected
        compliance:
          enabled: true
          baselines:
            - name: Baseline A
              failures_count_column: Count A
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-ScoreInputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private var workspace: URL { root.appendingPathComponent(profile, isDirectory: true) }
    private var dataDir: URL {
        workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
    }

    private func writeWorkspace(
        config: String = SecurityScoreInputsTests.yaml, withEAResults: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: workspace.appendingPathComponent("config.yaml"))
        let when = Date().addingTimeInterval(-3600)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: when,
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 9, sip: 10, firewall: 8, gatekeeper: 9))
        guard withEAResults else { return }
        var rows: [[String: Any]] = []
        for index in 0..<10 {
            let device = "mac-\(index)"
            rows.append(GoldenFleetWorkspace.eaRow(
                device: device, ea: "Falcon State", value: index < 7 ? "connected" : "error"))
            rows.append(GoldenFleetWorkspace.eaRow(
                device: device, ea: "Count A", value: index < 6 ? 0 : 5))
        }
        _ = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: when, rows: rows)
    }

    /// Four Macs in the `computers` snapshot, a SOFA feed whose releases are all long past
    /// their grace period, patch-status and device-compliance, so every default factor has data.
    private func writeNativeSnapshots() throws {
        let when = Date().addingTimeInterval(-3600)
        func mac(_ secureBoot: String, _ xprotect: String, _ os: String) -> [String: Any] {
            ["security": ["secureBootLevel": secureBoot, "xprotectVersion": xprotect,
                          "bootstrapTokenEscrowedStatus": "ESCROWED"],
             "operatingSystem": ["version": os]]
        }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: when, rows: [
                mac("FULL_SECURITY", "5363", "26.7.1"), mac("FULL_SECURITY", "5363", "26.7.1"),
                mac("MEDIUM_SECURITY", "5000", "26.7"), mac("NOT_SUPPORTED", "5363", "26.7.1"),
            ])
        try GoldenFleetWorkspace.writeRaw("""
            {"OSVersions": [{"Latest": {"ProductVersion": "26.7.1", "ReleaseDate": "2025-03-01"},
                             "SecurityReleases": [{"ProductVersion": "26.7",
                                                   "ReleaseDate": "2025-02-01"}]}],
             "XProtectPlistConfigData": {"com.apple.XProtect": "5363",
                                         "ReleaseDate": "2025-03-02"}}
            """, to: dataDir.appendingPathComponent("sofa/macos_data_feed.json"))
        try GoldenFleetWorkspace.writePatchStatus(
            dataDir: dataDir, at: when,
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "T", onLatest: 800, total: 1000)])
        let devices = (0..<10).map { index -> [String: Any] in
            ["name": "mac-\(index)", "days_since_contact": index < 7 ? "5" : "100"]
        }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "device-compliance", dataDir: dataDir, at: when, rows: devices)
    }

    private func load() throws -> ReportConfig {
        try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
    }

    private func fleetCounts() throws -> SecurityFleetCounts {
        let url = try XCTUnwrap(FileManager.newestJSONFile(
            in: dataDir.appendingPathComponent("security", isDirectory: true)))
        let items = try JSONDecoder().decode(
            [SecurityReportItem].self, from: Data(contentsOf: url))
        return try XCTUnwrap(SecurityFleetCounts.build(
            items: items, hardware: [:], policy: .default))
    }

    private func score(_ config: ReportConfig) throws -> SecurityScore {
        let factors = config.resolvedScoreFactors
        let measures = SecurityScoreInputs.measures(
            for: factors, fleet: try fleetCounts(),
            sources: SecurityScoreInputs.load(dataDir: dataDir, factors: factors),
            config: config)
        return SecurityScoreCalculator.score(factors: factors, measures: measures)
    }

    // MARK: - The factors

    func testEveryFactorWithDataIsWeighed() throws {
        try writeWorkspace()
        let result = try score(try load())

        XCTAssertEqual(result.value, 82.7, accuracy: 0.0001)
        XCTAssertEqual(result.available.map(\.id), [
            "filevault", "sip", "firewall", "gatekeeper", "mscp", "agent:Falcon",
        ])
        XCTAssertEqual(result.missing.map(\.id), [
            "secure_boot", "bootstrap_token", "os_current", "xprotect_current",
            "patch_compliance", "checked_in",
        ], "nothing was collected for these, so their weights drop out")
        XCTAssertEqual(
            result.basis,
            "filevault=15,sip=10,firewall=10,gatekeeper=5,mscp=10,agent:Falcon=5")
    }

    func testWithoutEAResultsTheScoreIsTheFourControlsAlone() throws {
        try writeWorkspace(withEAResults: false)
        let result = try score(try load())
        XCTAssertEqual(result.value, 90.0, accuracy: 0.0001)
        XCTAssertEqual(result.basis, "filevault=15,sip=10,firewall=10,gatekeeper=5")
    }

    /// The four-control proxy is never scored as mSCP: it is FileVault, SIP, Firewall and
    /// Gatekeeper again, so weighing it would count those controls twice. With no baseline the
    /// mSCP default is not added, and a listed mSCP factor has nothing to score.
    func testWithoutBaselinesNoMSCPInputIsInvented() throws {
        let noBaselines = """
            security_agents:
              - name: Falcon
                column: Falcon State
                connected_value: connected
            """
        try writeWorkspace(config: noBaselines)
        let result = try score(try load())
        XCTAssertFalse(result.available.contains { $0.kind == .mscp })
        XCTAssertFalse(result.missing.contains { $0.kind == .mscp })
        // (1350 + 1000 + 800 + 450 + 70 x 5) / 45 = 3950 / 45 = 87.8
        XCTAssertEqual(result.value, 87.8, accuracy: 0.0001)

        try writeWorkspace(config: noBaselines + """

            security_policy:
              score_factors:
                - {factor: sip, weight: 10}
                - {factor: mscp, weight: 10}
            """)
        let listed = try score(try load())
        XCTAssertEqual(listed.available.map(\.id), ["sip"])
        XCTAssertEqual(listed.value, 100.0, accuracy: 0.0001)
    }

    func testAnAgentNoMacReportsIsMissingNotZero() throws {
        try writeWorkspace(config: Self.yaml.replacingOccurrences(
            of: "Falcon State", with: "Some Other EA"))
        let result = try score(try load())
        XCTAssertTrue(result.missing.contains { $0.id == "agent:Falcon" })
        XCTAssertFalse(result.available.contains { $0.kind == .agent })
    }

    func testNoEAResultsLeavesBothEAFactorsWithoutData() throws {
        try writeWorkspace(withEAResults: false)
        let config = try load()
        let factors = config.resolvedScoreFactors
        let sources = SecurityScoreInputs.load(dataDir: dataDir, factors: factors)
        XCTAssertNil(sources.eaRows)
        let measures = SecurityScoreInputs.measures(
            for: factors, fleet: try fleetCounts(), sources: sources, config: config)
        XCTAssertNil(measures["mscp"])
        XCTAssertNil(measures["agent:falcon"])
    }

    /// `load` reads only the snapshots the listed factors need.
    func testLoadReadsOnlyWhatTheFactorsNeed() throws {
        try writeWorkspace()
        try writeNativeSnapshots()
        let controls = SecurityScoreInputs.load(
            dataDir: dataDir, factors: [SecurityScoreFactor(.sip, weight: 1)])
        XCTAssertNil(controls.computers)
        XCTAssertNil(controls.sofa)
        XCTAssertNil(controls.patchRows)
        XCTAssertNil(controls.complianceRows)
        XCTAssertNil(controls.eaRows)

        let osOnly = SecurityScoreInputs.load(
            dataDir: dataDir, factors: [SecurityScoreFactor(.osCurrent, weight: 1)])
        XCTAssertEqual(osOnly.computers?.count, 4)
        XCTAssertNotNil(osOnly.sofa)
        XCTAssertNil(osOnly.patchRows)

        let all = SecurityScoreInputs.load(
            dataDir: dataDir, factors: SecurityScoreFactor.nativeDefaults
                + [SecurityScoreFactor(.agent, weight: 1, target: "Falcon")])
        XCTAssertEqual(all.patchRows?.count, 1)
        XCTAssertEqual(all.complianceRows?.count, 10)
        XCTAssertEqual(all.eaRows?.count, 20)
    }

    // MARK: - Every native factor

    /// All twelve default factors with data. The shares: the controls 90, 100, 80, 90; Secure
    /// Boot 2 of the 3 Macs that report a level; bootstrap token 4 of 4; macOS 3 of 4 on the
    /// release required after a 30-day grace; XProtect 3 of 4; patch 800 of 1000; checked in 7
    /// of 10; mSCP 60; Falcon 70. 1350 + 1000 + 800 + 450 + 333.3 + 500 + 1125 + 375 + 800
    /// + 350 + 600 + 350 = 8033.3 over 100 weight is 80.3.
    func testEveryDefaultFactorMeasuredScoresOverTheirTotalWeight() throws {
        try writeWorkspace()
        try writeNativeSnapshots()
        let result = try score(try load())

        XCTAssertEqual(result.value, 80.3, accuracy: 0.0001)
        XCTAssertEqual(result.available.count, 12)
        XCTAssertTrue(result.missing.isEmpty)
        let shares = Dictionary(uniqueKeysWithValues: result.parts.map { ($0.factor.id, $0.share) })
        XCTAssertEqual(try XCTUnwrap(shares["secure_boot"]), 200.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(shares["bootstrap_token"], 100)
        XCTAssertEqual(shares["os_current"], 75)
        XCTAssertEqual(shares["xprotect_current"], 75)
        XCTAssertEqual(shares["patch_compliance"], 80)
        XCTAssertEqual(shares["checked_in"], 70)
    }

    // MARK: - One fleet, one score

    /// The summary writer, the Security Posture screen and the workbook's Executive Summary
    /// read the same snapshots and return the same score, and the summary records its basis,
    /// the EDR figure and the mSCP pass share the score used.
    func testEverySurfaceScoresTheFleetTheSame() throws {
        try writeWorkspace()
        let config = try load()

        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)

        let posture = SecurityPostureService.load(profile: profile)
        let screen = SecurityPostureView.score(posture)
        let workbook = CoreDashboard.executiveMetrics(config: config, dataDir: dataDir)

        XCTAssertEqual(try XCTUnwrap(summary.securityScore), 82.7, accuracy: 0.0001)
        XCTAssertEqual(screen.value, 82.7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(workbook.securityScore), 82.7, accuracy: 0.0001)
        XCTAssertEqual(
            summary.securityScoreBasis,
            "filevault=15,sip=10,firewall=10,gatekeeper=5,mscp=10,agent:Falcon=5")
        XCTAssertEqual(screen.basis, summary.securityScoreBasis)
        XCTAssertEqual(workbook.securityScoreParts.map(\.factor.id), screen.available.map(\.id))
        XCTAssertEqual(summary.crowdstrikePct, 70.0)
        XCTAssertEqual(summary.mscpScorePct, 60.0, "the real pass share, never the proxy")
    }

    func testEverySurfaceScoresAllTwelveFactorsTheSame() throws {
        try writeWorkspace()
        try writeNativeSnapshots()
        let config = try load()
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
        let screen = SecurityPostureView.score(SecurityPostureService.load(profile: profile))
        let workbook = CoreDashboard.executiveMetrics(config: config, dataDir: dataDir)

        for value in [try XCTUnwrap(summary.securityScore), screen.value,
                      try XCTUnwrap(workbook.securityScore)] {
            XCTAssertEqual(value, 80.3, accuracy: 0.0001)
        }
        XCTAssertEqual(summary.securityScoreBasis, screen.basis)
    }

    /// Secure Boot, bootstrap token and XProtect shares are recorded in the summary so Trends
    /// and alert rules have them, whether or not the score lists them.
    func testTheSummaryRecordsTheNativeSharesWhetherOrNotTheScoreListsThem() throws {
        try writeWorkspace(config: Self.yaml + """

            security_policy:
              score_factors:
                - {factor: sip, weight: 10}
            """)
        try writeNativeSnapshots()
        let config = try load()
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)

        XCTAssertEqual(summary.securityScoreBasis, "sip=10")
        XCTAssertEqual(summary.securityScore, 100.0)
        XCTAssertEqual(summary.secureBootPct, 66.7)
        XCTAssertEqual(summary.bootstrapPct, 100.0)
        XCTAssertEqual(summary.xprotectPct, 75.0)
        XCTAssertEqual(summary.gatekeeperPct, 90.0)
    }

    /// The summary's XProtect share uses the grace period the list gives the factor. The feed's
    /// newest XProtect came out three days ago: with the default 14 days of grace the older
    /// one is current, with `grace_days: 1` it is behind.
    func testTheSummarysXProtectShareUsesTheListedGracePeriod() throws {
        let released = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-3 * 86_400))
        func summaryShare(listing: String) throws -> Double? {
            try writeWorkspace(config: Self.yaml + listing)
            let when = Date().addingTimeInterval(-3600)
            func mac(_ xprotect: String) -> [String: Any] {
                ["security": ["xprotectVersion": xprotect]]
            }
            try GoldenFleetWorkspace.writeSnapshot(
                kind: "computers", dataDir: dataDir, at: when, rows: [mac("5363"), mac("5362")])
            try GoldenFleetWorkspace.writeRaw("""
                {"XProtectPlistConfigData": {"com.apple.XProtect": "5363",
                                             "ReleaseDate": "\(released)"}}
                """, to: dataDir.appendingPathComponent("sofa/macos_data_feed.json"))
            let summariesDir = root.appendingPathComponent(
                "summaries-\(UUID().uuidString)", isDirectory: true)
            ReportEngine(config: try load(), dataDir: dataDir)
                .emitSummaryJSON(summariesDir: summariesDir)
            return try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first).xprotectPct
        }
        XCTAssertEqual(try summaryShare(listing: ""), 100.0)
        XCTAssertEqual(try summaryShare(listing: """


            security_policy:
              score_factors:
                - {factor: xprotect_current, weight: 5, grace_days: 1}
            """), 50.0)
    }

    func testASummaryWithoutBaselinesRecordsNoMSCPFigure() throws {
        try writeWorkspace(config: """
            security_agents:
              - name: Falcon
                column: Falcon State
                connected_value: connected
            """)
        let config = try load()
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
        XCTAssertNil(summary.mscpScorePct)
        XCTAssertEqual(
            summary.securityScoreBasis,
            "filevault=15,sip=10,firewall=10,gatekeeper=5,agent:Falcon=5")
    }

    // MARK: - Alerts and notes across a basis change

    private func summary(_ date: String, score: Double?, basis: String?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 10, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, source: "jamf-cli",
            securityScore: score, securityScoreBasis: basis)
    }

    func testAScoreDropAcrossABasisChangeDoesNotAlert() {
        let rule = AlertRule(metric: "security_score", when: "drops_more_than", threshold: 5)
        let old = summary("2026-10-04", score: 90, basis: nil)
        let new = summary("2026-10-05", score: 79.3, basis: "filevault=15,sip=10")
        XCTAssertTrue(
            MetricAlertEvaluator.evaluate(rules: [rule], current: new, prior: old).isEmpty)
        let sameBasis = summary("2026-10-04", score: 90, basis: "filevault=15,sip=10")
        XCTAssertEqual(
            MetricAlertEvaluator.evaluate(rules: [rule], current: new, prior: sameBasis).count, 1)
        let otherWeights = summary("2026-10-04", score: 90, basis: "filevault=15,sip=20")
        XCTAssertTrue(
            MetricAlertEvaluator.evaluate(rules: [rule], current: new, prior: otherWeights)
                .isEmpty, "a changed weight is a changed definition")
    }

    /// The note names the factors the score now weighs: an earlier build's basis reads too,
    /// its `crowdstrike` as the EDR agent.
    func testTrendsNamesTheDateTheScoreChangedDefinition() throws {
        let old = "fileVault,sip,firewall,crowdstrike,mscp"
        let days = [
            summary("2026-10-03", score: 90, basis: nil),
            summary("2026-10-04", score: 91, basis: nil),
            summary("2026-10-05", score: 79.3, basis: old),
            summary("2026-10-06", score: 80, basis: old),
        ]
        let note = try XCTUnwrap(
            TrendStore.securityScoreDefinitionNote(in: days, edrAgentName: "Falcon"))
        XCTAssertTrue(note.contains("on 2026-10-05"), note)
        XCTAssertTrue(note.contains("Falcon connected"), note)
        XCTAssertTrue(note.contains("mSCP baseline"), note)

        let current = days + [summary(
            "2026-10-07", score: 82, basis: "filevault=15,agent:Nessus=5,os_current=15")]
        let newer = try XCTUnwrap(
            TrendStore.securityScoreDefinitionNote(in: current, edrAgentName: "Falcon"))
        XCTAssertTrue(newer.contains("on 2026-10-07"), newer)
        XCTAssertTrue(newer.contains("FileVault, Nessus connected, macOS current (30-day grace)"),
                      newer)
        // One basis through the visible range: nothing to say.
        XCTAssertNil(TrendStore.securityScoreDefinitionNote(
            in: Array(days.suffix(2)), edrAgentName: nil))
        XCTAssertNil(TrendStore.securityScoreDefinitionNote(
            in: Array(days.prefix(2)), edrAgentName: nil))
    }

    func testBasisSurvivesTheSummaryRoundTrip() throws {
        let original = summary("2026-10-05", score: 79.3, basis: "filevault=15,sip=10")
        let decoded = try JSONDecoder().decode(
            DailySummary.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.securityScoreBasis, "filevault=15,sip=10")
        let legacy = try JSONDecoder().decode(DailySummary.self, from: Data("""
            {"date":"2026-10-04","totalDevices":10,"source":"jamf-cli","securityScore":90}
            """.utf8))
        XCTAssertNil(legacy.securityScoreBasis)
    }
}
