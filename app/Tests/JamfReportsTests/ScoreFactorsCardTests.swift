import XCTest
@testable import JamfReports

/// The pure parts of the Config › Scoring factors card: which factors the "Add factor" menu
/// offers, the status line and the part of the score each row shows, and how a stepper edit
/// replaces one weight. No view body is built here.
@MainActor
final class ScoreFactorsCardTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor
    private typealias Card = ScoreFactorsCard

    private func snapshot(
        agents: [String] = [], baselines: [String] = [],
        measures: [Factor: SecurityScoreMeasure] = [:]
    ) -> ScoreFactorsSnapshot {
        ScoreFactorsSnapshot(
            agents: agents, baselines: baselines, staleDays: 30,
            measures: Dictionary(uniqueKeysWithValues: measures.map { ($0.key.key, $0.value) }))
    }

    // MARK: - addOptions

    func testEveryNativeFactorIsOfferedWhenTheListIsEmpty() {
        let options = Card.addOptions([], agents: [], baselines: [])
        XCTAssertEqual(options, Factor.nativeDefaults)
    }

    func testAListedFactorIsNotOfferedAgain() {
        let listed = Factor.nativeDefaults.filter { $0.kind != .sip && $0.kind != .checkedIn }
        let options = Card.addOptions(listed, agents: [], baselines: [])
        XCTAssertEqual(options.map(\.id), ["sip", "checked_in"])
        XCTAssertEqual(options.map(\.weight), [10, 5], "each at its default weight")
    }

    func testAFullNativeListWithNothingConfiguredOffersNothing() {
        XCTAssertEqual(Card.addOptions(Factor.nativeDefaults, agents: [], baselines: []), [])
    }

    /// mSCP is offered, unnamed and at 10, only once a baseline is configured and no mSCP factor
    /// is listed; with several baselines each is offered by name as well.
    func testMSCPIsOfferedOnlyWithABaselineAndOnlyOnceUnlessNamed() {
        let natives = Factor.nativeDefaults
        XCTAssertEqual(Card.addOptions(natives, agents: [], baselines: []), [])

        let one = Card.addOptions(natives, agents: [], baselines: ["STIG"])
        XCTAssertEqual(one, [Factor(.mscp, weight: 10)])

        let two = Card.addOptions(natives, agents: [], baselines: ["STIG", "CIS"])
        XCTAssertEqual(two.map(\.id), ["mscp", "mscp:STIG", "mscp:CIS"])

        let listedFirst = natives + [Factor(.mscp, weight: 10)]
        XCTAssertEqual(Card.addOptions(listedFirst, agents: [], baselines: ["STIG"]), [])
        XCTAssertEqual(
            Card.addOptions(listedFirst, agents: [], baselines: ["STIG", "CIS"]).map(\.id),
            ["mscp:STIG", "mscp:CIS"])

        let namedListed = natives + [Factor(.mscp, weight: 10, target: "stig")]
        XCTAssertEqual(
            Card.addOptions(namedListed, agents: [], baselines: ["STIG", "CIS"]).map(\.id),
            ["mscp:CIS"], "a listed baseline matches by key, ignoring case")
    }

    /// One option per named agent at 5; a blank name is skipped and a listed agent is not
    /// offered again, whatever its case.
    func testEachNamedAgentNotListedIsOffered() {
        let natives = Factor.nativeDefaults
        let options = Card.addOptions(
            natives + [Factor(.agent, weight: 5, target: "falcon")],
            agents: ["Falcon", "Nessus", "  ", ""], baselines: [])
        XCTAssertEqual(options, [Factor(.agent, weight: 5, target: "Nessus")])
    }

    func testOptionsComeInTheTabsOrderNativeThenMSCPThenAgents() {
        let options = Card.addOptions([], agents: ["Falcon"], baselines: ["STIG"])
        XCTAssertEqual(options.map(\.id),
                       Factor.nativeDefaults.map(\.id) + ["mscp", "agent:Falcon"])
    }

    // MARK: - status

    private func status(
        _ factor: Factor, _ snapshot: ScoreFactorsSnapshot = ScoreFactorsSnapshot(),
        policy: SecurityControlPolicy = .default
    ) -> String {
        Card.status(of: factor, snapshot: snapshot, policy: policy)
    }

    func testStatusShowsTheShareWhenTheFactorHasData() {
        let sip = Factor(.sip, weight: 10)
        let snap = snapshot(measures: [sip: SecurityScoreMeasure(passing: 9, evaluated: 10)])
        XCTAssertEqual(status(sip, snap), "90.0% of Macs pass")
        let third = snapshot(measures: [sip: SecurityScoreMeasure(passing: 1, evaluated: 3)])
        XCTAssertEqual(status(sip, third), "33.3% of Macs pass")
    }

    func testStatusSaysNoDataYetWithoutAShare() {
        let sip = Factor(.sip, weight: 10)
        XCTAssertEqual(status(sip), "No data yet")
        let judgedNone = snapshot(measures: [sip: SecurityScoreMeasure(passing: 0, evaluated: 0)])
        XCTAssertEqual(status(sip, judgedNone), "No data yet")
    }

    func testStatusNamesAControlSetToIgnore() {
        let policy = SecurityControlPolicy(sip: .ignore, gatekeeper: .warning)
        XCTAssertEqual(status(Factor(.sip, weight: 10), policy: policy),
                       "Not counted: System Integrity Protection is set to Ignore above")
        XCTAssertEqual(status(Factor(.gatekeeper, weight: 5), policy: policy), "No data yet",
                       "a warning still counts")
    }

    func testStatusNamesAnAgentOrBaselineThatDoesNotExist() {
        let snap = snapshot(agents: ["Falcon"], baselines: ["STIG"])
        XCTAssertEqual(status(Factor(.agent, weight: 5, target: "Ghost"), snap),
                       "Not counted: no security agent has this name")
        XCTAssertEqual(status(Factor(.agent, weight: 5, target: "falcon"), snap), "No data yet")
        XCTAssertEqual(status(Factor(.mscp, weight: 5, target: "Nope"), snap),
                       "Not counted: no mSCP baseline has this name")
        XCTAssertEqual(status(Factor(.mscp, weight: 5, target: "stig"), snap), "No data yet")
        XCTAssertEqual(status(Factor(.mscp, weight: 5), snap), "No data yet")
        XCTAssertEqual(status(Factor(.mscp, weight: 5), snapshot()),
                       "Not counted: no mSCP baseline is configured")
        XCTAssertEqual(status(Factor(.mscp, weight: 5, target: "STIG"), snapshot()),
                       "Not counted: no mSCP baseline is configured")
    }

    // MARK: - scoringWeight and part

    private func scoring(
        _ factors: [Factor], _ snap: ScoreFactorsSnapshot,
        policy: SecurityControlPolicy = .default
    ) -> [String: Double] {
        var listed = policy
        listed.scoreFactors = factors
        return Card.scoringWeight(factors, snapshot: snap, policy: listed)
    }

    private let measured = SecurityScoreMeasure(passing: 1, evaluated: 2)

    func testOnlyFactorsWithDataAndAWeightScore() {
        let fileVault = Factor(.fileVault, weight: 15)
        let sip = Factor(.sip, weight: 10)
        let firewall = Factor(.firewall, weight: 0)
        let gatekeeper = Factor(.gatekeeper, weight: 5)
        let snap = snapshot(measures: [
            fileVault: measured, sip: measured, firewall: measured,
            gatekeeper: SecurityScoreMeasure(passing: 0, evaluated: 0),
        ])
        XCTAssertEqual(scoring([fileVault, sip, firewall, gatekeeper], snap),
                       ["filevault": 15, "sip": 10],
                       "weight 0 and a factor that judged no Mac do not score")
    }

    func testAControlAtIgnoreOrAnUnmatchedAgentDoesNotScore() {
        let sip = Factor(.sip, weight: 10)
        let ghost = Factor(.agent, weight: 5, target: "Ghost")
        let falcon = Factor(.agent, weight: 5, target: "falcon")
        let snap = snapshot(agents: ["Falcon"], measures: [
            sip: measured, ghost: measured, falcon: measured,
        ])
        let policy = SecurityControlPolicy(sip: .ignore)
        XCTAssertEqual(scoring([sip, ghost, falcon], snap, policy: policy), ["agent:falcon": 5])
    }

    func testPartIsTheFactorsShareOfTheScoringWeight() {
        let scoring = ["filevault": 15.0, "sip": 10.0, "firewall": 10.0, "gatekeeper": 5.0]
        let parts = ["filevault", "sip", "firewall", "gatekeeper"].compactMap { id in
            Factor.Kind(rawValue: id).flatMap {
                Card.part(Factor($0, weight: 1), of: scoring)
            }
        }
        XCTAssertEqual(parts, [37.5, 25, 25, 12.5])
        XCTAssertEqual(parts.reduce(0, +), 100, accuracy: 0.0001)
    }

    func testPartIsNilForAFactorThatDoesNotScoreOrWhenNothingScores() {
        XCTAssertNil(Card.part(Factor(.sip, weight: 10), of: ["filevault": 15]))
        XCTAssertNil(Card.part(Factor(.sip, weight: 10), of: [:]))
        XCTAssertNil(Card.part(Factor(.sip, weight: 10), of: ["sip": 0]))
    }

    // MARK: - replacing

    func testReplacingChangesOnlyTheMatchingFactorsWeight() {
        let factors = [
            Factor(.fileVault, weight: 15), Factor(.agent, weight: 5, target: "Falcon"),
            Factor(.osCurrent, weight: 15, graceDays: 45),
        ]
        let changed = Card.replacing(factors[2], weight: 20, in: factors)
        XCTAssertEqual(changed, [
            Factor(.fileVault, weight: 15), Factor(.agent, weight: 5, target: "Falcon"),
            Factor(.osCurrent, weight: 20, graceDays: 45),
        ])
    }

    func testReplacingMatchesByKeyIgnoringCaseAndKeepsTheListedSpelling() {
        let factors = [Factor(.agent, weight: 5, target: "Falcon")]
        let changed = Card.replacing(
            Factor(.agent, weight: 99, target: "FALCON"), weight: 8, in: factors)
        XCTAssertEqual(changed, [Factor(.agent, weight: 8, target: "Falcon")])
    }

    func testReplacingClampsTheWeightToZeroThroughOneHundred() {
        let sip = Factor(.sip, weight: 10)
        XCTAssertEqual(Card.replacing(sip, weight: 150, in: [sip]).first?.weight, 100)
        XCTAssertEqual(Card.replacing(sip, weight: -5, in: [sip]).first?.weight, 0)
        XCTAssertEqual(Card.replacing(sip, weight: 0, in: [sip]).first?.weight, 0)
    }

    func testReplacingAFactorNotInTheListChangesNothing() {
        let factors = [Factor(.fileVault, weight: 15)]
        XCTAssertEqual(Card.replacing(Factor(.sip, weight: 1), weight: 5, in: factors), factors)
    }

    // MARK: - The snapshot behind the rows

    /// The card measures every factor it can list, not only the listed ones, so a factor shows
    /// its share as soon as it is added: the native ones, each configured agent, the first
    /// baseline and each named baseline.
    func testTheSnapshotMeasuresEveryFactorTheCardCanList() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-factors-card-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "factors-card"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try """
            thresholds:
              stale_device_days: 45
            security_agents:
              - name: Falcon
                column: Falcon State
                connected_value: connected
            compliance:
              enabled: true
              baselines:
                - name: Baseline A
                  failures_count_column: Count A
                - name: Baseline B
                  failures_count_column: Count B
            security_policy:
              score_factors:
                - {factor: sip, weight: 10}
            """.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true,
            encoding: .utf8)
        let when = Date().addingTimeInterval(-3600)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: when,
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 9, sip: 10, firewall: 8, gatekeeper: 10))
        var rows: [[String: Any]] = []
        for index in 0..<4 {
            let device = "mac-\(index)"
            rows.append(GoldenFleetWorkspace.eaRow(
                device: device, ea: "Falcon State", value: index < 3 ? "connected" : "off"))
            rows.append(GoldenFleetWorkspace.eaRow(device: device, ea: "Count A", value: index))
            rows.append(GoldenFleetWorkspace.eaRow(device: device, ea: "Count B", value: 0))
        }
        _ = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: when, rows: rows)

        let loaded = ScoreFactorsSnapshot.load(profile: profile)

        XCTAssertEqual(loaded.agents, ["Falcon"])
        XCTAssertEqual(loaded.baselines, ["Baseline A", "Baseline B"])
        XCTAssertEqual(loaded.staleDays, 45)
        XCTAssertEqual(loaded.measures["sip"], SecurityScoreMeasure(passing: 10, evaluated: 10))
        XCTAssertEqual(loaded.measures["filevault"],
                       SecurityScoreMeasure(passing: 9, evaluated: 10),
                       "FileVault is measured though the list holds only SIP")
        XCTAssertEqual(loaded.measures["agent:falcon"],
                       SecurityScoreMeasure(passing: 3, evaluated: 10))
        XCTAssertEqual(loaded.measures["mscp"], SecurityScoreMeasure(passing: 1, evaluated: 4),
                       "the first baseline: only mac-0 has no failures")
        XCTAssertEqual(loaded.measures["mscp:baseline a"],
                       SecurityScoreMeasure(passing: 1, evaluated: 4))
        XCTAssertEqual(loaded.measures["mscp:baseline b"],
                       SecurityScoreMeasure(passing: 4, evaluated: 4))
        XCTAssertNil(loaded.measures["secure_boot"]?.share, "no computers snapshot")
    }

    func testTheSnapshotOfAProfileWithNoWorkspaceIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-factors-card-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(ScoreFactorsSnapshot.load(profile: "nothing-here"), ScoreFactorsSnapshot())
    }
}
