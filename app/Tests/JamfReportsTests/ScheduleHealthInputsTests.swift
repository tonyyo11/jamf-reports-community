import XCTest
@testable import JamfReports

final class ScheduleHealthInputsTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func schedule(_ label: String, profile: String, multi: Bool, cadence: String) -> Schedule {
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

    func testTickerDisabledCollapsesEverythingIntoOneIssue() {
        let now = date(2026, 9, 7, 14, 30)
        let overdue = LaunchAgentService.ScheduleHealthInput(
            label: "com.github.tonyyo11.jamf-reports-community.alpha.x", displayName: "x",
            enabled: true, profile: "alpha", isMulti: false,
            expectedFire: date(2026, 9, 7, 6, 20), lastRunFinishedAt: nil,
            lastRunSuccess: nil, lastRunExitCode: nil)
        for status in [TickerStatus.requiresApproval, .notRegistered] {
            let issues = AutomationHealth.evaluate(inputs: [overdue], tickerStatus: status, now: now)
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
