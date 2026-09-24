import Foundation
import XCTest
@testable import JamfReports

/// The demo's Run History, Data Sources and Settings read `DemoData+Admin`,
/// which has to agree with the rest of `DemoData`: each schedule's newest run
/// is the Last Run the Automation screen shows, every log parses the way Run
/// History parses a real one, and nothing is dated after the demo's "now".
final class DemoDataAdminTests: XCTestCase {

    /// The format `DemoData.scheduledRuns` writes its Last Run in.
    private let lastRunFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private var allRuns: [DemoData.RunLog] {
        DemoData.cliProfiles.flatMap { DemoData.runHistory(for: $0.name) }
    }

    // MARK: - Run History

    func testEachScheduleNewestRunIsItsLastRun() {
        for schedule in DemoData.scheduledRuns {
            let newest = DemoData.runHistory(for: schedule.profile)
                .map(\.summary)
                .first { $0.name == schedule.name }
            guard let newest else {
                XCTFail("\(schedule.name) has no demo run history")
                continue
            }
            XCTAssertEqual(newest.status, schedule.lastStatus, schedule.name)
            XCTAssertEqual(lastRunFormat.string(from: newest.date), schedule.last, schedule.name)
        }
    }

    func testOnlyTheApr24IPadRunIsWarn() {
        let warn = allRuns.filter { $0.summary.status == .warn }.map(\.summary)
        XCTAssertEqual(warn.map(\.name), ["Mobile Inventory (iPad)"])
        XCTAssertEqual(warn.map { lastRunFormat.string(from: $0.date) }, ["Apr 24, 07:33"])
        XCTAssertNil(warn.first?.exitCode)
    }

    /// A demo log written to disk must read back as the row it is listed
    /// with — the WARN run as a run with no exit line — so the demo shows
    /// what the live parser would.
    func testDemoLogsParseToTheRowsTheyAreListedWith() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoRuns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for run in allRuns {
            let file = dir.appendingPathComponent(run.summary.id)
            try run.lines.map(\.text).joined(separator: "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            let (exitCode, duration, _) = RunHistoryService.parseLogTail(from: file)
            XCTAssertEqual(exitCode, run.summary.exitCode, run.summary.id)
            XCTAssertEqual(duration, run.summary.duration, run.summary.id)
        }
    }

    func testHistoryIsNewestFirstAndNeverAfterTheReferenceDate() {
        for profile in DemoData.cliProfiles {
            let dates = DemoData.runHistory(for: profile.name).map(\.summary.date)
            XCTAssertEqual(dates, dates.sorted(by: >), profile.name)
            XCTAssertTrue(dates.allSatisfy { $0 <= DemoData.referenceDate }, profile.name)
        }
    }

    func testRunLogsAreNamedLikeTheRecorderInTheDemoWorkspace() {
        for run in DemoData.runHistory(for: DemoData.org.profile) {
            XCTAssertTrue(run.summary.id.hasPrefix(run.summary.label + "."), run.summary.id)
            XCTAssertTrue(
                run.summary.logURL.path.hasSuffix(
                    "Jamf-Reports/meridian-prod/automation/logs/\(run.summary.id)"),
                run.summary.logURL.path)
        }
    }

    func testProfileWithoutSchedulesHasNoRunHistory() {
        XCTAssertTrue(DemoData.runHistory(for: "meridian-msp").isEmpty)
    }

    // MARK: - Workspace paths

    func testWorkspaceDisplayPathMatchesTheLiveShape() {
        XCTAssertEqual(
            DemoData.workspaceDisplayPath(profile: "meridian-prod", subpath: "config.yaml"),
            "~/Jamf-Reports/meridian-prod/config.yaml")
        XCTAssertEqual(
            DemoData.workspaceDisplayPath(profile: "meridian-prod"), "~/Jamf-Reports/meridian-prod")
    }

    // MARK: - Data Sources

    func testProfileWithoutSchedulesHasNoCachesInboxOrFamilies() {
        XCTAssertNil(DemoData.cacheDate(for: ["overview"], profile: "meridian-msp"))
        XCTAssertTrue(DemoData.inboxFiles(for: "meridian-msp").isEmpty)
        XCTAssertTrue(DemoData.snapshotFamilies(for: "meridian-msp").isEmpty)
    }

    /// The refresh tier comes from the Apr 25 daily snapshot, the inventory
    /// tier from Monday's executive report: the runs whose logs collect them.
    func testCacheDatesComeFromTheRunsThatCollectedThem() {
        let profile = DemoData.org.profile
        let overview = DemoData.cacheDate(for: ["overview"], profile: profile)
        let computers = DemoData.cacheDate(
            for: ["computers-list", "computers_list"], profile: profile)
        XCTAssertEqual(overview.map { lastRunFormat.string(from: $0) }, "Apr 25, 06:00")
        XCTAssertEqual(computers.map { lastRunFormat.string(from: $0) }, "Apr 20, 07:00")
        let names = [["overview"], ["ea-results"], ["update-status"], ["protect-overview"]]
        for demoProfile in DemoData.cliProfiles {
            for cacheNames in names {
                guard let date = DemoData.cacheDate(for: cacheNames, profile: demoProfile.name)
                else { continue }
                XCTAssertLessThanOrEqual(date, DemoData.referenceDate)
            }
        }
    }

    /// Only the Daily Snapshot's log collects Jamf Protect.
    func testProtectCacheOnlyWhereTheDailySnapshotRuns() {
        XCTAssertNotNil(DemoData.cacheDate(for: ["protect-overview"], profile: "meridian-prod"))
        XCTAssertNil(DemoData.cacheDate(for: ["protect-overview"], profile: "meridianedu"))
    }

    func testOnlyTheCSVAssistedProfileHasAnInboxCSV() {
        let inbox = DemoData.inboxFiles(for: DemoData.org.profile)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertTrue(inbox.allSatisfy { $0.mtime <= DemoData.referenceDate })
        XCTAssertTrue(DemoData.inboxFiles(for: "meridianedu").isEmpty)
    }

    func testSummariesFamilyMatchesTheTrendHistory() {
        let families = DemoData.snapshotFamilies(for: DemoData.org.profile)
        XCTAssertEqual(families.map(\.name), ["summaries"])
        XCTAssertEqual(families.first?.snapshotCount, DemoData.trendDates.count)
        XCTAssertEqual(
            families.first?.latestDate.map { lastRunFormat.string(from: $0) }, "Apr 25, 06:01")
    }

    func testCommandMatrixListsEveryTrackedCommandWithoutAVersion() {
        let snapshot = DemoData.jamfCLICapabilities
        XCTAssertNil(snapshot.version)
        XCTAssertEqual(Set(snapshot.availability.keys), Set(CapabilityService.trackedCommands))
        XCTAssertTrue(snapshot.availability.values.allSatisfy { $0 == .available })
    }

    // MARK: - Settings

    func testTokenStatusesAreValidAtTheReferenceDate() {
        let statuses = DemoData.tokenStatuses(for: DemoData.cliProfiles)
        XCTAssertEqual(Set(statuses.keys), Set(DemoData.cliProfiles.map(\.name)))
        for status in statuses.values {
            XCTAssertTrue(status.isValid, status.profile)
            guard let expiry = status.expiresAt else {
                XCTFail("\(status.profile) has no expiry")
                continue
            }
            XCTAssertGreaterThan(expiry, DemoData.referenceDate)
        }
    }
}
