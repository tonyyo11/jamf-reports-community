import Foundation
import XCTest
@testable import JamfReports

/// The Automation screen's progress rows for a split collect.
final class SplitCollectCardTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func schedule(_ name: String, multi: Bool = false) -> Schedule {
        Schedule(
            name: name, profile: "alpha", schedule: "Daily 06:00", cadence: "daily",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "lbl.\(name)",
            multiTarget: multi ? MultiTarget(scope: .all) : nil)
    }

    private func state(
        _ label: String, key: String, planned: [String], left: [String], failed: Bool = false
    ) -> TickState {
        var state = TickState()
        state.splitDay[label] = SplitDay(
            day: day, profiles: [key: .init(planned: planned, left: left, lastFinished: at(6))],
            failed: failed)
        return state
    }

    func testARowCountsWhatLandedToday() {
        let rows = SplitCollectRow.rows(
            state: state("lbl.fresh", key: "", planned: ["a", "b", "c"], left: ["c"]),
            schedules: [schedule("fresh")], workspace: "alpha", now: at(7))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].done, 2)
        XCTAssertEqual(rows[0].of, 3)
        XCTAssertEqual(rows[0].progressText, "2 of 3 sources collected today")
        XCTAssertFalse(rows[0].retrying)
    }

    func testCountsThatNoLongerLineUpSayWhatIsLeft() {
        let rows = SplitCollectRow.rows(
            state: state("lbl.fresh", key: "", planned: ["a"], left: ["a", "b"]),
            schedules: [schedule("fresh")], workspace: "alpha", now: at(19))
        XCTAssertNil(rows[0].done)
        XCTAssertEqual(rows[0].progressText, "2 sources left today")
    }

    func testAMultiScheduleShowsOnlyTheActiveWorkspace() {
        let st = state("lbl.fleet", key: "beta", planned: ["a"], left: ["a"])
        XCTAssertTrue(SplitCollectRow.rows(
            state: st, schedules: [schedule("fleet", multi: true)], workspace: "alpha",
            now: at(7)).isEmpty)
        XCTAssertEqual(SplitCollectRow.rows(
            state: st, schedules: [schedule("fleet", multi: true)], workspace: "beta",
            now: at(7)).count, 1)
    }

    func testAFailureSaysTheRetryGoesFirstAndYesterdayShowsNothing() {
        let st = state("lbl.fresh", key: "", planned: ["a"], left: ["a"], failed: true)
        let rows = SplitCollectRow.rows(
            state: st, schedules: [schedule("fresh")], workspace: "alpha", now: at(7))
        XCTAssertTrue(rows[0].retrying)
        XCTAssertTrue(SplitCollectRow.rows(
            state: st, schedules: [schedule("fresh")], workspace: "alpha", now: at(30)).isEmpty)
    }
}
