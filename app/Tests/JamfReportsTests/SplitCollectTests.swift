import Foundation
import Synchronization
import XCTest
@testable import JamfReports

/// Phase 2 of the split collect: a run records why it stopped and what it left, so the tick can
/// continue a budget stop instead of retrying it as a failure.
final class SplitCollectTests: XCTestCase {
    func testOnlyABudgetStopOrAnotherRefreshIsContinued() {
        let budget = ReportEngine.RunStop.budgetUsed(minutes: 45)
        XCTAssertEqual(SplitCollect.continuableStop(
            budget, mode: .snapshotOnly, protectOnly: false), .budget)
        XCTAssertEqual(SplitCollect.continuableStop(
            .manualRefresh(sameWorkspaceFull: false), mode: .jamfCLIFull, protectOnly: false),
            .otherRefresh)
        XCTAssertNil(SplitCollect.continuableStop(
            .manualRefresh(sameWorkspaceFull: true), mode: .snapshotOnly, protectOnly: false))
        XCTAssertNil(SplitCollect.continuableStop(budget, mode: .snapshotOnly, protectOnly: true))
        XCTAssertNil(SplitCollect.continuableStop(budget, mode: .jamfCLIOnly, protectOnly: false))
        XCTAssertNil(SplitCollect.continuableStop(nil, mode: .snapshotOnly, protectOnly: false))
    }

    func testTheRunRecordsWhatItPlannedAndLeft() async {
        let progress = ReportEngine.RunProgress()
        let lines = await ReportEngine.$runProgress.withValue(progress) { () -> [String] in
            _ = ReportEngine.collectPlanLines(profile: "p", running: ["overview", "computers"])
            _ = ReportEngine.collectPlanLines(profile: "p", running: ["protect-alerts"])
            let collected = Lines()
            await ReportEngine.$runStop.withValue({ .budgetUsed(minutes: 45) }) {
                _ = ReportEngine.stopsRun(
                    left: ["computers", "device scan"], onLine: { collected.add($0.text) })
            }
            return collected.all
        }
        XCTAssertEqual(progress.planned,
                       ["overview", "computers", "protect-alerts", "device scan"])
        XCTAssertEqual(progress.left, ["computers", "device scan"])
        XCTAssertEqual(progress.stop, .budgetUsed(minutes: 45))
        XCTAssertTrue(lines.first?.hasPrefix(ReportEngine.stoppedEarlyMarker) == true)
    }

    func testEveryPhaseOfOneRunKeepsItsLeftovers() async {
        let progress = ReportEngine.RunProgress()
        await ReportEngine.$runProgress.withValue(progress) {
            await ReportEngine.$runStop.withValue({ .budgetUsed(minutes: 45) }) {
                _ = ReportEngine.stopsRun(left: ["computers", "ea-results"], onLine: { _ in })
                _ = ReportEngine.stopsRun(left: ["protect-alerts"], onLine: { _ in })
                _ = ReportEngine.stopsRun(left: ["device scan"], onLine: { _ in })
            }
        }
        XCTAssertEqual(progress.left, ["computers", "ea-results", "protect-alerts", "device scan"])
        XCTAssertEqual(progress.stop, .budgetUsed(minutes: 45))
    }

    func testADueSchoolScanGetsItsDevicesOnAnUnforcedRun() {
        let now = Date()
        let plan = ReportEngine.planSchoolCollect(
            profile: "school", tiers: Set(CollectionTier.allCases), force: false, now: now,
            scanDue: true, lastRun: { _ in now.addingTimeInterval(-600) })
        let devices = plan.first { $0.kind == SchoolFleetService.devicesKind }
        XCTAssertNotNil(devices)
        XCTAssertNil(devices?.skip, "the scan's input is collected although it landed today")
        XCTAssertNotNil(plan.first { $0.kind != SchoolFleetService.devicesKind }?.skip)
    }

    func testAPlanOutsideAScheduledRunRecordsNothing() {
        XCTAssertNil(ReportEngine.runProgress)
        _ = ReportEngine.collectPlanLines(profile: "p", running: ["overview"])
    }

    func testAStopAloneIsNotAFailureForTheTick() {
        let honesty = CollectHonestyWatcher()
        honesty.observe(ReportEngine.stoppedEarlyMarker
            + "run budget used (45 minutes); 1 source left for the next run: computers")
        let profile = "split-\(UUID().uuidString.prefix(8))"
        XCTAssertTrue(honesty.retryCouldHelp(profile: profile))
        XCTAssertFalse(honesty.retryCouldHelp(profile: profile, countingStop: false))
    }

    func testAnOlderOutcomeDecodesWithNoStop() throws {
        let json = """
        {"profile":"a","exit":0,"incomplete":false,"retry_could_help":true,
         "started":"2026-11-25T06:00:00Z","finished":"2026-11-25T06:45:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outcome = try decoder.decode(ProfileOutcome.self, from: Data(json.utf8))
        XCTAssertNil(outcome.stop)
        XCTAssertTrue(outcome.failureRetryCouldHelp)
        XCTAssertEqual(outcome.planned, [])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stopped = ProfileOutcome(
            profile: "a", exitCode: 0, incomplete: false, retryCouldHelp: true,
            started: outcome.started, finished: outcome.finished, stop: .budget,
            failureRetryCouldHelp: false, planned: ["x", "y"], left: ["y"])
        XCTAssertEqual(
            try decoder.decode(ProfileOutcome.self, from: encoder.encode(stopped)), stopped)
    }
}

private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}
