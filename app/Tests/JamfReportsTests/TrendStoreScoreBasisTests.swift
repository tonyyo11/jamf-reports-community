import XCTest
@testable import JamfReports

/// Two scores compare only when their `securityScoreBasis` is equal: a changed factor list or
/// weight is a changed definition, not a changed fleet. `comparableValues(of:in:)` is the run of
/// scored days, ending at the newest, that share one basis; the Overview card, the Trends hero
/// and its pills compare inside it. Compliance across the proxy and patch across its basis follow
/// the same rule.
@MainActor
final class TrendStoreScoreBasisTests: XCTestCase {

    private func day(_ date: String, score: Double?, basis: String?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", securityScore: score, securityScoreBasis: basis)
    }

    private let old = "filevault=15,sip=15,firewall=15"
    private let new = "filevault=15,sip=10,firewall=10,gatekeeper=5"

    private func scores(_ days: [DailySummary]) -> [Double] {
        TrendStore.comparableValues(of: .securityScore, in: days) ?? []
    }

    // MARK: - The newest same-basis run

    func testOnlyTheNewestRunOfOneBasisIsReturned() {
        let days = [
            day("2026-10-01", score: 90, basis: old),
            day("2026-10-02", score: 91, basis: old),
            day("2026-10-03", score: 79, basis: new),
            day("2026-10-04", score: 80, basis: new),
            day("2026-10-05", score: 82, basis: new),
        ]
        XCTAssertEqual(scores(days), [79, 80, 82])
    }

    func testOneBasisThroughoutReturnsEveryScore() {
        let days = [
            day("2026-10-01", score: 88, basis: new), day("2026-10-02", score: 89, basis: new),
        ]
        XCTAssertEqual(scores(days), [88, 89])
    }

    /// Only the run ending at the newest day counts: an earlier day on the newest basis, cut
    /// off by a day on another, is not part of it.
    func testAnEarlierRunOfTheSameBasisIsNotJoined() {
        let days = [
            day("2026-10-01", score: 90, basis: new),
            day("2026-10-02", score: 70, basis: old),
            day("2026-10-03", score: 91, basis: new),
        ]
        XCTAssertEqual(scores(days), [91])
    }

    /// A weight change alone is a new basis.
    func testAChangedWeightBreaksTheRun() {
        let days = [
            day("2026-10-01", score: 90, basis: "filevault=15,sip=10"),
            day("2026-10-02", score: 85, basis: "filevault=15,sip=20"),
        ]
        XCTAssertEqual(scores(days), [85])
    }

    /// Days that stored no score carry no basis worth comparing: they neither break a run nor
    /// join one, whatever basis they hold.
    func testDaysWithoutAScoreAreIgnored() {
        let days = [
            day("2026-10-01", score: 80, basis: new),
            day("2026-10-02", score: nil, basis: old),
            day("2026-10-03", score: nil, basis: nil),
            day("2026-10-04", score: 82, basis: new),
            day("2026-10-05", score: nil, basis: old),
        ]
        XCTAssertEqual(scores(days), [80, 82])
    }

    /// Summaries from before the basis was recorded share the nil basis with each other.
    func testDaysWithNoRecordedBasisCompareWithEachOtherNotWithABasis() {
        let days = [
            day("2026-10-01", score: 90, basis: nil),
            day("2026-10-02", score: 91, basis: nil),
            day("2026-10-03", score: 79, basis: new),
        ]
        XCTAssertEqual(scores(days), [79])
        XCTAssertEqual(scores(Array(days.prefix(2))), [90, 91])
    }

    func testTheInputIsOrderedByDateNotByPosition() {
        let days = [
            day("2026-10-05", score: 82, basis: new),
            day("2026-10-01", score: 90, basis: old),
            day("2026-10-03", score: 79, basis: new),
        ]
        XCTAssertEqual(scores(days), [79, 82], "oldest first, from the newest run")
    }

    func testNothingScoredReturnsNothing() {
        XCTAssertEqual(scores([]), [])
        XCTAssertEqual(scores([day("2026-10-01", score: nil, basis: old)]), [])
    }

    // MARK: - On a store, in its range

    private func store(_ days: [DailySummary], range: TrendRange = .all) -> TrendStore {
        TrendStore(summaries: days, range: range)
    }

    func testTheStoreComparesWithinTheDaysItShows() {
        let days = [
            day("2026-04-01", score: 90, basis: old),
            day("2026-04-08", score: 91, basis: old),
            day("2026-04-15", score: 79, basis: new),
            day("2026-04-22", score: 80, basis: new),
        ]
        let all = store(days)
        XCTAssertEqual(all.comparableValues(metric: .securityScore), [79, 80])
        XCTAssertTrue(all.latestValuesComparable(metric: .securityScore),
                      "the two newest days share a basis")
    }

