import XCTest
@testable import JamfReports

/// The Security Score's factors live in `security_policy.score_factors`: every surface that
/// scores (the daily summary, the workbook's Executive Summary and the Security Posture screen)
/// reads that one list, so one fleet has one score. Fixtures are the `pro report security`
/// summary shape, GoldenFleet case A: 250 Macs, FileVault 240, SIP 250, Firewall 245,
/// Gatekeeper 248, so the shares are 96.0, 100.0, 98.0 and 99.2.
@MainActor
final class SecurityScoreSurfacesTests: XCTestCase {

    private func securityData(_ yaml: String) throws -> (config: ReportConfig, dataDir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-surfaces-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stamp = GoldenFleetClock.stamp(Date().addingTimeInterval(-3600))
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 250, filevault: 240, sip: 250, firewall: 245, gatekeeper: 248),
            to: dir.appendingPathComponent("security/security_\(stamp).json"))
        return (try ConfigLoader.loadFromString(yaml), dir)
    }

    private func summaryScore(_ data: (config: ReportConfig, dataDir: URL)) throws -> Double {
        let summaries = data.dataDir.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: data.config, dataDir: data.dataDir)
            .emitSummaryJSON(summariesDir: summaries)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
        return try XCTUnwrap(summary.securityScore)
    }

    private func workbookScore(_ data: (config: ReportConfig, dataDir: URL)) throws -> Double {
        let metrics = CoreDashboard.executiveMetrics(config: data.config, dataDir: data.dataDir)
        return try XCTUnwrap(metrics.securityScore)
    }

    private func screen(_ data: (config: ReportConfig, dataDir: URL)) throws -> SecurityScore {
        let folder = data.dataDir.appendingPathComponent("security")
        let file = folder.appendingPathComponent(try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: folder.path).first))
        let snapshot = try SecurityPostureService.load(
            from: file, policy: data.config.resolvedSecurityPolicy, hardware: [:])
        return SecurityPostureView.score(
            snapshot.scored(config: data.config, dataDir: data.dataDir))
    }

    private func assertEverySurface(
        _ yaml: String, scores expected: Double, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try securityData(yaml)
        XCTAssertEqual(try summaryScore(data), expected, accuracy: 0.001, "summary.json",
                       file: file, line: line)
        XCTAssertEqual(try workbookScore(data), expected, accuracy: 0.001, "Executive Summary",
                       file: file, line: line)
        XCTAssertEqual(try screen(data).value, expected, accuracy: 0.001, "Security Posture",
                       file: file, line: line)
    }

    /// No list: the default native factors, of which the security report measures the four
    /// controls at 15, 10, 10 and 5. (96.0 x 15 + 100 x 10 + 98.0 x 10 + 99.2 x 5) / 40
    /// = (1440 + 1000 + 980 + 496) / 40 = 97.9. Before the factors, the three controls at
    /// equal weights made it 98.0.
    func testWithNoListEverySurfaceScoresTheDefaultFactors() throws {
        try assertEverySurface("thresholds:\n  stale_device_days: 30\n", scores: 97.9)
    }

    /// FileVault 30 against SIP 15 and Firewall 15; Gatekeeper is not listed, so it is not
    /// scored: (96.0 x 30 + 100 x 15 + 98.0 x 15) / 60 = (2880 + 1500 + 1470) / 60 = 97.5.
    func testTheSummaryTheWorkbookAndTheScreenScoreWithTheWorkspacesFactors() throws {
        try assertEverySurface("""
            security_policy:
              score_factors:
                - {factor: filevault, weight: 30}
                - {factor: sip, weight: 15}
                - {factor: firewall, weight: 15}
            """, scores: 97.5)
    }

    /// An ignored control leaves the score whatever weight the list gives it. FileVault 30 and
    /// SIP 15 are left: (96.0 x 30 + 100 x 15) / 45 = 4380 / 45 = 97.3. Counting the firewall
    /// at its 50 would give (4380 + 98.0 x 50) / 95 = 97.7.
    func testAControlSetToNotCountedLeavesTheScoreWhateverItsWeight() throws {
        try assertEverySurface("""
            security_policy:
              controls:
                firewall: ignore
              score_factors:
                - {factor: filevault, weight: 30}
                - {factor: sip, weight: 15}
                - {factor: firewall, weight: 50}
            """, scores: 97.3)
    }

    /// A weight of 0 switches a factor off without removing it, and the Gatekeeper factor now
    /// counts: (100 x 10 + 99.2 x 10) / 20 = 99.6.
    func testAZeroWeightLeavesAListedFactorOutAndGatekeeperCounts() throws {
        try assertEverySurface("""
            security_policy:
              score_factors:
                - {factor: filevault, weight: 0}
                - {factor: sip, weight: 10}
                - {factor: gatekeeper, weight: 10}
            """, scores: 99.6)
    }

    /// Each surface lists the same scored factors: the screen's breakdown and the summary's
    /// basis name the factors the list holds that had data.
    func testTheBasisAndTheBreakdownNameTheSameFactors() throws {
        let data = try securityData("""
            security_policy:
              score_factors:
                - {factor: filevault, weight: 30}
                - {factor: sip, weight: 15}
                - {factor: secure_boot, weight: 5}
            """)
        let summaries = data.dataDir.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: data.config, dataDir: data.dataDir)
            .emitSummaryJSON(summariesDir: summaries)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
        let score = try screen(data)
        XCTAssertEqual(summary.securityScoreBasis, "filevault=30,sip=15",
                       "Secure Boot has no computers snapshot, so it is not scored or in the basis")
        XCTAssertEqual(score.basis, summary.securityScoreBasis)
        XCTAssertEqual(score.missing.map(\.id), ["secure_boot"])
    }

    /// The workbook lists each scored factor under the score with its share and the points it
    /// adds. Shares 96.0, 100.0, 98.0 and 99.2 at weights 15, 10, 10 and 5 over 40:
    /// 36.0 + 25.0 + 24.5 + 12.4 = 97.9.
    func testTheWorkbookListsEachScoredFactorWithItsShareAndPoints() throws {
        let data = try securityData("thresholds:\n  stale_device_days: 45\n")
        let metrics = CoreDashboard.executiveMetrics(config: data.config, dataDir: data.dataDir)
        let dashboard = CoreDashboard(
            config: data.config, dataDir: data.dataDir, workbook: Workbook())
        let rows = dashboard.scoreFactorRows(metrics)
        XCTAssertEqual(rows.map(\.0), [
            "Score — FileVault", "Score — SIP", "Score — Firewall", "Score — Gatekeeper",
        ])
        XCTAssertEqual(rows.map(\.1), [
            "96.0% · 36.0 pts", "100.0% · 25.0 pts", "98.0% · 24.5 pts", "99.2% · 12.4 pts",
        ])
    }

    func testTheBreakdownFormatsShareAndPoints() {
        XCTAssertEqual(ScoreBreakdownList.percent(96), "96.0%")
        XCTAssertEqual(ScoreBreakdownList.percent(33.333), "33.3%")
        XCTAssertEqual(ScoreBreakdownList.points(36.04), "36.0 pts")
        XCTAssertEqual(ScoreBreakdownList.points(0), "0.0 pts")
    }
}
