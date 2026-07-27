import Darwin
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

    func testTiersRoundTripThroughWriteAndParse() throws {
        var sched = Schedule(
            name: "Tier Round Trip",
            profile: "dummy",
            schedule: "Daily 07:00",
            cadence: "daily",
            mode: .jamfCLIFull,
            next: "-", last: "-", lastStatus: .ok,
            artifacts: [], enabled: true
        )
        sched.tiers = [.refresh, .inventory]
        let agentLabel = try XCTUnwrap(LaunchAgentWriter.label(for: sched))
        let plan = try LaunchAgentWriter.nativeSingleWrite(for: sched, load: false)
        defer {
            try? FileManager.default.removeItem(at: plan.plistURL)
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
            try? FileManager.default.removeItem(at: logDir)
        }

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plan.plistURL))
        XCTAssertEqual(parsed.tiers, [.refresh, .inventory],
                       "Tier set must survive the write → parse round trip")
    }

    // MARK: - --exclude-profiles round trip (was write-only; parse dropped it)

    func testExcludeProfilesRoundTripThroughWriteAndParse() throws {
        var sched = Schedule(
            name: "Exclude Round Trip",
            profile: "alpha",
            schedule: "Daily 07:00",
            cadence: "daily",
            mode: .jamfCLIFull,
            next: "-", last: "-", lastStatus: .ok,
            artifacts: [], enabled: true,
            multiTarget: MultiTarget(scope: .all)
        )
        sched.excludedProfiles = ["dummy", "sandbox"]
        let agentLabel = try XCTUnwrap(LaunchAgentWriter.label(for: sched))

        let tempExec = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-jamf-reports-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempExec.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: tempExec.path
        )
        defer { try? FileManager.default.removeItem(at: tempExec) }

        let plan = try LaunchAgentWriter.nativeMultiWrite(for: sched, executableURL: tempExec, load: false)
        defer {
            try? FileManager.default.removeItem(at: plan.plistURL)
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
            try? FileManager.default.removeItem(at: logDir)
        }

        let parsed = try XCTUnwrap(LaunchAgentService.parse(plan.plistURL))
        XCTAssertEqual(parsed.excludedProfiles, ["dummy", "sandbox"],
                       "--exclude-profiles must survive the write → parse round trip")
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

    // MARK: - staleExecutableLabels (PR-15)

    func testStaleExecutableLabelsReturnsEmptyForFreshPlists() throws {
        let dir = try makeAgentsDir()
        let realExec = FileManager.default.homeDirectoryForCurrentUser
        try writeLabeledPlist(
            in: dir,
            label: "\(prefix).demo.daily-fresh",
            executable: realExec.path
        )

        XCTAssertEqual(LaunchAgentService.staleExecutableLabels(in: dir), [])
    }

    func testStaleExecutableLabelsFlagsMissingExecutable() throws {
        let dir = try makeAgentsDir()
        try writeLabeledPlist(
            in: dir,
            label: "\(prefix).demo.daily-stale",
            executable: "/Users/nobody/JamfReports.app/Contents/MacOS/JamfReports"
        )

        XCTAssertEqual(
            LaunchAgentService.staleExecutableLabels(in: dir),
            ["\(prefix).demo.daily-stale"]
        )
    }

    func testStaleExecutableLabelsSortsMultipleStaleEntriesAlphabetically() throws {
        let dir = try makeAgentsDir()
        let missing = "/tmp/nonexistent-binary-\(UUID().uuidString.prefix(8))"
        try writeLabeledPlist(in: dir, label: "\(prefix).beta.weekly-z", executable: missing)
        try writeLabeledPlist(in: dir, label: "\(prefix).alpha.daily-a", executable: missing)
        // Add a fresh one to confirm it's filtered out
        try writeLabeledPlist(
            in: dir,
            label: "\(prefix).gamma.hourly-fresh",
            executable: FileManager.default.homeDirectoryForCurrentUser.path
        )

        XCTAssertEqual(
            LaunchAgentService.staleExecutableLabels(in: dir),
            ["\(prefix).alpha.daily-a", "\(prefix).beta.weekly-z"]
        )
    }

    func testStaleExecutableLabelsIgnoresNonJRCPlists() throws {
        let dir = try makeAgentsDir()
        let missing = "/tmp/nope-\(UUID().uuidString.prefix(8))"
        // A plist with our prefix but missing binary → flagged
        try writeLabeledPlist(in: dir, label: "\(prefix).demo.daily", executable: missing)
        // A plist with a different prefix → ignored even though executable missing
        try writeLabeledPlist(in: dir, label: "com.apple.someone.else.daily", executable: missing)

        XCTAssertEqual(
            LaunchAgentService.staleExecutableLabels(in: dir),
            ["\(prefix).demo.daily"]
        )
    }

    // MARK: - Managed multi health-input fallback (2.6 dead-man switch FIX 1)
    //
    // Managed all-profiles agents (`<prefix>.multi.managed-*`) carry no
    // `--status-file`; their run status lives per profile at
    // `<workspace>/automation/<label>_status.json`. `healthInput` must fall
    // back to that, else every managed agent reads as perpetually overdue.

    func testMultiHealthInputFallsBackToPerProfileStatusFile() throws {
        let root = try makeHealthWorkspacesRoot()
        let label = "\(prefix).multi.managed-freshness"
        let finished = try writeProfileRunStatus(
            root: root, profile: "healthalpha", label: label,
            success: true, finishedAt: "2026-07-06T13:00:00Z"
        )
        let agentsDir = try makeAgentsDir()
        try writeMultiHealthPlist(in: agentsDir, label: label, hour: 6, minute: 0)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T14:30:00Z"))
        let inputs = LaunchAgentService.healthInputs(in: agentsDir, now: now)
        let input = try XCTUnwrap(inputs.first { $0.label == label })
        XCTAssertEqual(
            input.lastRunFinishedAt, finished,
            "managed multi agent with no --status-file must read the per-profile status file"
        )
        XCTAssertEqual(input.lastRunSuccess, true)
        XCTAssertTrue(input.isMulti,
                      "a multi.managed-* plist must populate isMulti so it surfaces fleet-wide")
        XCTAssertEqual(input.profile, "",
                       "multi agents carry no owning profile slug")
    }

    func testMultiHealthInputPicksNewestProfileStatus() throws {
        let root = try makeHealthWorkspacesRoot()
        let label = "\(prefix).multi.managed-scan"
        try writeProfileRunStatus(
            root: root, profile: "healthalpha", label: label,
            success: true, finishedAt: "2026-07-06T09:00:00Z"
        )
        let newer = try writeProfileRunStatus(
            root: root, profile: "healthbeta", label: label,
            success: true, finishedAt: "2026-07-06T13:00:00Z"
        )
        let agentsDir = try makeAgentsDir()
        try writeMultiHealthPlist(in: agentsDir, label: label, hour: 6, minute: 0)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T14:30:00Z"))
        let input = try XCTUnwrap(
            LaunchAgentService.healthInputs(in: agentsDir, now: now).first { $0.label == label })
        XCTAssertEqual(input.lastRunFinishedAt, newer,
                       "the newest finished_at across profiles must win")
    }

    func testMultiHealthInputNilWhenNoStatusFilesAnywhere() throws {
        _ = try makeHealthWorkspacesRoot()  // empty workspaces root, no status files
        let label = "\(prefix).multi.managed-reports"
        let agentsDir = try makeAgentsDir()
        try writeMultiHealthPlist(in: agentsDir, label: label, hour: 6, minute: 0)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T14:30:00Z"))
        let input = try XCTUnwrap(
            LaunchAgentService.healthInputs(in: agentsDir, now: now).first { $0.label == label })
        XCTAssertNil(input.lastRunFinishedAt,
                     "no per-profile status file anywhere → nil, as before")
    }

    // MARK: - Per-profile scoping of multi-agent status (2.6 field incident:
    // a failing "Managed Freshness" row flipped to healthy on the Automation
    // screen while its own status file still said success:false).
    //
    // `healthInputs(in:)` (profile-less, headless overdue digest only) is
    // ALLOWED to pick the newest status across every local profile —
    // `testMultiHealthInputPicksNewestProfileStatus` above pins that. But
    // `healthInputs(for:)` (the per-profile Overview/Automation screen path)
    // must resolve a multi agent's status from THAT profile's own record —
    // never a different profile's — else one profile's later success masks
    // another profile's genuine failure.

    func testHealthInputsForProfileScopesMultiStatusToRequestingProfileNotNewestAcrossProfiles() throws {
        let root = try makeHealthWorkspacesRoot()
        let label = "\(prefix).multi.managed-freshness"
        let failedFinish = try writeProfileRunStatus(
            root: root, profile: "healthalpha", label: label,
            success: false, finishedAt: "2026-07-06T14:54:42Z"
        )
        // A DIFFERENT profile's run of the SAME shared managed agent finishes
        // LATER and succeeds — this must never surface on healthalpha's screen.
        try writeProfileRunStatus(
            root: root, profile: "healthbeta", label: label,
            success: true, finishedAt: "2026-07-06T15:00:00Z"
        )
        let agentsDir = try makeAgentsDir()
        try writeMultiHealthPlist(in: agentsDir, label: label, hour: 6, minute: 0)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T15:01:00Z"))

        let alphaInput = try XCTUnwrap(
            LaunchAgentService.healthInputs(for: "healthalpha", in: agentsDir, now: now)
                .first { $0.label == label })
        XCTAssertEqual(alphaInput.lastRunSuccess, false,
                       "healthalpha's own failing run must not be masked by healthbeta's later success")
        XCTAssertEqual(alphaInput.lastRunFinishedAt, failedFinish)

        // Evaluated end-to-end, healthalpha must still surface a .failing issue —
        // this is the exact "Automation screen shows green" field symptom.
        let issues = AutomationHealth.evaluate(
            inputs: LaunchAgentService.healthInputs(for: "healthalpha", in: agentsDir, now: now),
            now: now
        )
        XCTAssertTrue(issues.contains { $0.label == label && $0.kind == .failing },
                      "a failing managed agent must stay failing until ITS OWN profile's next run succeeds")
    }

    func testHealthInputsForProfileShowsThatProfilesOwnSuccessIndependently() throws {
        let root = try makeHealthWorkspacesRoot()
        let label = "\(prefix).multi.managed-freshness"
        try writeProfileRunStatus(
            root: root, profile: "healthalpha", label: label,
            success: false, finishedAt: "2026-07-06T14:54:42Z"
        )
        let betaFinish = try writeProfileRunStatus(
            root: root, profile: "healthbeta", label: label,
            success: true, finishedAt: "2026-07-06T15:00:00Z"
        )
        let agentsDir = try makeAgentsDir()
        try writeMultiHealthPlist(in: agentsDir, label: label, hour: 6, minute: 0)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T15:01:00Z"))
        let betaInput = try XCTUnwrap(
            LaunchAgentService.healthInputs(for: "healthbeta", in: agentsDir, now: now)
                .first { $0.label == label })
        XCTAssertEqual(betaInput.lastRunSuccess, true)
        XCTAssertEqual(betaInput.lastRunFinishedAt, betaFinish,
                       "healthbeta's own success is unaffected by healthalpha's independent failure")
    }

    func testHealthInputsForProfileIgnoresNewerStatusFromADifferentLabel() throws {
        // Refutes the "matches the newest status file regardless of label"
        // framing directly: a newer, successful run recorded under a
        // DIFFERENT label (e.g. a manual "Collect now") in the SAME profile's
        // automation/ directory must never be read as evidence for this
        // managed multi agent's own health.
        let root = try makeHealthWorkspacesRoot()
        let label = "\(prefix).multi.managed-freshness"
        let failedFinish = try writeProfileRunStatus(
            root: root, profile: "healthalpha", label: label,
            success: false, finishedAt: "2026-07-06T14:54:42Z"
        )
        try writeProfileRunStatus(
            root: root, profile: "healthalpha", label: "\(prefix).manual-collect",
            success: true, finishedAt: "2026-07-06T15:00:00Z"
        )
        let agentsDir = try makeAgentsDir()
        try writeMultiHealthPlist(in: agentsDir, label: label, hour: 6, minute: 0)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T15:01:00Z"))
        let input = try XCTUnwrap(
            LaunchAgentService.healthInputs(for: "healthalpha", in: agentsDir, now: now)
                .first { $0.label == label })
        XCTAssertEqual(input.lastRunSuccess, false,
                       "a different label's status file must never be read for this agent")
        XCTAssertEqual(input.lastRunFinishedAt, failedFinish)
    }

    /// Temp `JRC_TEST_WORKSPACES_ROOT` so profile discovery + status reads stay
    /// off the user's real `~/Jamf-Reports/`.
    private func makeHealthWorkspacesRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// Create `<root>/<profile>/` with a config.yaml (so
    /// `ProfileService.discoverLocal` includes it) plus
    /// `automation/<label>_status.json`. Returns the parsed finish Date.
    @discardableResult
    private func writeProfileRunStatus(
        root: URL, profile: String, label: String, success: Bool, finishedAt: String
    ) throws -> Date {
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let automation = workspace.appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: automation, withIntermediateDirectories: true)
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: workspace.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8
        )
        let status: [String: Any] = ["success": success, "finished_at": finishedAt]
        let data = try JSONSerialization.data(withJSONObject: status)
        try data.write(to: automation.appendingPathComponent("\(label)_status.json"))
        return try XCTUnwrap(ISO8601DateFormatter().date(from: finishedAt))
    }

    private func writeMultiHealthPlist(
        in dir: URL, label: String, hour: Int, minute: Int
    ) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/Applications/JamfReports.app/Contents/MacOS/JamfReports",
                "--scheduled-run", "--all-profiles",
                "--mode", "snapshot-only",
            ],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "Disabled": false,
        ]
        let url = dir.appendingPathComponent("\(label).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func makeAgentsDir() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("staleAgents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeLabeledPlist(in dir: URL, label: String, executable: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--scheduled-run"],
            "RunAtLoad": false,
            "Disabled": true,
        ]
        let url = dir.appendingPathComponent("\(label).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
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

    // MARK: - kickstartNow (Automation Health "Run now")

    func testKickstartNowSucceedsOnFirstAttemptNoFallback() async throws {
        let label = "\(prefix).multi.managed-scan"
        let dir = try makeAgentsDir()
        let recorder = ArgvRecorder(exitCodes: [0])

        let outcome = await LaunchAgentService.kickstartNow(
            label: label, in: dir, runLaunchctl: { recorder.record($0) }
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(outcome.usedBootstrapFallback)
        XCTAssertEqual(recorder.calls, [
            ["kickstart", "-k", "gui/\(getuid())/\(label)"],
        ])
    }

    func testKickstartNowFallsBackToBootstrapThenRetriesKickstart() async throws {
        let label = "\(prefix).multi.managed-freshness"
        let dir = try makeAgentsDir()
        try writeMultiHealthPlist(in: dir, label: label, hour: 6, minute: 0)
        let plistURL = dir.appendingPathComponent("\(label).plist")
        // kickstart fails (job not loaded) → bootstrap the plist → kickstart again.
        let recorder = ArgvRecorder(exitCodes: [1, 0, 0])

        let outcome = await LaunchAgentService.kickstartNow(
            label: label, in: dir, runLaunchctl: { recorder.record($0) }
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.usedBootstrapFallback)
        XCTAssertEqual(recorder.calls, [
            ["kickstart", "-k", "gui/\(getuid())/\(label)"],
            ["bootstrap", "gui/\(getuid())", plistURL.path],
            ["kickstart", "-k", "gui/\(getuid())/\(label)"],
        ])
    }

    func testKickstartNowFailsWhenBootstrapFallbackAlsoFails() async throws {
        let label = "\(prefix).multi.managed-reports"
        let dir = try makeAgentsDir()
        try writeMultiHealthPlist(in: dir, label: label, hour: 6, minute: 20)
        let recorder = ArgvRecorder(exitCodes: [1, 1])

        let outcome = await LaunchAgentService.kickstartNow(
            label: label, in: dir, runLaunchctl: { recorder.record($0) }
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.usedBootstrapFallback,
                      "bootstrap was attempted even though it too failed")
        XCTAssertEqual(
            recorder.calls.count, 2, "no second kickstart retry after a failed bootstrap")
    }

    func testKickstartNowFailsWithoutFallbackWhenPlistNotFound() async throws {
        // No plist written for this label in `dir` — the bootstrap fallback
        // has nothing to bootstrap, so it must not be attempted.
        let label = "\(prefix).multi.managed-backup"
        let dir = try makeAgentsDir()
        let recorder = ArgvRecorder(exitCodes: [1])

        let outcome = await LaunchAgentService.kickstartNow(
            label: label, in: dir, runLaunchctl: { recorder.record($0) }
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(outcome.usedBootstrapFallback)
        XCTAssertEqual(recorder.calls.count, 1, "only the initial kickstart attempt runs")
    }

    func testKickstartNowRejectsInvalidLabelBeforeRunningLaunchctl() async {
        let recorder = ArgvRecorder(exitCodes: [])

        let outcome = await LaunchAgentService.kickstartNow(
            label: "com.evil.example", runLaunchctl: { recorder.record($0) }
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(recorder.calls.count, 0, "an invalid label must never reach launchctl")
    }
}

/// Records the exact argv of each injected `runLaunchctl` call and replays a
/// scripted sequence of exit codes — `kickstartNow`'s only source of test
/// truth, since production launchctl is never invoked in tests.
private final class ArgvRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private var exitCodes: [Int32]

    init(exitCodes: [Int32]) {
        self.exitCodes = exitCodes
    }

    func record(_ args: [String]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(args)
        guard !exitCodes.isEmpty else { return 0 }
        return exitCodes.removeFirst()
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }
}
