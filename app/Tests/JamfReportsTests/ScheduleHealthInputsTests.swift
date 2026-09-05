import XCTest
@testable import JamfReports

final class ScheduleHealthInputsTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func schedule(
        _ label: String, profile: String, multi: Bool, cadence: String
    ) -> Schedule {
        Schedule(
            name: "n", profile: profile, schedule: cadence, cadence: "custom", mode: .snapshotOnly,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: label, multiTarget: multi ? MultiTarget(scope: .all) : nil)
    }

    func testInputsCarryExpectedFireProfileAndMultiFlag() {
        let now = date(2026, 9, 7, 14, 30)
        let single = schedule("com.github.tonyyo11.jamf-reports-community.alpha.x",
                              profile: "alpha", multi: false, cadence: "Daily 06:20")
        let multi = schedule("com.github.tonyyo11.jamf-reports-community.multi.y",
                             profile: "", multi: true, cadence: "Mon 07:00")
        let inputs = LaunchAgentService.healthInputs(
            schedules: [single, multi], statusProfile: nil, now: now)
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].expectedFire, date(2026, 9, 7, 6, 20))
        XCTAssertEqual(inputs[0].profile, "alpha")
        XCTAssertFalse(inputs[0].isMulti)
        XCTAssertEqual(inputs[1].expectedFire, date(2026, 9, 7, 7, 0))  // Monday
        XCTAssertTrue(inputs[1].isMulti)
    }

    func testUnreadableCadenceYieldsNoExpectedFire() {
        let s = schedule("com.github.tonyyo11.jamf-reports-community.alpha.x",
                         profile: "alpha", multi: false, cadence: "whenever")
        let inputs = LaunchAgentService.healthInputs(
            schedules: [s], statusProfile: nil, now: Date())
        XCTAssertNil(inputs.first?.expectedFire)
    }

    /// A managed (multi) schedule records its status once per profile under one
    /// label. `statusProfile` must read THAT profile's own record: a fleet-wide
    /// caller takes the newest finish, but a per-profile screen must keep
    /// showing this profile's failure even when a sibling profile succeeded
    /// later. Coverage restored after the writer-path test that used to pin the
    /// status-file naming was deleted with its dead symbols.
    func testMultiStatusIsReadPerProfileNotNewestWins() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("jrc-health-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let label = "com.github.tonyyo11.jamf-reports-community.multi.managed-freshness"
        // Newer SUCCESS on one profile, older FAILURE on the other.
        try writeStatus(root: root, profile: "winner", label: label,
                        finished: date(2026, 9, 7, 8, 0), success: true)
        try writeStatus(root: root, profile: "loser", label: label,
                        finished: date(2026, 9, 7, 6, 30), success: false)

        let multi = schedule(label, profile: "", multi: true, cadence: "Daily 06:20")
        let scoped = LaunchAgentService.healthInputs(
            schedules: [multi], statusProfile: "loser", now: date(2026, 9, 7, 9, 0))
        XCTAssertEqual(scoped.first?.lastRunSuccess, false,
                       "a sibling profile's later success must not clear this one's failure")

        let fleetWide = LaunchAgentService.healthInputs(
            schedules: [multi], statusProfile: nil, now: date(2026, 9, 7, 9, 0))
        XCTAssertEqual(fleetWide.first?.lastRunSuccess, true,
                       "the profile-less caller takes the newest finish across profiles")
    }

    private func writeStatus(
        root: URL, profile: String, label: String, finished: Date, success: Bool
    ) throws {
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let automation = workspace.appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: automation, withIntermediateDirectories: true)
        // `ProfileService.discoverLocal` (which the profile-less branch scans)
        // only counts a directory as a profile when it holds a config.yaml.
        try "".write(to: workspace.appendingPathComponent("config.yaml"),
                     atomically: true, encoding: .utf8)
        let payload: [String: Any] = [
            "finished_at": ISO8601DateFormatter().string(from: finished),
            "success": success,
            "exit_code": success ? 0 : 1,
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: automation.appendingPathComponent("\(label)_status.json"))
    }

    func testTickerDisabledCollapsesEverythingIntoOneIssue() {
        let now = date(2026, 9, 7, 14, 30)
        let overdue = LaunchAgentService.ScheduleHealthInput(
            label: "com.github.tonyyo11.jamf-reports-community.alpha.x", displayName: "x",
            enabled: true, profile: "alpha", isMulti: false,
            expectedFire: date(2026, 9, 7, 6, 20), lastRunFinishedAt: nil,
            lastRunSuccess: nil, lastRunExitCode: nil)
        for status in [TickerStatus.requiresApproval, .notRegistered] {
            let issues = AutomationHealth.evaluate(
                inputs: [overdue], tickerStatus: status, now: now)
            XCTAssertEqual(issues.map(\.kind), [.tickerDisabled], "\(status)")
            XCTAssertEqual(issues.first?.label, AutomationHealth.tickerLabel)
            XCTAssertTrue(issues.first?.isMulti == true)
        }
        XCTAssertEqual(AutomationHealth.evaluate(
            inputs: [overdue], tickerStatus: .enabled, now: now).map(\.kind), [.overdue])
        // A dev build (unavailable) is not a disabled ticker.
        XCTAssertEqual(AutomationHealth.evaluate(
            inputs: [overdue], tickerStatus: .unavailable, now: now).map(\.kind), [.overdue])
    }
}
