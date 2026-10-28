import Foundation
import XCTest
@testable import JamfReports

/// A schedule on a profile of another product ends its retries, writes nothing in the
/// workspace and posts nothing, while an unresolved or Jamf Pro profile runs as before.
final class ScheduledRunProductGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "protect-only"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-product-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func schedule(_ mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: "guard", profile: profile, schedule: "manual", cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: nil, multiTarget: nil, tiers: nil, excludedProfiles: nil)
    }

    private var automation: URL {
        root.appendingPathComponent("Jamf-Reports/\(profile)/automation")
    }

    func testARefusedScheduleSucceedsEndsItsRetriesAndLeavesOneMarkedRecord() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let modes: [Schedule.RunMode] = [.jamfCLIFull, .snapshotOnly, .backup]
        for mode in modes {
            let outcome = await runSchedule(schedule(mode), verbose: false)
            XCTAssertEqual(outcome.exitCode, 0, "\(mode)")
            XCTAssertTrue(outcome.endsRetries, "\(mode): the tick must not retry it")
            XCTAssertTrue(outcome.succeeded, "\(mode)")
        }
        let runs = RunHistoryService.list(profile: profile)
        XCTAssertEqual(runs.count, modes.count, "one Run History entry per refused run")
        for run in runs {
            XCTAssertEqual(run.exitCode, 0)
            let text = try String(contentsOf: run.logURL, encoding: .utf8)
            XCTAssertTrue(text.contains("[skip] scheduled"), text)
        }
        let statuses = try FileManager.default.contentsOfDirectory(atPath: automation.path)
            .filter { $0.hasSuffix("_status.json") }
        XCTAssertEqual(statuses.count, modes.count)
        for name in statuses {
            let data = try Data(contentsOf: automation.appendingPathComponent(name))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["refused"] as? Bool, true, name)
        }
        let stateDir = root.appendingPathComponent(
            "Jamf-Reports/\(profile)/jamf-cli-data/state").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir),
                       "a refused run is not a failed source: no .fail file")
    }

    func testARefusedRunInAProfileWithNoWorkspaceCreatesNoFolder() async throws {
        let ghost = "protect-ghost"
        try ProductGuardSeed.seed(profile: ghost, product: "protect", in: root)
        var ghostSchedule = schedule(.snapshotOnly)
        ghostSchedule.profile = ghost
        let outcome = await runSchedule(ghostSchedule, verbose: false)
        XCTAssertEqual(outcome.exitCode, 0)
        let folder = root.appendingPathComponent("Jamf-Reports/\(ghost)").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testAScheduleThatReadsOnlyTheCacheIsNotRefused() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        _ = await runSchedule(schedule(.jamfCLIOnly), verbose: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: automation.path),
                      "jamf-cli-only sends no command and still records its run")
    }

    func testRefusalIsTheSameRuleAsTheRouterAndSchedulesAdd() throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        XCTAssertNotNil(CollectRouter.proRunRefusal(
            profile: profile, operation: "Collect", config: nil))
        let school = try ConfigLoader.loadFromString(
            "school_cli:\n  enabled: true\n  profile: \(profile)\n")
        XCTAssertNil(CollectRouter.proRunRefusal(
            profile: profile, operation: "Collect", config: school),
                     "a School workspace is not a Pro run")
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: profile, allProfiles: false, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:20", tiers: nil, disabled: false))
        XCTAssertNoThrow(try Schedules.Add.record(
            name: "x", profile: profile, allProfiles: true, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:20", tiers: nil, disabled: false))
    }
}

/// A refused schedule writes no status file, so it must not reach the dead-man switch.
final class ScheduledRunHealthProductGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "protect-only"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-health-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func schedule(_ mode: Schedule.RunMode, multi: Bool = false) -> Schedule {
        Schedule(
            name: "guard-\(mode.rawValue)", profile: multi ? "" : profile, schedule: "Daily 06:20",
            cadence: "custom", mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.x.\(mode.rawValue)",
            multiTarget: multi ? MultiTarget(scope: .all) : nil, tiers: nil, excludedProfiles: nil)
    }

    func testARefusedScheduleIsFailingWithTheReasonNeverOverdue() throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let schedules = [
            schedule(.jamfCLIFull), schedule(.snapshotOnly), schedule(.backup),
            schedule(.jamfCLIOnly), schedule(.snapshotOnly, multi: true)]
        let now = Date()
        let inputs = LaunchAgentService.healthInputs(
            schedules: schedules, statusProfile: nil, now: now)
        XCTAssertEqual(inputs.count, 5)
        XCTAssertEqual(inputs.map { $0.refusal != nil }, [true, true, true, false, false],
                       "a cache-only and an all-profiles schedule are not refused")
        // Two days on, with no status file anywhere: the old reading was overdue.
        let issues = AutomationHealth.evaluate(
            inputs: inputs, now: now.addingTimeInterval(86_400 * 2))
        let refused = issues.filter { $0.profile == profile && $0.reason != nil }
        XCTAssertEqual(refused.count, 3)
        XCTAssertTrue(refused.allSatisfy { $0.kind == .failing })
        XCTAssertTrue(refused.allSatisfy { $0.reason?.contains("'\(profile)' is a Jamf Protect profile") == true })
        XCTAssertTrue(issues.filter { $0.kind == .overdue }.allSatisfy { $0.reason == nil })
    }

    /// A refused run's record is exit 0, but it covers no fire: with the refusal gone the
    /// schedule reads overdue, and while it stands the reason shows.
    func testARefusedRecordNeitherSatisfiesAFireNorReadsAsSuccess() throws {
        let fm = FileManager.default
        let automation = root.appendingPathComponent("Jamf-Reports/\(profile)/automation")
        try fm.createDirectory(at: automation, withIntermediateDirectories: true)
        // After the workspace folder was created (a fire before it is never overdue), always.
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2099, month: 1, day: 5, hour: 12)))
        let finished = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
        let sched = schedule(.snapshotOnly)
        let label = try XCTUnwrap(sched.launchAgentLabel)
        let status: [String: Any] = [
            "success": true, "exit_code": 0, "refused": true, "finished_at": finished]
        try JSONSerialization.data(withJSONObject: status)
            .write(to: automation.appendingPathComponent("\(label)_status.json"))

        for (refusal, expected) in [("nope", AutomationHealthIssue.Kind.failing), (nil, .overdue)] {
            let inputs = LaunchAgentService.healthInputs(
                schedules: [sched], statusProfile: nil, now: now, refusal: { _ in refusal })
            let input = try XCTUnwrap(inputs.first)
            XCTAssertNil(input.lastRunFinishedAt)
            XCTAssertNil(input.lastRunSuccess)
            let issues = AutomationHealth.evaluate(inputs: inputs, now: now)
            XCTAssertEqual(issues.first?.kind, expected)
            XCTAssertEqual(issues.first?.reason, refusal)
        }
    }

    func testAJamfProScheduleIsNotRefused() throws {
        try ProductGuardSeed.seed(profile: profile, product: "pro", in: root)
        XCTAssertNil(LaunchAgentService.healthInputs(
            schedules: [schedule(.jamfCLIFull)], statusProfile: nil).first?.refusal)
    }
}

