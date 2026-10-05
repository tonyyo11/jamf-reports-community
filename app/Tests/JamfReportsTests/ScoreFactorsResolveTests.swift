import XCTest
@testable import JamfReports

/// What a workspace actually scores: the listed factors (or the defaults) less what the
/// workspace cannot count. Every score, report and screen resolves through
/// `SecurityControlPolicy.resolvedScoreFactors(agents:baselines:)`.
final class ScoreFactorsResolveTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor

    private func policy(_ yaml: String) throws -> SecurityControlPolicy {
        try ConfigLoader.loadFromString(yaml).resolvedSecurityPolicy
    }

    // MARK: - Controls at ignore

    /// A control set to `ignore` is not scored even when its factor is listed.
    func testAControlAtIgnoreIsDroppedEvenWhenListed() throws {
        let policy = try policy("""
            security_policy:
              controls:
                sip: ignore
                gatekeeper: ignore
              score_factors:
                - {factor: filevault, weight: 15}
                - {factor: sip, weight: 10}
                - {factor: gatekeeper, weight: 5}
            """)
        XCTAssertEqual(policy.resolvedScoreFactors(agents: [], baselines: []),
                       [Factor(.fileVault, weight: 15)])
    }

    func testTheDefaultsAlsoLoseAControlAtIgnore() {
        let policy = SecurityControlPolicy(firewall: .ignore)
        let resolved = policy.resolvedScoreFactors(agents: [], baselines: [])
        XCTAssertEqual(resolved.map(\.id),
                       Factor.nativeDefaults.map(\.id).filter { $0 != "firewall" })
    }

    /// A warning is not ignore: the factor stays (the Mac scores as passing).
    func testAControlAtWarningStays() {
        let policy = SecurityControlPolicy(sip: .warning, gatekeeper: .warning)
        let ids = policy.resolvedScoreFactors(agents: [], baselines: []).map(\.id)
        XCTAssertTrue(ids.contains("sip") && ids.contains("gatekeeper"))
    }

    // MARK: - Absent list

    func testAnAbsentListResolvesToTheDefaultsForTheWorkspace() {
        let resolved = SecurityControlPolicy.default.resolvedScoreFactors(
            agents: ["Falcon", "Nessus"], baselines: ["STIG"])
        XCTAssertEqual(resolved, Factor.defaults(agents: ["Falcon", "Nessus"], hasBaseline: true))
        XCTAssertEqual(resolved.suffix(3).map(\.id), ["mscp", "agent:Falcon", "agent:Nessus"])
    }

    func testAnEmptyListResolvesToNothing() throws {
        let policy = try policy("security_policy:\n  score_factors: []\n")
        XCTAssertEqual(policy.resolvedScoreFactors(agents: ["Falcon"], baselines: ["A"]), [])
    }

    // MARK: - Agents

    func testAnAgentThatMatchesNoSecurityAgentIsDropped() throws {
        let policy = try policy("""
            security_policy:
              score_factors:
                - {factor: agent, agent: Ghost, weight: 5}
                - {factor: agent, agent: Falcon, weight: 5}
                - {factor: sip, weight: 5}
            """)
        XCTAssertEqual(policy.resolvedScoreFactors(agents: ["Falcon"], baselines: []).map(\.id),
                       ["agent:Falcon", "sip"])
        XCTAssertEqual(policy.resolvedScoreFactors(agents: [], baselines: []).map(\.id), ["sip"],
                       "no security_agents at all")
    }

    /// The agent takes the spelling `security_agents` gives it, matched ignoring case and
    /// surrounding space, so the summary keys and the Overview look it up the same way.
    func testAnAgentTakesTheConfiguredSpelling() throws {
        let policy = try policy("""
            security_policy:
              score_factors:
                - {factor: agent, agent: "crowdstrike FALCON", weight: 5}
            """)
        let resolved = policy.resolvedScoreFactors(
            agents: ["  CrowdStrike Falcon "], baselines: [])
        XCTAssertEqual(resolved, [Factor(.agent, weight: 5, target: "CrowdStrike Falcon")])
        XCTAssertEqual(resolved.first?.key, "agent:crowdstrike falcon")
    }

    // MARK: - mSCP

    func testMSCPWithNoBaselinesIsDropped() throws {
        let policy = try policy("""
            security_policy:
              score_factors:
                - {factor: mscp, weight: 10}
                - {factor: mscp, baseline: STIG, weight: 10}
                - {factor: sip, weight: 5}
            """)
        XCTAssertEqual(policy.resolvedScoreFactors(agents: [], baselines: []).map(\.id), ["sip"])
    }

    /// With baselines configured an unnamed mSCP factor stays unnamed, which scores the first.
    func testUnnamedMSCPStaysUnnamedWhenABaselineExists() throws {
        let policy = try policy("""
            security_policy:
              score_factors:
                - {factor: mscp, weight: 10}
            """)
        let resolved = policy.resolvedScoreFactors(agents: [], baselines: ["STIG", "CIS"])
        XCTAssertEqual(resolved, [Factor(.mscp, weight: 10)])
        XCTAssertNil(resolved.first?.target)
    }

    func testANamedBaselineIsMatchedIgnoringCaseAndTakesTheConfiguredSpelling() throws {
        let policy = try policy("""
            security_policy:
              score_factors:
                - {factor: mscp, baseline: "cis LEVEL 1", weight: 10}
                - {factor: mscp, baseline: "Nope", weight: 10}
            """)
        let resolved = policy.resolvedScoreFactors(
            agents: [], baselines: ["DISA STIG", "CIS Level 1"])
        XCTAssertEqual(resolved, [Factor(.mscp, weight: 10, target: "CIS Level 1")])
    }

    // MARK: - The name matcher

    func testConfiguredNameMatchesTrimmedAndCaseInsensitively() {
        let names = [" Falcon ", "", "Nessus"]
        XCTAssertEqual(SecurityControlPolicy.configuredName("falcon", in: names), "Falcon")
        XCTAssertEqual(SecurityControlPolicy.configuredName("  NESSUS\n", in: names), "Nessus")
        XCTAssertNil(SecurityControlPolicy.configuredName("Splunk", in: names))
        XCTAssertNil(SecurityControlPolicy.configuredName("", in: names), "a blank name is no name")
        XCTAssertNil(SecurityControlPolicy.configuredName("   ", in: [""]))
        XCTAssertNil(SecurityControlPolicy.configuredName(nil, in: names))
    }

    // MARK: - From a whole config

    /// `ReportConfig.resolvedScoreFactors` reads the agents and baselines from the same file,
    /// skipping an agent with no name.
    func testAConfigResolvesItsOwnAgentsAndBaselines() throws {
        let config = try ConfigLoader.loadFromString("""
            security_agents:
              - name: Falcon
                column: Falcon State
                connected_value: connected
              - name: ""
                column: Other
                connected_value: connected
            compliance:
              enabled: true
              baselines:
                - name: STIG
                  failures_count_column: STIG Count
            """)
        let resolved = config.resolvedScoreFactors
        XCTAssertEqual(resolved.map(\.id), Factor.nativeDefaults.map(\.id)
            + ["mscp", "agent:Falcon"])
    }

    func testAConfigWithoutAgentsOrBaselinesScoresTheNativeFactorsAlone() throws {
        let config = try ConfigLoader.loadFromString("thresholds:\n  stale_device_days: 30\n")
        XCTAssertEqual(config.resolvedScoreFactors, Factor.nativeDefaults)
    }

    /// The pre-baselines `failures_count_column` shape synthesises one baseline, which turns
    /// the mSCP default on.
    func testTheLegacySingleBaselineShapeCountsAsABaseline() throws {
        let config = try ConfigLoader.loadFromString("""
            compliance:
              enabled: true
              failures_count_column: Count
            """)
        XCTAssertTrue(config.resolvedScoreFactors.contains { $0.kind == .mscp })
    }
}
