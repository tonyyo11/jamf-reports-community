import XCTest
@testable import JamfReports

/// The Security Score's weights live in `security_policy.score_weights`: every surface that
/// scores reads that one set, and the Scoring tab falls back to this Mac's earlier preference
/// only for what it shows. Fixtures are the `pro report security` summary shape.
@MainActor
final class SecurityScoreWeightsTests: XCTestCase {

    // MARK: - What the Scoring tab shows

    private let legacy = "20,15,15,10,20,5,15,5"

    func testConfigWeightsAreShownWhenSet() {
        var configured = SecurityScoreWeights.defaultWeights
        configured.sip = 40
        let shown = ScoringConfig.displayedWeights(config: configured, legacyRaw: legacy)
        XCTAssertEqual(shown.weights, configured, "the file wins over the preference")
        XCTAssertFalse(shown.fromLegacyPreference)
    }

    func testTheEarlierPreferenceIsShownWhenTheFileHasNoWeights() {
        let shown = ScoringConfig.displayedWeights(config: nil, legacyRaw: legacy)
        XCTAssertEqual(shown.weights, ScoringConfig.parse(legacy).weights)
        XCTAssertEqual(shown.weights.fileVault, 20)
        XCTAssertTrue(shown.fromLegacyPreference)
    }

    func testTheDefaultsAreShownWithNeither() {
        let shown = ScoringConfig.displayedWeights(config: nil, legacyRaw: "")
        XCTAssertEqual(shown.weights, .defaultWeights)
        XCTAssertFalse(shown.fromLegacyPreference)
    }

    /// With no earlier preference the block goes (nil); with one, saving nil would show that
    /// preference again, so the defaults are saved and the preference stays as it is.
    func testResetSavesTheDefaultsOnlyWhereTheEarlierPreferenceWouldReturn() {
        XCTAssertNil(ScoringConfig.resetWeights(legacyRaw: ""))
        XCTAssertEqual(ScoringConfig.resetWeights(legacyRaw: legacy), .defaultWeights)
        let afterReset = ScoringConfig.displayedWeights(
            config: ScoringConfig.resetWeights(legacyRaw: legacy), legacyRaw: legacy)
        XCTAssertEqual(afterReset.weights, .defaultWeights)
        XCTAssertFalse(afterReset.fromLegacyPreference)
    }

    // MARK: - One set of weights for every score

    private func securityData(_ yaml: String) throws -> (config: ReportConfig, dataDir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-weights-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stamp = GoldenFleetClock.stamp(Date().addingTimeInterval(-3600))
        // GoldenFleet case A: 250 Macs, FileVault 240, SIP 250, Firewall 245, Gatekeeper 248.
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

    private func screenScore(_ data: (config: ReportConfig, dataDir: URL)) throws -> Double {
        let file = data.dataDir.appendingPathComponent("security")
            .appendingPathComponent(try XCTUnwrap(FileManager.default.contentsOfDirectory(
                atPath: data.dataDir.appendingPathComponent("security").path).first))
        let snapshot = try SecurityPostureService.load(
            from: file, policy: data.config.resolvedSecurityPolicy, hardware: [:])
        return SecurityPostureView.score(snapshot).value
    }

    /// FileVault 96.0, SIP 100.0 and Firewall 98.0 are the only measured controls, so the
    /// weights renormalize over them. Defaults 15/15/15: (96 + 100 + 98) / 3 = 98.0.
    func testWithNoWeightsEverySurfaceScoresWithTheDefaults() throws {
        let data = try securityData("thresholds:\n  stale_device_days: 30\n")
        XCTAssertEqual(try summaryScore(data), 98.0, accuracy: 0.001)
        XCTAssertEqual(try workbookScore(data), 98.0, accuracy: 0.001)
        XCTAssertEqual(try screenScore(data), 98.0, accuracy: 0.001)
    }

    /// FileVault 30 against SIP 15 and Firewall 15 (total 60):
    /// (96.0 * 30 + 100.0 * 15 + 98.0 * 15) / 60 = (2880 + 1500 + 1470) / 60 = 97.5.
    func testTheSummaryTheWorkbookAndTheScreenScoreWithTheWorkspacesWeights() throws {
        let data = try securityData("""
        security_policy:
          score_weights:
            filevault: 30
        """)
        XCTAssertEqual(try summaryScore(data), 97.5, accuracy: 0.001)
        XCTAssertEqual(try workbookScore(data), 97.5, accuracy: 0.001)
        XCTAssertEqual(try screenScore(data), 97.5, accuracy: 0.001)
    }

    /// An ignored control leaves the score whatever weight the file gives it. FileVault 30 and
    /// SIP 15 are left: (96.0 * 30 + 100.0 * 15) / 45 = 4380 / 45 = 97.3. Counting the
    /// firewall at its 50 would give (4380 + 98.0 * 50) / 95 = 97.7.
    func testAControlSetToNotCountedLeavesTheScoreWhateverItsWeight() throws {
        let data = try securityData("""
        security_policy:
          controls:
            firewall: ignore
          score_weights:
            filevault: 30
            firewall: 50
        """)
        XCTAssertEqual(try summaryScore(data), 97.3, accuracy: 0.001)
        XCTAssertEqual(try workbookScore(data), 97.3, accuracy: 0.001)
        XCTAssertEqual(try screenScore(data), 97.3, accuracy: 0.001)
    }

    // MARK: - The Config Doctor says what a bad weight is

    func testTheDoctorCallsABadWeightANumberProblemNotALevelProblem() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(
                keyPath: "security_policy.score_weights.sip", value: "150", used: "15")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.title, "security_policy.score_weights.sip")
        XCTAssertEqual(rows.first?.detail, "\"150\" is not a number from 0 to 100 — using 15")
        XCTAssertEqual(rows.first?.hint,
                       "Set it to a number from 0 to 100 in config.yaml, or remove the line.")
    }
}
