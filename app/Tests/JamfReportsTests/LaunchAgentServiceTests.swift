import Foundation
import XCTest
@testable import JamfReports

final class LaunchAgentServiceTests: XCTestCase {
    private let prefix = LaunchAgentWriter.labelPrefix

    func testParseMultiLaunchAgentPreservesMultiTarget() throws {
        let label = "\(prefix).multi.weekday-collect"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/usr/local/bin/jamf-cli",
                "multi",
                "--profiles",
                "alpha,beta",
                "--sequential",
                "--",
                "pro",
                "collect",
            ],
            "StartCalendarInterval": ["Weekday": 1, "Hour": 8, "Minute": 30],
            "Disabled": false,
        ])

        let schedule = LaunchAgentService.parse(plistURL)

        let parsed = try XCTUnwrap(schedule)
        XCTAssertEqual(parsed.launchAgentLabel, label)
        XCTAssertEqual(parsed.profile, "")
        XCTAssertTrue(parsed.isMulti)
        XCTAssertEqual(parsed.multiTarget, MultiTarget(scope: .list(["alpha", "beta"]), sequential: true))
        XCTAssertEqual(parsed.schedule, "Mon 08:30")
        XCTAssertEqual(LaunchAgentWriter.label(for: parsed), label)
    }

    func testParseMultiLaunchAgentDefaultsToAllProfiles() throws {
        let label = "\(prefix).multi.daily-collect"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/usr/local/bin/jamf-cli",
                "multi",
                "--",
                "pro",
                "collect",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": true,
        ])

        let schedule = LaunchAgentService.parse(plistURL)

        XCTAssertEqual(schedule?.profile, "")
        XCTAssertEqual(schedule?.multiTarget, MultiTarget(scope: .all))
        XCTAssertEqual(schedule?.enabled, false)
        XCTAssertEqual(schedule?.next, "—")
    }

    func testParseJRCMultiLaunchAgentPreservesModeAndTarget() throws {
        let label = "\(prefix).multi.full-automation"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/python3",
                "/Applications/JamfReports.app/Contents/Resources/jamf-reports-community.py",
                "multi-launchagent-run",
                "--mode",
                "jamf-cli-full",
                "--workspace-root",
                "/Users/example/Jamf-Reports",
                "--multi-profiles",
                "alpha,beta",
                "--multi-sequential",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let schedule = try XCTUnwrap(LaunchAgentService.parse(plistURL))

        XCTAssertEqual(schedule.launchAgentLabel, label)
        XCTAssertEqual(schedule.profile, "")
        XCTAssertEqual(schedule.mode, .jamfCLIFull)
        XCTAssertEqual(schedule.multiTarget, MultiTarget(scope: .list(["alpha", "beta"]), sequential: true))
        XCTAssertEqual(schedule.profileDisplayLabel, "2 profiles")
    }

    func testScheduleFormKeepsBaseProfileForMultiTarget() {
        var form = ScheduleFormState(defaultProfile: "alpha")
        form.name = "Weekly Multi"
        form.profileMode = .list
        form.multiList = "alpha,beta"
        form.mode = .jamfCLIFull

        let schedule = form.toSchedule()

        XCTAssertTrue(schedule.isMulti)
        XCTAssertEqual(schedule.profile, "alpha")
        XCTAssertEqual(schedule.mode, .jamfCLIFull)
        XCTAssertEqual(schedule.multiTarget, MultiTarget(scope: .list(["alpha", "beta"])))
        XCTAssertEqual(LaunchAgentWriter.label(for: schedule), "\(prefix).multi.weekly-multi")
    }

    func testLaunchAgentLogTailParsesAnyExitCode() throws {
        let logURL = try writeLog("[info] started\n[info] exit 127 after 4s\n")

        let tail = LaunchAgentService.parseLogTail(from: logURL)

        XCTAssertEqual(tail.exitCode, 127)
        XCTAssertFalse(tail.hasFailureMarker)
        XCTAssertEqual(LaunchAgentService.exitCode(from: "[info] exit -1 after 0s"), -1)
        XCTAssertEqual(LaunchAgentService.exitCode(from: "[info] exit 2 after 0s"), 2)
    }

    func testLaunchAgentLogTailDetectsMultiFailureMarkers() throws {
        let logURL = try writeLog("[fail] beta\nError: multi-profile run failed for: beta\n")

        let tail = LaunchAgentService.parseLogTail(from: logURL)

        XCTAssertTrue(tail.hasFailureMarker)
    }

    func testParseMultiLaunchAgentReadsAggregateStatusFailure() throws {
        let label = "\(prefix).multi.failed-\(UUID().uuidString.lowercased())"
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: logDir) }

        let statusURL = logDir.appendingPathComponent("status.json")
        let status: [String: Any] = [
            "command": "multi-launchagent-run",
            "success": false,
            "finished_at": "2026-05-02T12:00:00Z",
            "results": [
                ["profile": "alpha", "success": true],
                ["profile": "beta", "success": false, "error": "failed"],
            ],
        ]
        let statusData = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        try statusData.write(to: statusURL)

        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/python3",
                "/Applications/JamfReports.app/Contents/Resources/jamf-reports-community.py",
                "multi-launchagent-run",
                "--mode",
                "jamf-cli-full",
                "--workspace-root",
                "/Users/example/Jamf-Reports",
                "--status-file",
                statusURL.path,
            ],
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let schedule = try XCTUnwrap(LaunchAgentService.parse(plistURL))

        XCTAssertEqual(schedule.lastStatus, .fail)
        XCTAssertEqual(schedule.profile, "")
    }

    // MARK: - Partial-status detection (PR-8 follow-up)
    //
    // `LaunchAgentService.checkSummaryFileForPartialStatus` is `private` and
    // not directly callable. The tests below exercise it indirectly through
    // `LaunchAgentService.parse(plistURL)` → `readLogSummary` →
    // `checkSummaryFileForPartialStatus`, which is the production path that
    // populates `Schedule.lastStatus`.
    //
    // Workspace scaffolding uses the `JRC_TEST_WORKSPACES_ROOT` env override
    // (DEBUG-gated in `ProfileService.workspacesRoot()`) to redirect the
    // workspace lookup to a tmp dir — without it, the test would write into
    // the user's real `~/Jamf-Reports/` and pollute live data.

    func testCheckSummaryFileReturnsPartialWhenStatusIsPartial() throws {
        let scaffold = try makePartialStatusScaffold(
            profile: "dummy",
            timestamp: "20260516-143000",
            summaryStatus: "partial"
        )
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        XCTAssertEqual(schedule.lastStatus, .partial,
                       "summary_<logFilename>.json status=partial must surface as Schedule.LastStatus.partial")
    }

    func testCheckSummaryFileReturnsFalseWhenStatusIsOK() throws {
        let scaffold = try makePartialStatusScaffold(
            profile: "dummy",
            timestamp: "20260516-144500",
            summaryStatus: "ok"
        )
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        // exit 0 + no partial marker + summary status=ok → ok.
        XCTAssertEqual(schedule.lastStatus, .ok,
                       "summary status=ok must keep lastStatus at .ok, not .partial")
    }

    func testCheckSummaryFileReturnsFalseForMultiLogs() throws {
        // Multi-profile logs live under ~/Library/Logs/JamfReports/<label>/,
        // not in a per-profile workspace. The check must short-circuit on
        // isMulti=true regardless of any summary file at the workspace path.
        let label = "\(prefix).multi.partial-mp-\(UUID().uuidString.lowercased())"
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: logDir) }

        let stdoutURL = logDir.appendingPathComponent("stdout.log")
        try "[info] exit 0 after 1s\n".write(to: stdoutURL, atomically: true, encoding: .utf8)

        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/usr/local/bin/jamf-cli",
                "multi",
                "--",
                "pro",
                "collect",
            ],
            "StandardOutPath": stdoutURL.path,
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let schedule = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertFalse(schedule.lastStatus == .partial,
                       "Multi-profile logs must never report .partial via summary-file lookup")
    }

    func testCheckSummaryFileReturnsFalseWhenSummaryAbsent() throws {
        // No summary file is written. The log has exit 0 and no [partial]
        // marker — fallback chain must report .ok, not .partial.
        let scaffold = try makePartialStatusScaffold(
            profile: "dummy",
            timestamp: "20260516-150000",
            summaryStatus: nil  // explicitly skip writing summary.json
        )
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        XCTAssertEqual(schedule.lastStatus, .ok,
                       "Absent summary.json must not synthesize a .partial status")
    }

    /// Test scaffold for `checkSummaryFileForPartialStatus` indirect tests.
    /// Creates a temp `JRC_TEST_WORKSPACES_ROOT`, a `<root>/<profile>/`
    /// workspace, the `automation/logs/<ts>.log` log file, optionally the
    /// `snapshots/computers/summaries/summary_<ts>.json` sibling, and the
    /// LaunchAgent plist that points `StandardOutPath` at the log.
    private struct PartialStatusScaffold {
        let plistURL: URL
        let cleanup: () -> Void
    }

    private func makePartialStatusScaffold(
        profile: String,
        timestamp: String,
        summaryStatus: String?
    ) throws -> PartialStatusScaffold {
        let workspacesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)

        let workspace = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
        let logsDir = workspace
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let summariesDir = workspace
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("computers", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let logURL = logsDir.appendingPathComponent("\(timestamp).log")
        try "[info] exit 0 after 5s\n".write(to: logURL, atomically: true, encoding: .utf8)

        if let summaryStatus {
            let summaryURL = summariesDir.appendingPathComponent("summary_\(timestamp).json")
            let json = try JSONSerialization.data(withJSONObject: ["status": summaryStatus])
            try json.write(to: summaryURL)
        }

        let label = "\(prefix).\(profile).partial-\(UUID().uuidString.lowercased())"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/python3",
                "/Applications/JamfReports.app/Contents/Resources/jamf-reports-community.py",
                "launchagent-run",
            ],
            "StandardOutPath": logURL.path,
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        return PartialStatusScaffold(plistURL: plistURL) {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: workspacesRoot)
        }
    }

    private func writePlist(_ plist: [String: Any]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("agent.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return url
    }

    private func writeLog(_ text: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("stdout.log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return url
    }
}
