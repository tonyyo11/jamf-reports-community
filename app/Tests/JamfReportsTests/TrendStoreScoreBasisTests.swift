import XCTest
@testable import JamfReports

/// Two scores compare only when their `securityScoreBasis` is equal: a changed factor list or
/// weight is a changed definition, not a changed fleet. `comparableSecurityScores` is the run of
/// scored days, ending at the newest, that share one basis; the Overview card, the Trends hero
/// and its pills compare inside it.
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
        TrendStore.comparableSecurityScores(in: days)
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
        XCTAssertEqual(all.comparableSecurityScores(), [79, 80])
        XCTAssertTrue(all.latestSecurityScoresComparable, "the two newest days share a basis")
    }

    /// The newest two scored days on different bases have no change between them.
    func testTheLatestTwoScoresAreNotComparableAcrossABasisChange() {
        let days = [
            day("2026-04-01", score: 90, basis: old),
            day("2026-04-08", score: 79, basis: new),
        ]
        let across = store(days)
        XCTAssertEqual(across.comparableSecurityScores(), [79])
        XCTAssertFalse(across.latestSecurityScoresComparable)
    }

    /// With fewer than two scored days there is no change to compare, so nothing is flagged.
    func testFewerThanTwoScoredDaysAreNotFlagged() {
        XCTAssertTrue(store([]).latestSecurityScoresComparable)
        XCTAssertTrue(
            store([day("2026-04-01", score: 90, basis: old)]).latestSecurityScoresComparable)
        XCTAssertTrue(store([
            day("2026-04-01", score: nil, basis: old), day("2026-04-08", score: 79, basis: new),
        ]).latestSecurityScoresComparable)
    }
}