    /// The newest two scored days on different bases have no change between them.
    func testTheLatestTwoScoresAreNotComparableAcrossABasisChange() {
        let days = [
            day("2026-04-01", score: 90, basis: old),
            day("2026-04-08", score: 79, basis: new),
        ]
        let across = store(days)
        XCTAssertEqual(across.comparableValues(metric: .securityScore), [79])
        XCTAssertFalse(across.latestValuesComparable(metric: .securityScore))
    }

    /// With fewer than two scored days there is no change to compare, so nothing is flagged.
    func testFewerThanTwoScoredDaysAreNotFlagged() {
        XCTAssertTrue(store([]).latestValuesComparable(metric: .securityScore))
        XCTAssertTrue(
            store([day("2026-04-01", score: 90, basis: old)])
                .latestValuesComparable(metric: .securityScore))
        XCTAssertTrue(store([
            day("2026-04-01", score: nil, basis: old), day("2026-04-08", score: 79, basis: new),
        ]).latestValuesComparable(metric: .securityScore))
    }

    // MARK: - Compliance and patch

    private func compliance(_ date: String, _ pct: Double, proxy: Bool?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: nil, compliancePct: pct,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", complianceIsProxy: proxy)
    }

    /// The proxy and a benchmark's failure count measure different things.
    func testComplianceComparesOnlyDaysOnOneSideOfTheProxy() {
        let days = [
            compliance("2026-04-01", 96, proxy: true),
            compliance("2026-04-08", 71, proxy: false),
            compliance("2026-04-15", 73, proxy: false),
        ]
        XCTAssertEqual(TrendStore.comparableValues(of: .compliance, in: days), [71, 73])
        let flipped = store(Array(days.prefix(2)))
        XCTAssertEqual(flipped.comparableValues(metric: .compliance), [71])
        XCTAssertFalse(flipped.latestValuesComparable(metric: .compliance))
    }

    func testPatchComparesOnlyDaysOnOneBasis() {
        let days = [
            DailySummary(date: "2026-04-01", totalDevices: 100, fileVaultPct: nil,
                         compliancePct: nil, staleCount: nil, osCurrentPct: nil,
                         crowdstrikePct: nil, patchPct: 80, source: "jamf-cli"),
            DailySummary(date: "2026-04-08", totalDevices: 100, fileVaultPct: nil,
                         compliancePct: nil, staleCount: nil, osCurrentPct: nil,
                         crowdstrikePct: nil, patchPct: 70, source: "jamf-cli",
                         patchPctBasis: DailySummary.deviceWeightedPatchBasis),
        ]
        XCTAssertEqual(TrendStore.comparableValues(of: .patch, in: days), [70])
    }

    /// A metric with one definition has no basis run; every value compares.
    func testAMetricWithOneDefinitionHasNoRun() {
        XCTAssertNil(TrendStore.comparableValues(of: .fileVault, in: []))
    }

    /// The fleet insight gives no prior across the proxy or a score definition change.
    func testTheFleetInsightGivesNoPriorAcrossABasisChange() throws {
        func fact(_ input: FleetInsightInput, _ prefix: String) throws -> FleetInsightInput.Fact {
            try XCTUnwrap(input.facts.first { $0.label.hasPrefix(prefix) })
        }
        let flip = FleetInsightInput.fleet(
            current: compliance("2026-04-08", 96, proxy: true),
            previous: compliance("2026-04-01", 71, proxy: false))
        XCTAssertNil(try fact(flip, "Compliance").prior)
        let same = FleetInsightInput.fleet(
            current: compliance("2026-04-08", 73, proxy: false),
            previous: compliance("2026-04-01", 71, proxy: false))
        XCTAssertEqual(try fact(same, "Compliance").prior, .percent(71))
        let rescored = FleetInsightInput.fleet(
            current: day("2026-04-08", score: 79, basis: new),
            previous: day("2026-04-01", score: 90, basis: old))
        XCTAssertNil(try fact(rescored, "Security score").prior)
    }

    /// The proxy names the figure, so a benchmark label never sits on a proxy number.
    func testTheNewestComplianceFigureDecidesTheProxyTitle() {
        XCTAssertTrue(store([
            compliance("2026-04-01", 71, proxy: false), compliance("2026-04-08", 96, proxy: true),
        ]).latestComplianceIsProxy)
        XCTAssertFalse(store([
            compliance("2026-04-01", 96, proxy: true), compliance("2026-04-08", 71, proxy: false),
        ]).latestComplianceIsProxy)
        XCTAssertFalse(store([]).latestComplianceIsProxy)
    }
}
