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

    func testParseJRCMultiLaunchAgentPreservesModeAndBaseProfile() throws {
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
                "--base-profile",
                "alpha",
                "--multi-profiles",
                "alpha,beta",
                "--multi-sequential",
            ],
            "StartCalendarInterval": ["Hour": 6, "Minute": 0],
            "Disabled": false,
        ])

        let schedule = try XCTUnwrap(LaunchAgentService.parse(plistURL))

        XCTAssertEqual(schedule.launchAgentLabel, label)
        XCTAssertEqual(schedule.profile, "alpha")
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
                "--base-profile",
                "alpha",
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
        XCTAssertEqual(schedule.profile, "alpha")
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