/// A config.yaml that exists but does not decode cannot say which product the profile is, so
/// the run fails with the decode error instead of being read as Jamf Pro and refused.
final class ScheduledRunUndecodableConfigTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "school-broken"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-undecodable-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func schedule(_ mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: "broken", profile: profile, schedule: "manual", cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: nil, multiTarget: nil, tiers: nil, excludedProfiles: nil)
    }

    private func writeConfig(_ yaml: String) throws {
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    func testAnUndecodableConfigFailsTheRunInsteadOfRefusingItWithExitZero() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        try writeConfig("school_cli:\n  enabled: true\nthresholds: not-a-mapping\n")
        XCTAssertThrowsError(try ConfigLoader.load(from: try XCTUnwrap(
            ProfileService.workspaceURL(for: profile)).appendingPathComponent("config.yaml")))
        for mode in [Schedule.RunMode.jamfCLIFull, .snapshotOnly] {
            let outcome = await runSchedule(schedule(mode), verbose: false)
            XCTAssertEqual(outcome.exitCode, 1, "\(mode)")
            XCTAssertFalse(outcome.endsRetries, "\(mode): the tick must retry it")
        }
    }

    /// A backup needs only the profile: it runs, and a profile of another
    /// product is refused as it is with no config.yaml.
    func testABackupStillRuns() async throws {
        try writeConfig("thresholds: not-a-mapping\n")
        _ = await runSchedule(schedule(.backup), verbose: false)
        let logs = try WorkspacePaths.runHistoryDir(for: profile)
        let log = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: logs.path)
            .first { $0.hasSuffix(".log") })
        let text = try String(contentsOf: logs.appendingPathComponent(log), encoding: .utf8)
        // The decode warning now comes from the Protect step (ProtectBackupTests), once.
        XCTAssertFalse(text.contains("nothing ran"), text)
        XCTAssertTrue(text.contains("backup"), text)

        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let refused = await runSchedule(schedule(.backup), verbose: false)
        XCTAssertEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.endsRetries)
    }

    func testTheFailureIsInRunHistoryWithTheDecodeError() async throws {
        try writeConfig("thresholds: not-a-mapping\n")
        _ = await runSchedule(schedule(.snapshotOnly), verbose: false)
        let logs = try WorkspacePaths.runHistoryDir(for: profile)
        let log = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: logs.path)
            .first { $0.hasSuffix(".log") })
        let text = try String(contentsOf: logs.appendingPathComponent(log), encoding: .utf8)
        XCTAssertTrue(text.contains("config.yaml does not decode"), text)
        XCTAssertTrue(text.contains("Config decode failed"), text)
    }

    /// notify lives in the file that failed to decode; its own failure card must still go out.
    func testTheFailureCardAndTheOverdueDigestStillReadTheNotifyBlock() async throws {
        WebhookCapture.start()
        addTeardownBlock { WebhookCapture.stop() }
        try writeConfig(
            "thresholds: not-a-mapping\nnotify:\n  enabled: true\n  provider: teams\n"
                + "  url: \"\(WebhookCapture.webhookURL)\"\n")
        let outcome = await runSchedule(schedule(.snapshotOnly), verbose: false)
        XCTAssertEqual(outcome.exitCode, 1)
        let posted = WebhookCapture.posted
        XCTAssertEqual(posted.count, 1, "one failure card")
        XCTAssertTrue(posted.first?.contains("Failed") == true, "\(posted)")

        let targets = notifyTargets(in: [profile]) { _ in false }
        XCTAssertEqual(targets.map(\.profile), [profile], "the digest reaches this workspace")
    }

    func testAnAbsentConfigStillRunsAsBefore() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let outcome = await runSchedule(schedule(.snapshotOnly), verbose: false)
        XCTAssertEqual(outcome.exitCode, 0, "a Protect login with no config is still refused")
    }
}
