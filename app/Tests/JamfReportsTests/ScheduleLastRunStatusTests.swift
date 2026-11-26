import Foundation
import XCTest
@testable import JamfReports

/// The schedule list's status pill reads each schedule's newest finished run from Run History
/// instead of the `.ok` placeholder every builder sets.
final class ScheduleLastRunStatusTests: XCTestCase {
    private let profile = "pill-status"
    private var root: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-Pill-\(UUID().uuidString)", isDirectory: true)
        logs = root.appendingPathComponent(profile).appendingPathComponent("automation/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func log(_ label: String, _ stamp: String, _ body: String) throws {
        try body.write(to: logs.appendingPathComponent("\(label).\(stamp).log"),
                       atomically: true, encoding: .utf8)
    }

    func testNewestFinishedRunPerLabelWins() throws {
        let label = "\(LaunchAgentWriter.labelPrefix).multi.managed-freshness"
        try log(label, "20261124-060000", "[info] exit 0 after 5s\n")
        try log(label, "20261125-060000", "[error] boom\n[info] exit 1 after 9s\n")
        let other = "\(LaunchAgentWriter.labelPrefix).multi.managed-backup"
        try log(other, "20261125-063000", "[partial] x\n[info] exit 0 after 2s\n")

        let runs = RunHistoryService.newestFinishedRuns(profile: profile)

        XCTAssertEqual(runs[label]?.status, .fail)
        XCTAssertEqual(runs[other]?.status, .partial)
        XCTAssertNil(runs["\(LaunchAgentWriter.labelPrefix).multi.managed-scan"])
    }

    func testSchedulesTakeTheirRunsStatusAndKeepThePlaceholderWithout() throws {
        let label = "\(LaunchAgentWriter.labelPrefix).multi.managed-freshness"
        try log(label, "20261125-060000", "[info] exit 1 after 9s\n")
        let freshness = Schedule(
            name: "f", profile: profile, schedule: "Daily 06:00", cadence: "daily",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label)
        var scan = freshness
        scan.launchAgentLabel = "\(LaunchAgentWriter.labelPrefix).multi.managed-scan"

        let updated = WorkspaceStore.withLastRuns(
            [freshness, scan], RunHistoryService.newestFinishedRuns(profile: profile))

        XCTAssertEqual(updated[0].lastStatus, .fail)
        XCTAssertNotEqual(updated[0].last, "—")
        XCTAssertEqual(updated[1].lastStatus, .ok)
        XCTAssertEqual(updated[1].last, "—")
    }

    func testSchedulesListPrintsTheStatusInEnglish() throws {
        let record = try XCTUnwrap(ScheduleRecord(schedule: Schedule(
            name: "nightly", profile: "ws", schedule: "Daily 06:00", cadence: "daily",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true)))

        XCTAssertTrue(Schedules.List.line(for: record, status: .fail).contains("\tFAIL"))
        XCTAssertTrue(Schedules.List.line(for: record, status: nil).hasSuffix("\t-"))
    }
}
