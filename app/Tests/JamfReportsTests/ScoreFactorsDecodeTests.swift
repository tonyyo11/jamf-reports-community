import XCTest
@testable import JamfReports

/// `security_policy.score_factors` decodes to `SecurityControlPolicy.scoreFactors`: nil when the
/// key is absent (the defaults apply), otherwise the entries the app can use. Like the rest of
/// `security_policy` it never throws, so one bad entry cannot cost the whole config.yaml.
final class ScoreFactorsDecodeTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor

    private func factors(_ yaml: String) throws -> [Factor]? {
        try ConfigLoader.loadFromString(yaml).resolvedSecurityPolicy.scoreFactors
    }

    /// A `score_factors` list from its items, written flush left here and indented under the key.
    private func block(_ items: String) -> String {
        let indented = items.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
        return "security_policy:\n  score_factors:\n" + indented + "\n"
    }

    // MARK: - Absent, empty, valid

    func testAbsentKeyIsNilSoTheDefaultsApply() throws {
        XCTAssertNil(try factors("thresholds:\n  stale_device_days: 30\n"))
        XCTAssertNil(try factors("security_policy:\n  controls:\n    sip: warning\n"))
        XCTAssertNil(SecurityControlPolicy.default.scoreFactors)
    }

    /// An empty list is a list: the workspace scores nothing, which Config Doctor says.
    func testAnEmptyListIsEmptyNotNil() throws {
        XCTAssertEqual(try factors("security_policy:\n  score_factors: []\n"), [])
    }

    func testValidEntriesDecodeInListOrder() throws {
        let decoded = try factors(block("""
              - factor: sip
                weight: 10
              - factor: filevault
                weight: 15
              - factor: os_current
                weight: 20
                grace_days: 45
              - factor: xprotect_current
                weight: 5
              - factor: agent
                agent: CrowdStrike Falcon
                weight: 5
              - factor: mscp
                baseline: STIG
                weight: 10
              - factor: mscp
                weight: 12
              """))
        // The unnamed mSCP entry is a different factor from the named one, so both stay.
        XCTAssertEqual(decoded, [
            Factor(.sip, weight: 10), Factor(.fileVault, weight: 15),
            Factor(.osCurrent, weight: 20, graceDays: 45),
            Factor(.xprotectCurrent, weight: 5),
            Factor(.agent, weight: 5, target: "CrowdStrike Falcon"),
            Factor(.mscp, weight: 10, target: "STIG"),
            Factor(.mscp, weight: 12),
        ])
        XCTAssertNil(decoded?[3].graceDays, "no grace_days uses the kind's default")
    }

    /// The `factor` word is trimmed and case-insensitive, like a typed level; a name is trimmed.
    func testTheFactorWordAndNamesAreTrimmedAndCaseInsensitive() throws {
        let decoded = try factors(block("""
              - factor: "  FileVault "
                weight: 5
              - factor: AGENT
                agent: "  Falcon  "
                weight: 5
              """))
        XCTAssertEqual(decoded, [
            Factor(.fileVault, weight: 5), Factor(.agent, weight: 5, target: "Falcon"),
        ])
    }

    /// Weights need not add up to 100 and 0 is a weight (the factor is listed but off).
    func testWeightsFromZeroToOneHundredAreRead() throws {
        let decoded = try factors(block("""
              - {factor: sip, weight: 0}
              - {factor: firewall, weight: 100}
              - {factor: gatekeeper, weight: 33}
              """))
        XCTAssertEqual(decoded?.map(\.weight), [0, 100, 33])
    }

    // MARK: - Entries the app cannot use

    func testEntriesTheAppCannotUseAreSkippedAndTheRestAreKept() throws {
        let decoded = try factors(block("""
              - factor: sip
                weight: 10
              - factor: nonsense
                weight: 5
              - factor: firewall
              - factor: gatekeeper
                weight: 101
              - factor: secure_boot
                weight: -1
              - factor: bootstrap_token
                weight: lots
              - factor: agent
                weight: 5
              - factor: agent
                agent: "   "
                weight: 5
              - filevault
              - weight: 9
              - factor: checked_in
                weight: 5
              """))
        XCTAssertEqual(decoded, [Factor(.sip, weight: 10), Factor(.checkedIn, weight: 5)])
    }

    /// A weight of the wrong shape (a list, a mapping) skips the entry, not the decode.
    func testAWeightOfTheWrongShapeSkipsTheEntry() throws {
        let decoded = try factors(block("""
              - factor: sip
                weight: [1, 2]
              - factor: firewall
                weight: {a: 1}
              - factor: gatekeeper
                weight: 4
              """))
        XCTAssertEqual(decoded, [Factor(.gatekeeper, weight: 4)])
    }

    /// A fractional YAML scalar arrives as text and an integer as a number; both are read.
    func testAFractionalWeightIsReadWhetherTypedOrQuoted() throws {
        let decoded = try factors(block("""
              - {factor: sip, weight: 12.5}
              - {factor: firewall, weight: "7.5"}
              - {factor: gatekeeper, weight: " 3 "}
              """))
        XCTAssertEqual(decoded?.map(\.weight), [12.5, 7.5, 3])
    }

    // MARK: - grace_days

    /// A `grace_days` that is not a whole number from 0 to 365 uses the default and keeps the
    /// entry; 0 is a grace period.
    func testGraceDaysOutOfRangeUsesTheDefault() throws {
        let decoded = try factors(block("""
              - {factor: os_current, weight: 5, grace_days: 400}
              - {factor: xprotect_current, weight: 5, grace_days: -1}
              """))
        XCTAssertEqual(decoded?.map(\.graceDays), [nil, nil])
        XCTAssertEqual(decoded?.map(\.resolvedGraceDays), [30, 14])

        for typed in ["abc", "7.5", "[3]"] {
            let odd = try factors(block(
                "- {factor: os_current, weight: 5, grace_days: \(typed)}"))
            XCTAssertEqual(odd, [Factor(.osCurrent, weight: 5)], "grace_days: \(typed)")
        }
    }

    func testGraceDaysInRangeIsKept() throws {
        let decoded = try factors(block("""
              - {factor: os_current, weight: 5, grace_days: 0}
              - {factor: xprotect_current, weight: 5, grace_days: 365}
              - {factor: patch_compliance, weight: 5, grace_days: 10}
              """))
        XCTAssertEqual(decoded?.map(\.graceDays), [0, 365, nil],
                       "a kind without a grace period drops the value")
        let quoted = try factors(block(
            "- {factor: os_current, weight: 5, grace_days: \"21\"}"))
        XCTAssertEqual(quoted?.first?.graceDays, 21)
    }

    // MARK: - Repeats

    /// A factor listed twice counts once, and the last entry wins, as a repeated key does.
    func testARepeatedFactorKeepsTheLastEntry() throws {
        let decoded = try factors(block("""
              - {factor: sip, weight: 5}
              - {factor: filevault, weight: 10}
              - {factor: sip, weight: 7}
              """))
        XCTAssertEqual(decoded, [Factor(.fileVault, weight: 10), Factor(.sip, weight: 7)])
    }

    func testARepeatedAgentOrBaselineMatchesByCaseInsensitiveName() throws {
        let decoded = try factors(block("""
              - {factor: agent, agent: Falcon, weight: 5}
              - {factor: agent, agent: "falcon ", weight: 8}
              - {factor: agent, agent: Nessus, weight: 3}
              - {factor: mscp, baseline: STIG, weight: 5}
              - {factor: mscp, baseline: stig, weight: 6}
              """))
        XCTAssertEqual(decoded, [
            Factor(.agent, weight: 8, target: "falcon"),
            Factor(.agent, weight: 3, target: "Nessus"),
            Factor(.mscp, weight: 6, target: "stig"),
        ])
    }

    // MARK: - Never throws

    /// A key that is not a list reads as absent (the defaults apply) and the rest of the file
    /// still decodes.
    func testAKeyThatIsNotAListReadsAsAbsentAndTheRestDecodes() throws {
        for shape in ["5", "yes", "{sip: 5}", "sip"] {
            let config = try ConfigLoader.loadFromString("""
                thresholds:
                  stale_device_days: 45
                security_policy:
                  controls:
                    sip: warning
                  score_factors: \(shape)
                """)
            XCTAssertNil(config.resolvedSecurityPolicy.scoreFactors, "score_factors: \(shape)")
            XCTAssertEqual(config.resolvedSecurityPolicy.sip, .warning, "score_factors: \(shape)")
            XCTAssertEqual(config.thresholds?.resolvedStaleDays, 45, "score_factors: \(shape)")
        }
    }

    func testBadEntriesLeaveTheOtherPolicyKeysAndTheRestOfTheFileDecoding() throws {
        let config = try ConfigLoader.loadFromString("""
            thresholds:
              stale_device_days: 45
            security_policy:
              controls:
                firewall: ignore
              edr_agent: Falcon
              score_factors:
                - factor: bogus
                - 7
                - [a, b]
                - factor: sip
                  weight: 10
            """)
        let policy = config.resolvedSecurityPolicy
        XCTAssertEqual(policy.scoreFactors, [Factor(.sip, weight: 10)])
        XCTAssertEqual(policy.firewall, .ignore)
        XCTAssertEqual(policy.edrAgent, "Falcon")
        XCTAssertEqual(config.thresholds?.resolvedStaleDays, 45)
    }

    /// `score_weights` was the key before `score_factors`; no released build read it and the
    /// decoder does not either.
    func testScoreWeightsIsNotRead() throws {
        let config = try ConfigLoader.loadFromString(
            "security_policy:\n  score_weights:\n    sip: 5\n")
        XCTAssertNil(config.resolvedSecurityPolicy.scoreFactors)
        XCTAssertEqual(ConfigSchema.retiredKeys["security_policy.score_weights"], "2.9")
    }
}
