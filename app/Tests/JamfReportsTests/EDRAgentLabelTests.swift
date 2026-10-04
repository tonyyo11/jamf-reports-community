import XCTest
@testable import JamfReports

/// v2.2.0 EDR genericization: a community app must not hardcode a vendor name.
/// The metric identifier keeps the legacy "crowdstrike" raw value (persistence
/// + summary.json schema compatibility); every user-visible label is either the
/// generic "EDR Agent …" or the tenant's configured security_agents name.
final class EDRAgentLabelTests: XCTestCase {

    // MARK: - Raw-value compatibility

    func testTrendMetricKeepsLegacyRawValue() {
        XCTAssertEqual(TrendSeries.Metric.edrAgent.rawValue, "crowdstrike")
        XCTAssertEqual(TrendSeries.Metric(rawValue: "crowdstrike"), .edrAgent)
    }

    /// Persisted score-card selections from before the rename must keep working.
    func testPersistedScoreCardSelectionWithLegacyRawValueDecodes() {
        UserDefaults.standard.set(
            "stability,crowdstrike,patch", forKey: WorkspaceStore.scoreCardsKey
        )
        defer { UserDefaults.standard.removeObject(forKey: WorkspaceStore.scoreCardsKey) }

        XCTAssertEqual(
            WorkspaceStore.loadPersistedScoreCards(),
            [.stability, .edrAgent, .patch]
        )
    }

    /// The three security controls join after `managedDevices` (the order is pinned in
    /// `testCaseIterableOrderUnchangedByRename`) under their own raw values.
    func testSecurityControlMetricsKeepTheirRawValues() {
        XCTAssertEqual(TrendSeries.Metric(rawValue: "sip"), .sip)
        XCTAssertEqual(TrendSeries.Metric(rawValue: "firewall"), .firewall)
        XCTAssertEqual(TrendSeries.Metric(rawValue: "gatekeeper"), .gatekeeper)
    }

    /// A selection that names a control card persists and reloads as stored.
    func testPersistedSecurityControlSelectionRoundTrips() {
        defer { UserDefaults.standard.removeObject(forKey: WorkspaceStore.scoreCardsKey) }

        UserDefaults.standard.set("sip,firewall", forKey: WorkspaceStore.scoreCardsKey)
        XCTAssertEqual(WorkspaceStore.loadPersistedScoreCards(), [.sip, .firewall])

        WorkspaceStore.persistScoreCards([.stability, .gatekeeper, .sip])
        XCTAssertEqual(WorkspaceStore.loadPersistedScoreCards(), [.stability, .gatekeeper, .sip])
    }

    func testSecurityControlMetricsCarryTheirOwnLabelUnitAndColour() {
        let expected: [(TrendSeries.Metric, String, UInt32)] = [
            (.sip, "System Integrity Protection", 0x64D2FF),
            (.firewall, "Firewall Enabled", 0x5E5CE6),
            (.gatekeeper, "Gatekeeper Enabled", 0xAC8E68),
        ]
        for (metric, label, colour) in expected {
            XCTAssertEqual(metric.displayLabel, label)
            XCTAssertEqual(
                metric.displayLabel(benchmarkLabel: "Benchmark", edrAgentName: "Agent"), label)
            XCTAssertEqual(metric.unit, "%")
            XCTAssertEqual(metric.minY, 60)
            XCTAssertEqual(metric.maxY, 100)
            XCTAssertEqual(metric.colorHex, colour)
        }
    }

    func testSecurityScoreMetricKeepsLegacyRawValue() {
        XCTAssertEqual(SecurityScore.Metric.edrAgent.rawValue, "crowdstrike")
    }

    // MARK: - Generic fallback labels (no vendor names)

    func testGenericLabelsContainNoVendorName() {
        XCTAssertEqual(TrendSeries.Metric.edrAgent.displayLabel, "EDR Agent Installed")
        XCTAssertEqual(SecurityScore.Metric.edrAgent.displayLabel, "EDR Agent Connected")
        for metric in TrendSeries.Metric.allCases {
            XCTAssertFalse(
                metric.displayLabel.localizedCaseInsensitiveContains("crowdstrike"),
                "\(metric) label must not hardcode a vendor name"
            )
        }
        for metric in SecurityScore.Metric.allCases {
            XCTAssertFalse(
                metric.displayLabel.localizedCaseInsensitiveContains("crowdstrike"),
                "\(metric) label must not hardcode a vendor name"
            )
        }
    }

    // MARK: - Config-driven labels

    func testTrendMetricLabelUsesConfiguredAgentName() {
        XCTAssertEqual(
            TrendSeries.Metric.edrAgent.displayLabel(
                benchmarkLabel: nil, edrAgentName: "CrowdStrike Falcon"
            ),
            "CrowdStrike Falcon Installed"
        )
        XCTAssertEqual(
            TrendSeries.Metric.edrAgent.displayLabel(benchmarkLabel: nil, edrAgentName: nil),
            "EDR Agent Installed"
        )
        // Other metrics ignore the agent name.
        XCTAssertEqual(
            TrendSeries.Metric.fileVault.displayLabel(
                benchmarkLabel: nil, edrAgentName: "SentinelOne"
            ),
            "FileVault Encryption"
        )
    }

    func testSecurityScoreMetricLabelUsesConfiguredAgentName() {
        XCTAssertEqual(
            SecurityScore.Metric.edrAgent.displayLabel(edrAgentName: "SentinelOne"),
            "SentinelOne Connected"
        )
        XCTAssertEqual(
            SecurityScore.Metric.edrAgent.displayLabel(edrAgentName: ""),
            "EDR Agent Connected"
        )
    }

    // MARK: - Scoring weights preference compatibility

    func testScoringConfigPositionalParsingUnchanged() {
        // Slot 4 is the EDR weight regardless of the property rename — a
        // pre-rename persisted preference must parse identically.
        let parsed = ScoringConfig.parse("15,15,15,10,20,5,15,5")
        XCTAssertEqual(parsed.weights.edrAgent, 10)
        XCTAssertEqual(parsed.weights, SecurityScoreWeights.defaultWeights)
    }

    // MARK: - Metric ordering preserved

    func testCaseIterableOrderUnchangedByRename() {
        XCTAssertEqual(TrendSeries.Metric.allCases, [
            .stability, .activeDevices, .compliance, .fileVault, .osCurrent,
            .edrAgent, .stale, .patch, .securityScore, .mscpBandTrend, .managedDevices,
            .sip, .firewall, .gatekeeper,
        ])
        XCTAssertEqual(SecurityScore.Metric.allCases, [
            .fileVault, .sip, .firewall, .edrAgent, .mscp, .xprotect, .cve, .secureBoot,
        ])
    }
}
