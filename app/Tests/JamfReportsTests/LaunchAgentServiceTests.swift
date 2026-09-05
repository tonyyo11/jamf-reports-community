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

    // MARK: - PR-23 T-19: --tiers parsing

    func testParseNativePlistReadsTiersFlag() throws {
        let label = "\(prefix).dummy.tiered-collect"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", "dummy",
                "--mode", "jamf-cli-full",
                "--tiers", "refresh,scan",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertEqual(parsed.tiers, [.refresh, .scan])
    }

    func testParseNativePlistWithoutTiersFlagYieldsNil() throws {
        // Pre-PR-23 plists omit --tiers; parse must yield nil so main.swift
        // applies the all-tiers default.
        let label = "\(prefix).dummy.legacy-collect"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", "dummy",
                "--mode", "jamf-cli-full",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertNil(parsed.tiers, "Absent --tiers must parse to nil, not an empty set")
    }

    func testParseTiersDropsUnknownTokensKeepsValid() throws {
        let label = "\(prefix).dummy.mixed-tiers"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", "dummy",
                "--mode", "jamf-cli-full",
                "--tiers", "refresh,bogus,inventory",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertEqual(parsed.tiers, [.refresh, .inventory],
                       "Unknown 'bogus' token dropped; valid tiers kept")
    }

    func testParseTiersAllUnknownFallsBackToNil() throws {
        // If every token is unrecognizable (corruption / cross-version
        // rename), treat the flag as absent rather than yielding an empty
        // set — an empty set would silently collect nothing.
        let label = "\(prefix).dummy.garbage-tiers"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", "dummy",
                "--mode", "jamf-cli-full",
                "--tiers", "xxx,yyy",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertNil(parsed.tiers)
    }

    // MARK: - --exclude-profiles round trip (was write-only; parse dropped it)

    func testParseReadsExcludeProfilesFromMultiPlist() throws {
        let label = "\(prefix).multi.exclude-round-trip"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", "alpha",
                "--mode", "jamf-cli-full",
                "--all-profiles",
                "--exclude-profiles", "dummy,sandbox",
            ],
            "StartCalendarInterval": ["Hour": 7, "Minute": 0],
            "Disabled": false,
        ])

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertEqual(parsed.excludedProfiles, ["dummy", "sandbox"],
                       "parse must read --exclude-profiles back from a multi plist")
    }

    func testExcludeProfilesAbsentFlagYieldsNil() throws {
        let label = "\(prefix).multi.no-exclusions"
        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", "alpha",
                "--mode", "jamf-cli-full",
                "--all-profiles",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plistURL))
        XCTAssertNil(parsed.excludedProfiles, "Absent --exclude-profiles must parse to nil, not an empty array")
    }

    func testScheduleFormKeepsBaseProfileForMultiTarget() {
        // The form's profile-target picker collapsed to single/all in 2.8.0
        // (ScheduleRecord.allProfiles is a Bool — the native runner never
        // honoured a filter or explicit list); this pins the surviving path.
        var form = ScheduleFormState(defaultProfile: "alpha")
        form.name = "Weekly Multi"
        form.profileMode = .all
        form.mode = .jamfCLIFull

        let schedule = form.toSchedule()

        XCTAssertTrue(schedule.isMulti)
        XCTAssertEqual(schedule.profile, "alpha")
        XCTAssertEqual(schedule.mode, .jamfCLIFull)
        XCTAssertEqual(schedule.multiTarget, MultiTarget(scope: .all))
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

    // MARK: - sheet_failures → .partial (the `.partial` branch used to be dead
    // code because `runStatus?.success` short-circuited before it could run)

    func testLastStatusIsPartialWhenSuccessTrueWithSheetFailures() throws {
        let scaffold = try writeSheetFailuresStatusScaffold(success: true, sheetFailures: 2)
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        XCTAssertEqual(schedule.lastStatus, .partial)
    }

    func testLastStatusIsOkWhenSuccessTrueWithZeroSheetFailures() throws {
        let scaffold = try writeSheetFailuresStatusScaffold(success: true, sheetFailures: 0)
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        XCTAssertEqual(schedule.lastStatus, .ok)
    }

    func testLastStatusIsFailWhenSuccessFalseRegardlessOfSheetFailures() throws {
        let scaffold = try writeSheetFailuresStatusScaffold(success: false, sheetFailures: 3)
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        XCTAssertEqual(schedule.lastStatus, .fail)
    }

    func testLastStatusIsOkWhenSheetFailuresKeyAbsent() throws {
        // Status files written before `sheet_failures` existed — back-compat.
        let scaffold = try writeSheetFailuresStatusScaffold(success: true, sheetFailures: nil)
        defer { scaffold.cleanup() }

        let schedule = try XCTUnwrap(LaunchAgentService.parse(scaffold.plistURL))
        XCTAssertEqual(schedule.lastStatus, .ok)
    }

    private struct SheetFailuresScaffold {
        let plistURL: URL
        let cleanup: () -> Void
    }

    /// Writes a single-profile `status.json` at the DEFAULT
    /// `<workspace>/automation/<label>_status.json` path (no `--status-file`
    /// override), so `lastStatus` is exercised through the real production
    /// path rather than the private function directly.
    private func writeSheetFailuresStatusScaffold(
        success: Bool,
        sheetFailures: Int?
    ) throws -> SheetFailuresScaffold {
        let profile = "dummy"
        let workspacesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SheetFailures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)

        let automation = workspacesRoot
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: automation, withIntermediateDirectories: true)

        let label = "\(prefix).\(profile).sheet-failures-\(UUID().uuidString.lowercased())"
        var status: [String: Any] = ["success": success, "finished_at": "2026-07-27T12:00:00Z"]
        if let sheetFailures { status["sheet_failures"] = sheetFailures }
        let statusData = try JSONSerialization.data(withJSONObject: status)
        try statusData.write(to: automation.appendingPathComponent("\(label)_status.json"))

        let plistURL = try writePlist([
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run",
                "--profile", profile,
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        return SheetFailuresScaffold(plistURL: plistURL) {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: workspacesRoot)
        }
    }

    // MARK: - Archive redaction (scrub secret args before archiving a plist)

    func testRedactedPlistDataScrubsNotifyWebhook() throws {
        let url = try writePlist([
            "Label": "\(prefix).dummy.notify-sched",
            "ProgramArguments": [
                "/usr/local/bin/jamf-cli-reports", "launchagent-run",
                "--mode", "snapshot-only",
                "--notify", "https://example.webhook.office.com/secret-token-xyz",
            ],
        ])
        let data = try XCTUnwrap(
            LaunchAgentService.redactedPlistData(at: url),
            "a plist carrying --notify must be redacted, not copied verbatim")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any])
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertFalse(args.contains { $0.contains("secret-token") },
                       "the webhook URL must not survive into the archive copy")
        let notifyIdx = try XCTUnwrap(args.firstIndex(of: "--notify"))
        XCTAssertEqual(args[notifyIdx + 1], "<redacted-on-archive>")
        XCTAssertTrue(args.contains("snapshot-only"), "non-secret args are preserved")
    }

    func testRedactedPlistDataReturnsNilWhenNoSecret() throws {
        let url = try writePlist([
            "Label": "\(prefix).dummy.plain-sched",
            "ProgramArguments": [
                "/usr/local/bin/jamf-cli-reports", "launchagent-run",
                "--mode", "snapshot-only",
            ],
        ])
        XCTAssertNil(LaunchAgentService.redactedPlistData(at: url),
                     "a plist with no secret args is copied verbatim (nil = no redaction)")
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
