import Foundation
@testable import JamfReports

extension Date {
    /// 2026-06-15 12:00 local: mid-day and mid-month, so a test that stamps a local day never
    /// depends on when it runs. Hand it to the code under test through its `now`/`day` seam.
    static let testNoon: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 6
        parts.day = 15
        parts.hour = 12
        return Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 1_781_539_200)
    }()
}

/// A daily schedule that fires at 10:00 local, two hours before `Date.testNoon`, and has never
/// run: overdue from about 11:00, the dead-man switch's one-hour grace.
func dailyScheduleFiringAtTen(profile: String) -> Schedule {
    Schedule(
        name: "Daily", profile: profile, schedule: "Daily 10:00",
        cadence: "custom", mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok,
        artifacts: [], enabled: true,
        launchAgentLabel: "\(LaunchAgentWriter.labelPrefix).\(profile).daily")
}

extension Date {
    /// Past the window in which `tickLockHeldRecently` still reads a released lock as busy.
    static var testNoonAfterTheLockWindow: Date {
        testNoon.addingTimeInterval(TickLock.wakeInterval + 61)
    }
}
