import XCTest
@testable import JamfReports

/// v2.2.0 EDR genericization: a community app must not hardcode a vendor name.
/// The trend metric identifier keeps the legacy "crowdstrike" raw value (persistence
/// + summary.json schema compatibility); every user-visible label is either the
/// generic "EDR agent coverage" or the tenant's configured security_agents name. The score's
/// agent factors are named by the agent, and an earlier build's `crowdstrike` basis word reads
/// as the EDR agent.
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

    // MARK: - Generic fallback labels (no vendor names)

    func testGenericLabelsContainNoVendorName() {
        XCTAssertEqual(TrendSeries.Metric.edrAgent.displayLabel, "EDR agent coverage")
        XCTAssertEqual(SecurityScoreFactor.labels(inBasis: "crowdstrike"), ["EDR agent"])
        XCTAssertEqual(SecurityScoreFactor(.agent, weight: 5).label(), "Agent connected")
        for metric in TrendSeries.Metric.allCases {
            XCTAssertFalse(
                metric.displayLabel.localizedCaseInsensitiveContains("crowdstrike"),
                "\(metric) label must not hardcode a vendor name"
            )
        }
        for kind in SecurityScoreFactor.Kind.allCases {
            XCTAssertFalse(
                SecurityScoreFactor(kind, weight: 1).label()
                    .localizedCaseInsensitiveContains("crowdstrike"),
                "\(kind) label must not hardcode a vendor name"
            )
        }
    }

    // MARK: - Config-driven labels

    func testTrendMetricLabelUsesConfiguredAgentName() {
        XCTAssertEqual(
            TrendSeries.Metric.edrAgent.displayLabel(
                benchmarkLabel: nil, edrAgentName: "CrowdStrike Falcon"
            ),
            "CrowdStrike Falcon coverage"
        )
        XCTAssertEqual(
            TrendSeries.Metric.edrAgent.displayLabel(benchmarkLabel: nil, edrAgentName: nil),
            "EDR agent coverage"
        )
        // Other metrics ignore the agent name.
        XCTAssertEqual(
            TrendSeries.Metric.fileVault.displayLabel(
                benchmarkLabel: nil, edrAgentName: "SentinelOne"
            ),
            "FileVault Encryption"
        )
    }

    func testScoreFactorLabelUsesTheConfiguredAgentName() {
        XCTAssertEqual(
            SecurityScoreFactor(.agent, weight: 5, target: "SentinelOne").label(),
            "SentinelOne connected"
        )
    }

    /// A summary written before the factors named its EDR input `crowdstrike`, whoever the
    /// agent was; the Trends note reads it as the configured agent.
    func testAnEarlierBuildsEDRBasisWordReadsAsTheConfiguredAgent() {
        XCTAssertEqual(
            SecurityScoreFactor.labels(inBasis: "crowdstrike", edrAgentName: "SentinelOne"),
            ["SentinelOne connected"]
        )
        XCTAssertEqual(
            SecurityScoreFactor.labels(inBasis: "crowdstrike", edrAgentName: ""),
            ["EDR agent"]
        )
    }

    // MARK: - Metric ordering preserved

    func testCaseIterableOrderUnchangedByRename() {
        XCTAssertEqual(TrendSeries.Metric.allCases, [
            .stability, .activeDevices, .compliance, .fileVault, .osCurrent,
            .edrAgent, .stale, .patch, .securityScore, .mscpBandTrend, .managedDevices,
            .sip, .firewall, .gatekeeper,
        ])
    }
}
