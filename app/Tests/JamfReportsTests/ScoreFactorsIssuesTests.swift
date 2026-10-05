import XCTest
@testable import JamfReports

/// What the app says about a hand-typed `score_factors`: the loader's issues (one per entry the
/// decoder skipped or read other than as typed, never echoing more than `displayText` allows)
/// and the Config Doctor rows built from them. The decoder never throws, so these are how a
/// typo is found.
final class ScoreFactorsIssuesTests: XCTestCase {

    private typealias Issue = SecurityPolicyIssue

    private let profile = "jrc-factor-issues"

    private func withWorkspacesRoot(_ body: () throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-factor-issues-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    /// The issues for a `score_factors` list whose items are `items` (flush left).
    private func issues(_ items: String) throws -> [Issue] {
        var found: [Issue] = []
        try withWorkspacesRoot {
            let indented = items.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
            try writeConfig("security_policy:\n  score_factors:\n" + indented + "\n")
            found = SecurityPolicyConfigLoader.issues(profile: profile)
        }
        return found
    }

    private func writeConfig(_ yaml: String) throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try yaml.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true,
            encoding: .utf8)
    }

    // MARK: - The loader's issues

    func testAValidListHasNoIssues() throws {
        XCTAssertEqual(try issues("""
            - {factor: filevault, weight: 15}
            - {factor: os_current, weight: 10, grace_days: 45}
            - {factor: agent, agent: Falcon, weight: 5}
            - {factor: mscp, baseline: STIG, weight: 10}
            - {factor: sip, weight: "7.5"}
            """), [])
    }

    func testANullListAndAnEmptyListHaveNoIssues() throws {
        try withWorkspacesRoot {
            try writeConfig("security_policy:\n  score_factors:\n")
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
            try writeConfig("security_policy:\n  score_factors: []\n")
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testAKeyThatIsNotAListIsNamedWithWhatTheAppUsesInstead() throws {
        try withWorkspacesRoot {
            for (typed, shown) in [("5", "5"), ("{sip: 5}", "{…}"), ("sip", "sip")] {
                try writeConfig("security_policy:\n  score_factors: \(typed)\n")
                XCTAssertEqual(
                    SecurityPolicyConfigLoader.issues(profile: profile),
                    [Issue(keyPath: "security_policy.score_factors", value: shown,
                           used: "the default factors, since this is not a list")],
                    "score_factors: \(typed)")
            }
        }
    }

    func testAnUnknownFactorIsSkippedAndTheKnownOnesAreListed() throws {
        let found = try issues("- {factor: bogus, weight: 5}")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.keyPath, "security_policy.score_factors[0]")
        XCTAssertEqual(found.first?.value, "bogus")
        let used = try XCTUnwrap(found.first?.used)
        XCTAssertTrue(used.hasPrefix("skipped: factor is one of filevault, sip, firewall,"), used)
        XCTAssertTrue(used.hasSuffix("mscp, agent"), used)
    }

    func testAMissingFactorKeyIsAnUnknownFactorWithNothingToShow() throws {
        let found = try issues("- {weight: 5}")
        XCTAssertEqual(found.first?.keyPath, "security_policy.score_factors[0]")
        XCTAssertEqual(found.first?.value, "")
        XCTAssertEqual(found.first?.used.hasPrefix("skipped: factor is one of"), true)
    }

    func testABadWeightIsSkippedWithWhatTheFileSaid() throws {
        let found = try issues("""
            - {factor: sip, weight: 150}
            - {factor: firewall, weight: abc}
            - {factor: gatekeeper}
            - {factor: secure_boot, weight: -1}
            - {factor: bootstrap_token, weight: [1]}
            """)
        let skipped = "skipped: weight is a number from 0 to 100"
        XCTAssertEqual(found, [
            Issue(keyPath: "security_policy.score_factors[0]", value: "150", used: skipped),
            Issue(keyPath: "security_policy.score_factors[1]", value: "abc", used: skipped),
            Issue(keyPath: "security_policy.score_factors[2]", value: "", used: skipped),
            Issue(keyPath: "security_policy.score_factors[3]", value: "-1", used: skipped),
            Issue(keyPath: "security_policy.score_factors[4]", value: "[1]", used: skipped),
        ])
    }

    func testAnAgentEntryWithoutAnAgentNameIsSkipped() throws {
        let found = try issues("""
            - {factor: agent, weight: 5}
            - {factor: agent, agent: "  ", weight: 5}
            """)
        XCTAssertEqual(found.map(\.keyPath), [
            "security_policy.score_factors[0]", "security_policy.score_factors[1]",
        ])
        for issue in found {
            XCTAssertEqual(issue.used, "skipped: an agent entry needs the agent's name under agent")
        }
    }

    func testAnEntryThatIsNotAMappingIsSkipped() throws {
        let found = try issues("""
            - filevault
            - 7
            """)
        XCTAssertEqual(found, [
            Issue(keyPath: "security_policy.score_factors[0]", value: "filevault",
                  used: "skipped: an entry needs factor and weight"),
            Issue(keyPath: "security_policy.score_factors[1]", value: "7",
                  used: "skipped: an entry needs factor and weight"),
        ])
    }

    /// The entry stays in the list with the kind's own grace period, and the issue says which.
    func testABadGraceDaysUsesTheDefaultAndNamesIt() throws {
        let found = try issues("""
            - {factor: os_current, weight: 5, grace_days: 400}
            - {factor: xprotect_current, weight: 5, grace_days: soon}
            """)
        XCTAssertEqual(found, [
            Issue(keyPath: "security_policy.score_factors[0].grace_days", value: "400",
                  used: "30 days, since grace_days is a whole number from 0 to 365"),
            Issue(keyPath: "security_policy.score_factors[1].grace_days", value: "soon",
                  used: "14 days, since grace_days is a whole number from 0 to 365"),
        ])
    }

    func testGraceDaysOnAKindWithoutOneIsNotRead() throws {
        let found = try issues("- {factor: sip, weight: 5, grace_days: 10}")
        XCTAssertEqual(found, [
            Issue(keyPath: "security_policy.score_factors[0].grace_days", value: "10",
                  used: "not read: sip has no grace period"),
        ])
    }

    /// A key inside an entry that the app does not read is named by its path, with no value:
    /// nothing is echoed for a key the app does not understand.
    func testAnUnknownKeyInsideAnEntryIsNamedWithoutItsValue() throws {
        let found = try issues("- {factor: sip, weight: 5, colour: red}")
        XCTAssertEqual(found, [
            Issue(keyPath: "security_policy.score_factors[0].colour", value: "", used: ""),
        ])
    }

    func testAFactorListedTwiceNamesTheEntryThatWasReplaced() throws {
        let found = try issues("""
            - {factor: sip, weight: 5}
            - {factor: firewall, weight: 5}
            - {factor: sip, weight: 7}
            - {factor: agent, agent: Falcon, weight: 5}
            - {factor: agent, agent: falcon, weight: 5}
            """)
        XCTAssertEqual(found, [
            Issue(keyPath: "security_policy.score_factors[0]", value: "sip",
                  used: "replaced by score_factors[2], which lists it again"),
            Issue(keyPath: "security_policy.score_factors[3]", value: "agent:falcon",
                  used: "replaced by score_factors[4], which lists it again"),
        ])
    }

    /// A skipped entry does not count as listing its factor, so it is not "replaced".
    func testASkippedEntryIsNotAReplacedOne() throws {
        let found = try issues("""
            - {factor: sip, weight: 150}
            - {factor: sip, weight: 7}
            """)
        XCTAssertEqual(found.map(\.used), ["skipped: weight is a number from 0 to 100"])
    }

    func testIssueValuesAreCleanedOfControlCharacters() throws {
        let found = try issues("- {factor: \"bo\u{202E}gus\u{1B}\", weight: 5}")
        let value = try XCTUnwrap(found.first?.value)
        XCTAssertFalse(value.isEmpty)
        XCTAssertFalse(value.contains("\u{1B}"))
        XCTAssertFalse(value.contains("\u{202E}"))
    }

    /// `used` and the keys come from what the decoder applied, so the issues and the loaded
    /// policy cannot disagree: the entry the loader names is the one the policy lacks.
    func testIssuesAndTheLoadedPolicyAgree() throws {
        try withWorkspacesRoot {
            try writeConfig("""
                security_policy:
                  score_factors:
                    - {factor: filevault, weight: 30}
                    - {factor: sip, weight: 150}
                    - {factor: agent, agent: Falcon, weight: "25"}
                    - {factor: os_current, weight: 5, grace_days: 999}
                """)
            let policy = SecurityPolicyConfigLoader.load(profile: profile)
            let found = SecurityPolicyConfigLoader.issues(profile: profile)

            XCTAssertEqual(policy.scoreFactors, [
                SecurityScoreFactor(.fileVault, weight: 30),
                SecurityScoreFactor(.agent, weight: 25, target: "Falcon"),
                SecurityScoreFactor(.osCurrent, weight: 5),
            ])
            XCTAssertEqual(found.map(\.keyPath), [
                "security_policy.score_factors[1]", "security_policy.score_factors[3].grace_days",
            ])
            XCTAssertEqual(policy.scoreFactors?.last?.resolvedGraceDays, 30,
                           "the 30 days the issue says were used")
        }
    }

    // MARK: - The Doctor rows for the issues

    func testTheDoctorWordsAnEntryIssueAsAFactorProblem() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [Issue(
                keyPath: "security_policy.score_factors[1]", value: "150",
                used: "skipped: weight is a number from 0 to 100")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.title, "security_policy.score_factors[1]")
        XCTAssertEqual(rows.first?.detail,
                       "\"150\" — skipped: weight is a number from 0 to 100")
        XCTAssertEqual(rows.first?.hint,
                       "Fix the entry in config.yaml, or edit the factors in Config > Scoring.")
    }

    func testTheDoctorWordsAnEntryWithNothingTypedAndLeavesUnknownKeysToTheirOwnRows() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [
                Issue(keyPath: "security_policy.score_factors[2]", value: "",
                      used: "skipped: weight is a number from 0 to 100"),
                Issue(keyPath: "security_policy.score_factors[0].colour", value: "", used: ""),
            ],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.count, 1, "an unknown key is reported once, by the unknown-key rows")
        XCTAssertEqual(rows.first?.detail,
                       "This entry is skipped: weight is a number from 0 to 100")
    }

    /// `score_weights` is a retired key: Config Doctor words it as no longer read since 2.9, a
    /// suggestion and not a warning, and does not call it a misspelling of another key.
    func testTheDoctorWordsScoreWeightsAsRetired() throws {
        try withWorkspacesRoot {
            try writeConfig("security_policy:\n  score_weights:\n    sip: 5\n")
            let rows = ConfigDoctorService.unknownKeyRows(profile: profile)
            XCTAssertEqual(rows.map(\.title), ["security_policy.score_weights"])
            XCTAssertEqual(rows.map(\.severity), [.suggest])
            XCTAssertEqual(rows.map(\.detail), ["No longer read since 2.9."])
            XCTAssertFalse(rows.compactMap(\.hint).joined().contains("spelling"))
        }
    }

    // MARK: - Factors the score cannot count

    private func rows(_ yaml: String) throws -> [DoctorRow] {
        ConfigDoctorService.scoreFactorRows(config: try ConfigLoader.loadFromString(yaml))
    }

    private static let agents = """
        security_agents:
          - name: Falcon
            column: Falcon State
            connected_value: connected
        compliance:
          enabled: true
          baselines:
            - name: STIG
              failures_count_column: STIG Count
        """

    func testAnAbsentListHasNoRows() throws {
        XCTAssertEqual(try rows(Self.agents), [])
    }

    func testAnEmptyListWarnsThatTheScoreCountsNothing() throws {
        let found = try rows("security_policy:\n  score_factors: []\n")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.id, "security_policy.score_factors.empty")
        XCTAssertEqual(found.first?.severity, .warn)
        XCTAssertEqual(found.first?.title, "security_policy.score_factors")
        XCTAssertEqual(found.first?.detail,
                       "The list is empty, so the security score counts nothing.")
    }

    func testAnAgentThatMatchesNoSecurityAgentIsNamed() throws {
        let found = try rows(Self.agents + """

            security_policy:
              score_factors:
                - {factor: agent, agent: Falcon, weight: 5}
                - {factor: agent, agent: Ghost, weight: 5}
            """)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.id, "security_policy.score_factors.unmatched.0")
        XCTAssertEqual(found.first?.severity, .warn)
        XCTAssertEqual(found.first?.detail,
                       "\"Ghost\" matches no security_agents entry, so it is not scored.")
    }

    func testABaselineThatMatchesNoBaselineIsNamed() throws {
        let found = try rows(Self.agents + """

            security_policy:
              score_factors:
                - {factor: mscp, baseline: stig, weight: 5}
                - {factor: mscp, baseline: Nope, weight: 5}
            """)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.detail,
                       "\"Nope\" matches no compliance.baselines entry, so it is not scored.")
    }

    func testMSCPWithNoBaselineConfiguredIsNamed() throws {
        let found = try rows("""
            security_policy:
              score_factors:
                - {factor: mscp, weight: 5}
                - {factor: sip, weight: 5}
            """)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.detail,
                       "No compliance.baselines entry is configured, so mSCP is not scored.")
    }

    /// Each unmatched factor has its own row id, in list order.
    func testEachUnmatchedFactorHasItsOwnRow() throws {
        let found = try rows("""
            security_policy:
              score_factors:
                - {factor: agent, agent: One, weight: 5}
                - {factor: agent, agent: Two, weight: 5}
            """)
        XCTAssertEqual(found.map(\.id), [
            "security_policy.score_factors.unmatched.0",
            "security_policy.score_factors.unmatched.1",
        ])
    }

    /// A control set to ignore is left out by the policy, not by a mistake in the list.
    func testAControlAtIgnoreIsNotNamed() throws {
        XCTAssertEqual(try rows("""
            security_policy:
              controls:
                sip: ignore
              score_factors:
                - {factor: sip, weight: 5}
                - {factor: filevault, weight: 5}
            """), [])
    }

    func testTheRowsAreIncludedInTheSecurityPolicySection() throws {
        let config = try ConfigLoader.loadFromString("security_policy:\n  score_factors: []\n")
        try withWorkspacesRoot {
            let all = ConfigDoctorService.securityPolicyRows(profile: profile, config: config)
            XCTAssertTrue(all.contains { $0.id == "security_policy.score_factors.empty" })
        }
    }
}
