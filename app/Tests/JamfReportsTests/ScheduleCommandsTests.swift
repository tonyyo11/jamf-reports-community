import XCTest
@testable import JamfReports

final class ScheduleCommandsTests: XCTestCase {

    func testAddBuildsARecordFromFlags() throws {
        let r = try Schedules.Add.record(
            name: "Nightly Snapshot", profile: "alpha", allProfiles: false, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:20", tiers: "refresh,scan", disabled: false)
        XCTAssertEqual(r.label, "com.github.tonyyo11.jamf-reports-community.alpha.nightly-snapshot")
        XCTAssertEqual(r.mode, "snapshot-only")
        XCTAssertEqual(r.tiers, ["refresh", "scan"])
        XCTAssertTrue(r.enabled)
    }

    func testAddAllProfilesWithExclusions() throws {
        let r = try Schedules.Add.record(
            name: "fleet", profile: "alpha", allProfiles: true, exclude: "dummy, sandbox",
            mode: "jamf-cli-full", cadence: "Mon 07:00", tiers: nil, disabled: true)
        XCTAssertTrue(r.allProfiles)
        XCTAssertEqual(r.excludedProfiles, ["dummy", "sandbox"])
        XCTAssertFalse(r.enabled)
        XCTAssertNil(r.tiers)
    }

    func testAddRejectsBadModeCadenceProfileOrManagedName() {
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: "alpha", allProfiles: false, exclude: nil,
            mode: "nope", cadence: "Daily 06:20", tiers: nil, disabled: false))
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: "alpha", allProfiles: false, exclude: nil,
            mode: "backup", cadence: "whenever", tiers: nil, disabled: false))
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: "Bad Profile", allProfiles: false, exclude: nil,
            mode: "backup", cadence: "Mon 07:00", tiers: nil, disabled: false))
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "managed-scan", profile: "alpha", allProfiles: true, exclude: nil,
            mode: "backup", cadence: "Mon 07:00", tiers: nil, disabled: false))
    }

    /// `schedules run`, the Schedules screen, and the health-card button all
    /// branch on this exact value to say "queued" instead of reporting a run
    /// that has not happened. It is a shared contract, not an internal detail.
    func testQueuedExitCodeIsTempFail() {
        XCTAssertEqual(TickRunner.queuedExitCode, 75)
    }

    func testSchedulesIsAKnownSubcommand() {
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("schedules"))
    }
}
