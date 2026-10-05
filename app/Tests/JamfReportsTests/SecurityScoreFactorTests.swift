import XCTest
@testable import JamfReports

/// The factor value type behind `security_policy.score_factors`: what a workspace scores by
/// default, how a factor is identified, and the `securityScoreBasis` string that says which
/// definition a stored score was computed under. Design:
/// docs/superpowers/specs/2026-10-05-security-score-factors-design.md.
final class SecurityScoreFactorTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor

    // MARK: - Defaults

    /// The design's native list, in the order the Scoring tab shows it, with its weights.
    func testNativeDefaultsAreTheDesignsFactorsInOrder() {
        XCTAssertEqual(Factor.nativeDefaults.map(\.id), [
            "filevault", "sip", "firewall", "gatekeeper", "secure_boot", "bootstrap_token",
            "os_current", "xprotect_current", "patch_compliance", "checked_in",
        ])
        XCTAssertEqual(Factor.nativeDefaults.map(\.weight), [15, 10, 10, 5, 5, 5, 15, 5, 10, 5])
        XCTAssertEqual(Factor.nativeDefaults.map(\.weight).reduce(0, +), 85)
        XCTAssertTrue(Factor.nativeDefaults.allSatisfy { $0.graceDays == nil && $0.target == nil },
                      "the defaults leave the grace period and the target to their own defaults")
    }

    func testDefaultsWithoutAgentsOrABaselineAreTheNativeFactorsAlone() {
        XCTAssertEqual(Factor.defaults(agents: [], hasBaseline: false), Factor.nativeDefaults)
    }

    /// mSCP is a default only for a workspace that configures a baseline; it follows the native
    /// factors, at 10, and scores the first baseline (no target).
    func testMSCPIsADefaultOnlyWithABaseline() {
        let factors = Factor.defaults(agents: [], hasBaseline: true)
        XCTAssertEqual(factors.count, Factor.nativeDefaults.count + 1)
        XCTAssertEqual(factors.last, Factor(.mscp, weight: 10))
        XCTAssertNil(factors.last?.target)
        XCTAssertFalse(
            Factor.defaults(agents: [], hasBaseline: false).contains { $0.kind == .mscp })
    }

    /// One agent factor at 5 per named agent, after mSCP; a blank name is skipped and a name
    /// that differs only by case or surrounding space counts once.
    func testEachNamedAgentIsADefaultOnceAndBlankNamesAreSkipped() {
        let factors = Factor.defaults(
            agents: ["CrowdStrike Falcon", "", "   ", "crowdstrike falcon ", "Nessus"],
            hasBaseline: true)
        let tail = Array(factors.dropFirst(Factor.nativeDefaults.count))
        XCTAssertEqual(tail.map(\.id), ["mscp", "agent:CrowdStrike Falcon", "agent:Nessus"])
        XCTAssertEqual(tail.map(\.weight), [10, 5, 5])
    }

    // MARK: - Identity

    func testIdentityIsTheKindOrTheKindWithTheTarget() {
        XCTAssertEqual(Factor(.fileVault, weight: 1).id, "filevault")
        XCTAssertEqual(Factor(.secureBoot, weight: 1).id, "secure_boot")
        XCTAssertEqual(Factor(.mscp, weight: 1).id, "mscp")
        XCTAssertEqual(Factor(.mscp, weight: 1, target: "Baseline A").id, "mscp:Baseline A")
        XCTAssertEqual(Factor(.agent, weight: 1, target: "CrowdStrike Falcon").id,
                       "agent:CrowdStrike Falcon")
    }

    /// The key is what a list holds once and what measures are looked up by: names match the
    /// way `security_agents` names do, case-insensitively.
    func testKeyIsTheLowercasedIdentity() {
        XCTAssertEqual(Factor(.agent, weight: 1, target: "CrowdStrike Falcon").key,
                       "agent:crowdstrike falcon")
        XCTAssertEqual(Factor(.agent, weight: 1, target: "FALCON").key,
                       Factor(.agent, weight: 9, target: " falcon ").key)
        XCTAssertNotEqual(Factor(.mscp, weight: 1).key, Factor(.mscp, weight: 1, target: "A").key,
                          "the first baseline and a named one are different factors")
    }

    func testAGraceDaysValueIsKeptOnlyForTheKindsThatHaveAGracePeriod() {
        XCTAssertEqual(Factor(.osCurrent, weight: 1, graceDays: 10).graceDays, 10)
        XCTAssertEqual(Factor(.xprotectCurrent, weight: 1, graceDays: 0).graceDays, 0)
        for kind in Factor.Kind.allCases where kind.defaultGraceDays == nil {
            XCTAssertNil(Factor(kind, weight: 1, graceDays: 10).graceDays, "\(kind)")
        }
        XCTAssertEqual(Factor(.osCurrent, weight: 1).resolvedGraceDays, 30)
        XCTAssertEqual(Factor(.xprotectCurrent, weight: 1).resolvedGraceDays, 14)
        XCTAssertEqual(Factor(.osCurrent, weight: 1, graceDays: 7).resolvedGraceDays, 7)
        XCTAssertEqual(Factor(.sip, weight: 1).resolvedGraceDays, 0)
    }

    /// Only an agent or an mSCP baseline carries a name, trimmed; a blank name is no name.
    func testATargetIsKeptOnlyForAgentsAndBaselinesAndIsTrimmed() {
        XCTAssertEqual(Factor(.agent, weight: 1, target: "  Falcon \n").target, "Falcon")
        XCTAssertEqual(Factor(.mscp, weight: 1, target: " Baseline A ").target, "Baseline A")
        XCTAssertNil(Factor(.mscp, weight: 1, target: "   ").target)
        XCTAssertNil(Factor(.agent, weight: 1, target: "").target)
        XCTAssertNil(Factor(.sip, weight: 1, target: "Falcon").target)
        XCTAssertEqual(Factor(.sip, weight: 1, target: "Falcon").id, "sip")
    }

    func testOnlyTheFourControlsMapToAControl() {
        XCTAssertEqual(Factor.Kind.allCases.compactMap(\.control),
                       [.fileVault, .sip, .firewall, .gatekeeper])
    }

    // MARK: - Basis

    func testBasisIsIdEqualsWeightInListOrder() {
        let factors = [
            Factor(.fileVault, weight: 15), Factor(.sip, weight: 10),
            Factor(.agent, weight: 5, target: "CrowdStrike Falcon"),
        ]
        XCTAssertEqual(Factor.basis(factors), "filevault=15,sip=10,agent:CrowdStrike Falcon=5")
        XCTAssertEqual(Factor.basis(Array(factors.reversed())),
                       "agent:CrowdStrike Falcon=5,sip=10,filevault=15",
                       "list order is part of the definition")
        XCTAssertEqual(Factor.basis([]), "")
    }

    /// A changed weight is a changed definition, so the basis names the weight; a fractional
    /// weight is written without trailing zeros.
    func testBasisCarriesTheWeightsSoAChangedWeightIsADifferentBasis() {
        XCTAssertNotEqual(Factor.basis([Factor(.sip, weight: 10)]),
                          Factor.basis([Factor(.sip, weight: 11)]))
        XCTAssertEqual(Factor.basis([Factor(.sip, weight: 12.5)]), "sip=12.5")
        XCTAssertEqual(Factor.weightText(15), "15")
        XCTAssertEqual(Factor.weightText(0), "0")
        XCTAssertEqual(Factor.weightText(7.25), "7.25")
    }

    /// `,` and `=` separate the basis and `%` is the escape, so a name holding any of them is
    /// percent-encoded and still reads as one factor.
    func testBasisEscapesSeparatorsInANameAndReadsThemBack() {
        let name = "Acme, Inc. A=B 100% (x)"
        let basis = Factor.basis([Factor(.agent, weight: 5, target: name), Factor(.sip, weight: 3)])
        XCTAssertEqual(basis, "agent:Acme%2C Inc. A%3DB 100%25 (x)=5,sip=3")
        XCTAssertEqual(Factor.labels(inBasis: basis), ["\(name) connected", "SIP"])
    }

    /// A name that already spells an escape is not decoded twice.
    func testBasisEscapingRoundTripsALiteralEscapeSequence() {
        let name = "100%2C pure"
        let basis = Factor.basis([Factor(.mscp, weight: 10, target: name)])
        XCTAssertEqual(basis, "mscp:100%252C pure=10")
        XCTAssertEqual(Factor.labels(inBasis: basis), ["mSCP: \(name)"])
    }

    // MARK: - Labels

    func testLabelsNameTheFactorsTheWayScreensShowThem() {
        XCTAssertEqual(Factor(.fileVault, weight: 1).label(), "FileVault")
        XCTAssertEqual(Factor(.osCurrent, weight: 1).label(), "macOS current (30-day grace)")
        XCTAssertEqual(Factor(.osCurrent, weight: 1, graceDays: 45).label(),
                       "macOS current (45-day grace)")
        XCTAssertEqual(Factor(.xprotectCurrent, weight: 1).label(),
                       "XProtect current (14-day grace)")
        XCTAssertEqual(Factor(.checkedIn, weight: 1).label(), "Checked in recently")
        XCTAssertEqual(Factor(.checkedIn, weight: 1).label(staleDays: 45),
                       "Checked in within 45 days")
        XCTAssertEqual(Factor(.mscp, weight: 1).label(), "mSCP baseline")
        XCTAssertEqual(Factor(.mscp, weight: 1, target: "STIG").label(), "mSCP: STIG")
        XCTAssertEqual(Factor(.agent, weight: 1, target: "Falcon").label(), "Falcon connected")
    }

    func testLabelsInTheCurrentBasisFormat() {
        let basis = "filevault=15,agent:Falcon=5,mscp:Base A=10,checked_in=5,os_current=15"
        XCTAssertEqual(
            Factor.labels(inBasis: basis, staleDays: 45),
            ["FileVault", "Falcon connected", "mSCP: Base A", "Checked in within 45 days",
             "macOS current (30-day grace)"])
    }

    /// An earlier build wrote metric names, whose `crowdstrike` was the EDR agent. Given the
    /// agent's name it reads as that agent; otherwise as a generic EDR agent. An unknown word
    /// is dropped.
    func testLabelsInAnEarlierBuildsBasis() {
        let old = "fileVault,sip,firewall,crowdstrike,mscp"
        XCTAssertEqual(
            Factor.labels(inBasis: old, edrAgentName: "Falcon"),
            ["FileVault", "SIP", "Firewall", "Falcon connected", "mSCP baseline"])
        XCTAssertEqual(
            Factor.labels(inBasis: old),
            ["FileVault", "SIP", "Firewall", "EDR agent", "mSCP baseline"])
        XCTAssertEqual(
            Factor.labels(inBasis: old, edrAgentName: ""),
            ["FileVault", "SIP", "Firewall", "EDR agent", "mSCP baseline"])
        XCTAssertEqual(
            Factor.labels(inBasis: "fileVault,bogus,xprotect,cve,secureBoot"),
            ["FileVault", "XProtect", "CVE", "Secure Boot"])
        XCTAssertEqual(Factor.labels(inBasis: ""), [])
    }
}
