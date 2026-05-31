import Testing
@testable import JamfReports

struct ScheduleExtensionsTests {

    @Test("Plain language summary for daily schedules")
    func plainLanguageSummaryDaily() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "Daily 08:00",
            cadence: "daily",
            mode: .jamfCLIFull,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )

        #expect(schedule.plainLanguageSummary == "Daily at 08:00 — collects snapshots and builds a workbook")
    }

    @Test("Plain language summary for weekday schedules")
    func plainLanguageSummaryWeekdays() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "Weekdays 06:00",
            cadence: "weekdays",
            mode: .snapshotOnly,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )

        #expect(schedule.plainLanguageSummary == "Every weekday at 06:00 — collects snapshots only")
    }

    @Test("Plain language summary for weekly schedules")
    func plainLanguageSummaryWeekly() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "Mon 07:30",
            cadence: "weekly",
            mode: .csvAssisted,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )

        #expect(schedule.plainLanguageSummary == "Weekly at 07:30 — collects snapshots and builds a workbook (CSV required)")
    }

    @Test("Plain language summary for jamf-cli-only mode")
    func plainLanguageSummaryJamfCLIOnly() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "Daily 09:15",
            cadence: "daily",
            mode: .jamfCLIOnly,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )

        #expect(schedule.plainLanguageSummary == "Daily at 09:15 — builds a workbook from cached data")
    }

    @Test("Plain language summary without time component")
    func plainLanguageSummaryNoTime() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "manual",
            cadence: "custom",
            mode: .snapshotOnly,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )

        #expect(schedule.plainLanguageSummary == "Manual — collects snapshots only")
    }

    @Test("Plain language summary for multiple weekly runs")
    func plainLanguageSummaryMultipleWeekly() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "5× weekly · Mon 08:00",
            cadence: "custom",
            mode: .jamfCLIFull,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )

        #expect(schedule.plainLanguageSummary == "Multiple times per week at 08:00 — collects snapshots and builds a workbook")
    }

    @Test("Migration nudge for jamfCLIOnly with launchAgentLabel")
    func migrationNudgeNeeded() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "Daily 08:00",
            cadence: "daily",
            mode: .jamfCLIOnly,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.test.daily"
        )

        #expect(schedule.needsMigrationNudge == true)
    }

    @Test("No migration nudge for jamfCLIOnly without launchAgentLabel")
    func migrationNudgeNotNeededWithoutLabel() {
        let schedule = Schedule(
            name: "Test",
            profile: "test",
            schedule: "Daily 08:00",
            cadence: "daily",
            mode: .jamfCLIOnly,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true,
            launchAgentLabel: nil
        )

        #expect(schedule.needsMigrationNudge == false)
    }

    @Test("No migration nudge for other modes")
    func migrationNudgeNotNeededOtherModes() {
        for mode in [Schedule.RunMode.snapshotOnly, .jamfCLIFull, .csvAssisted] {
            let schedule = Schedule(
                name: "Test",
                profile: "test",
                schedule: "Daily 08:00",
                cadence: "daily",
                mode: mode,
                next: "—",
                last: "—",
                lastStatus: .ok,
                artifacts: [],
                enabled: true,
                launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.test.daily"
            )

            #expect(schedule.needsMigrationNudge == false)
        }
    }
}