import Foundation
import XCTest
@testable import JamfReports

/// Epic #207 H1: the stored Security Score weighs every input the run has data for, through
/// the one function the daily summary, the Security Posture screen and the workbook share.
///
/// Fleet, invented and worked by hand: ten Macs. FileVault on 9, SIP on 10, Firewall on 8;
/// the EDR agent connected on 7 (3 report "error"); the primary mSCP baseline has a valid
/// count for all ten, zero failures on 6. With the default weights (15, 15, 15, EDR 10,
/// mSCP 20): (90 x 15 + 100 x 15 + 80 x 15 + 70 x 10 + 60 x 20) / 75 = 79.3. Without the EDR
/// and mSCP inputs it is (90 + 100 + 80) / 3 = 90.0.
final class SecurityScoreInputsTests: XCTestCase {

    private var root: URL!
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
                total: 10, filevault: 9, sip: 10, firewall: 8, gatekeeper: 10))
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

    private func fleetCounts() throws -> SecurityFleetCounts {
        let url = try XCTUnwrap(FileManager.newestJSONFile(
            in: dataDir.appendingPathComponent("security", isDirectory: true)))
        let items = try JSONDecoder().decode(
            [SecurityReportItem].self, from: Data(contentsOf: url))
        return try XCTUnwrap(SecurityFleetCounts.build(
            items: items, hardware: [:], policy: .default))
    }

    // MARK: - The inputs

    func testEveryInputWithDataIsWeighed() throws {
        try writeWorkspace()
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let extras = SecurityScoreInputs.load(dataDir: dataDir, config: config)
        XCTAssertEqual(extras, .init(edrConnected: 7, mscpPass: 6, mscpEvaluated: 10))

        let score = SecurityScoreCalculator.score(
            input: SecurityScoreInputs.input(fleet: try fleetCounts(), extras: extras))
        XCTAssertEqual(score.value, 79.3, accuracy: 0.0001)
        XCTAssertEqual(score.available, [.fileVault, .sip, .firewall, .edrAgent, .mscp])
        XCTAssertEqual(score.missing, [.xprotect, .cve, .secureBoot],
                       "nothing in the app measures these, so their weights drop out")
        XCTAssertEqual(
            SecurityScoreInputs.basis(of: score), "fileVault,sip,firewall,crowdstrike,mscp")
    }

    func testWithoutExtrasTheScoreIsTheThreeControlsAlone() throws {
        try writeWorkspace()
        let score = SecurityScoreCalculator.score(
            input: SecurityScoreInputs.input(fleet: try fleetCounts(), extras: .none))
        XCTAssertEqual(score.value, 90.0, accuracy: 0.0001)
        XCTAssertEqual(SecurityScoreInputs.basis(of: score), "fileVault,sip,firewall")
    }

    /// The proxy is FileVault, SIP, Firewall and Gatekeeper again; weighing it as mSCP would
    /// count those controls twice.
    func testWithoutBaselinesNoMSCPInputIsInvented() throws {
        let noBaselines = """
            security_agents:
              - name: Falcon
                column: Falcon State
                connected_value: connected
            """
        try writeWorkspace(config: noBaselines)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let extras = SecurityScoreInputs.load(dataDir: dataDir, config: config)
        XCTAssertEqual(extras, .init(edrConnected: 7, mscpPass: nil, mscpEvaluated: nil))
        let score = SecurityScoreCalculator.score(
            input: SecurityScoreInputs.input(fleet: try fleetCounts(), extras: extras))
        XCTAssertFalse(score.available.contains(.mscp))
        // (90 x 15 + 100 x 15 + 80 x 15 + 70 x 10) / 55 = 86.36, shown to a tenth
        XCTAssertEqual(score.value, 86.4, accuracy: 0.0001)
    }

    func testAnAgentNoMacReportsIsMissingNotZero() throws {
        try writeWorkspace(config: Self.yaml.replacingOccurrences(
            of: "Falcon State", with: "Some Other EA"))
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let extras = SecurityScoreInputs.load(dataDir: dataDir, config: config)
        XCTAssertNil(extras.edrConnected)
    }

    func testNoEAResultsLeavesTheThreeControls() throws {
        try writeWorkspace(withEAResults: false)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(SecurityScoreInputs.load(dataDir: dataDir, config: config), .none)
    }

    func testBasisRoundTripsToMetrics() {
        XCTAssertEqual(
            SecurityScoreInputs.metrics(inBasis: "fileVault,crowdstrike,bogus,mscp"),
            [.fileVault, .edrAgent, .mscp])
    }

    // MARK: - One fleet, one score

    /// The summary writer, the Security Posture screen and the workbook's Executive Summary
    /// read the same snapshots and return the same score, and the summary records its basis,
    /// the EDR figure and the mSCP pass share the score used.
    func testEverySurfaceScoresTheFleetTheSame() throws {
        try writeWorkspace()
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))

        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)

        let posture = SecurityPostureService.load(profile: profile)
        let screen = SecurityPostureView.score(posture)
        let workbook = CoreDashboard.executiveMetrics(config: config, dataDir: dataDir)

        XCTAssertEqual(try XCTUnwrap(summary.securityScore), 79.3, accuracy: 0.0001)
        XCTAssertEqual(screen.value, 79.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(workbook.securityScore), 79.3, accuracy: 0.0001)
        XCTAssertEqual(summary.securityScoreBasis, "fileVault,sip,firewall,crowdstrike,mscp")
        XCTAssertEqual(SecurityScoreInputs.basis(of: screen), summary.securityScoreBasis)
        XCTAssertEqual(summary.crowdstrikePct, 70.0)
        XCTAssertEqual(summary.mscpScorePct, 60.0, "the real pass share, never the proxy")
    }

    func testASummaryWithoutBaselinesRecordsNoMSCPFigure() throws {
        try writeWorkspace(config: """
            security_agents:
              - name: Falcon
                column: Falcon State
                connected_value: connected
            """)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
        XCTAssertNil(summary.mscpScorePct)
        XCTAssertEqual(summary.securityScoreBasis, "fileVault,sip,firewall,crowdstrike")
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
        let new = summary("2026-10-05", score: 79.3, basis: "fileVault,sip,firewall,mscp")
        XCTAssertTrue(
            MetricAlertEvaluator.evaluate(rules: [rule], current: new, prior: old).isEmpty)
        let sameBasis = summary("2026-10-04", score: 90, basis: "fileVault,sip,firewall,mscp")
        XCTAssertEqual(
            MetricAlertEvaluator.evaluate(rules: [rule], current: new, prior: sameBasis).count, 1)
    }

    func testTrendsNamesTheDateTheScoreChangedDefinition() throws {
        let days = [
            summary("2026-10-03", score: 90, basis: nil),
            summary("2026-10-04", score: 91, basis: nil),
            summary("2026-10-05", score: 79.3, basis: "fileVault,sip,firewall,crowdstrike,mscp"),
            summary("2026-10-06", score: 80, basis: "fileVault,sip,firewall,crowdstrike,mscp"),
        ]
        let note = try XCTUnwrap(
            TrendStore.securityScoreDefinitionNote(in: days, edrAgentName: "Falcon"))
        XCTAssertTrue(note.contains("on 2026-10-05"), note)
        XCTAssertTrue(note.contains("Falcon Connected"), note)
        XCTAssertTrue(note.contains("mSCP Compliance"), note)
        // One basis through the visible range: nothing to say.
        XCTAssertNil(TrendStore.securityScoreDefinitionNote(
            in: Array(days.suffix(2)), edrAgentName: nil))
        XCTAssertNil(TrendStore.securityScoreDefinitionNote(
            in: Array(days.prefix(2)), edrAgentName: nil))
    }

    func testBasisSurvivesTheSummaryRoundTrip() throws {
        let original = summary("2026-10-05", score: 79.3, basis: "fileVault,sip,firewall,mscp")
        let decoded = try JSONDecoder().decode(
            DailySummary.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.securityScoreBasis, "fileVault,sip,firewall,mscp")
        let legacy = try JSONDecoder().decode(DailySummary.self, from: Data("""
            {"date":"2026-10-04","totalDevices":10,"source":"jamf-cli","securityScore":90}
            """.utf8))
        XCTAssertNil(legacy.securityScoreBasis)
    }
}
