import Foundation
import XCTest
@testable import JamfReports

/// v2.2.0 managed-agent layer. As of 2.8.0 the reconcile/plan machinery is
/// gone (the SMAppService ticker reads `desiredSchedules` fresh each tick),
/// so the remaining correctness weight is on `owns` (identity, never a
/// prefix match) and `desiredSchedules` (policy → specs, incl. cadence
/// strings).
final class ManagedAutomationTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    // MARK: - Ownership (the destructive-action guard)

    func testOwnsAcceptsOnlyExactReservedLabels() {
        for kind in ManagedAutomation.ManagedKind.allCases {
            XCTAssertTrue(ManagedAutomation.owns(ManagedAutomation.label(for: kind)))
        }
        // Prefix-y impostors must NOT be owned — a destructive action would
        // otherwise touch a user's agent named like a managed one.
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).multi.managed-freshness-2"))
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).multi.managed-freshnessX"))
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).multi.my-schedule"))
        XCTAssertFalse(ManagedAutomation.owns("\(prefix).alpha.managed-freshness"))
        XCTAssertFalse(ManagedAutomation.owns("com.evil.multi.managed-freshness"))
    }

    // MARK: - Base profile

    /// Three call sites derived the managed base profile separately and two
    /// ignored the exclusions — an excluded profile could end up naming the
    /// run the policy exists to skip.
    func testManagedBaseProfileSkipsExcludedAndYieldsNilWhenAllAreExcluded() {
        let profiles = ["dummy", "prod", "sandbox"].map {
            JamfCLIProfile(name: $0, url: "(local workspace)", schedules: 0, status: .idle)
        }
        var policy = AutomationPolicy()
        policy.excludedProfiles = ["dummy"]
        XCTAssertEqual(
            ManagedAutomation.managedBaseProfile(profiles: profiles, policy: policy), "prod")

        policy.excludedProfiles = ["dummy", "prod", "sandbox"]
        XCTAssertNil(ManagedAutomation.managedBaseProfile(profiles: profiles, policy: policy))
        XCTAssertNil(ManagedAutomation.managedBaseProfile(
            names: profiles.map(\.name), policy: policy))
    }

    // MARK: - Desired specs

    func testNoDesiredWhenUnmanaged() {
        XCTAssertTrue(
            ManagedAutomation.desiredSchedules(for: AutomationPolicy(), baseProfile: "alpha").isEmpty
        )
    }

    func testNoDesiredWithoutBaseProfile() {
        var p = AutomationPolicy(); p.isManaged = true
        XCTAssertTrue(ManagedAutomation.desiredSchedules(for: p, baseProfile: nil).isEmpty)
    }

    func testManagedAllPoliciesProduceFourAgents() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.backupsEnabled = true
        let desired = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
        let labels = Set(desired.compactMap(\.launchAgentLabel))
        XCTAssertEqual(labels, ManagedAutomation.reservedLabels)
        XCTAssertTrue(desired.allSatisfy(\.isMulti))
    }

    func testReportsOffAndBackupsOffDropThoseAgents() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.reportsCadence = .off
        p.backupsEnabled = false
        let labels = Set(
            ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
                .compactMap(\.launchAgentLabel)
        )
        XCTAssertEqual(labels, [
            ManagedAutomation.label(for: .freshness),
            ManagedAutomation.label(for: .scan),
        ])
    }

    func testPerKindModesTiersAndCadenceStrings() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.backupsEnabled = true
        p.scanWeekday = 1        // Mon
        p.reportsWeekday = 1     // Mon
        p.backupsWeekday = 0     // Sun
        let byLabel = Dictionary(
            uniqueKeysWithValues: ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
                .map { ($0.launchAgentLabel ?? "", $0) }
        )

        let freshness = byLabel[ManagedAutomation.label(for: .freshness)]
        XCTAssertEqual(freshness?.mode, .snapshotOnly)
        XCTAssertEqual(freshness?.tiers, [.refresh, .inventory])
        XCTAssertEqual(freshness?.schedule, "Daily 06:00")

        let scan = byLabel[ManagedAutomation.label(for: .scan)]
        XCTAssertEqual(scan?.mode, .snapshotOnly)
        XCTAssertEqual(scan?.tiers, [.scan])
        XCTAssertEqual(scan?.schedule, "Mon 06:10", "scan staggered +10")

        let reports = byLabel[ManagedAutomation.label(for: .reports)]
        XCTAssertEqual(reports?.mode, .jamfCLIOnly, "reports generate from fresh cache")
        XCTAssertNil(reports?.tiers)
        XCTAssertEqual(reports?.schedule, "Mon 06:20", "reports staggered +20")

        let backup = byLabel[ManagedAutomation.label(for: .backup)]
        XCTAssertEqual(backup?.mode, .backup)
        XCTAssertEqual(backup?.schedule, "Sun 06:30", "backup staggered +30")
    }

    func testExclusionsFlowIntoDesiredSchedules() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.excludedProfiles = ["dummy"]
        let desired = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
        XCTAssertTrue(desired.allSatisfy { $0.excludedProfiles == ["dummy"] })
    }

    func testStaggeredTimeClampsWithinDay() {
        XCTAssertEqual(ManagedAutomation.staggeredTime(base: "06:00", offsetMinutes: 30), "06:30")
        XCTAssertEqual(ManagedAutomation.staggeredTime(base: "23:50", offsetMinutes: 30), "23:59")
        XCTAssertEqual(ManagedAutomation.staggeredTime(base: "06:55", offsetMinutes: 10), "07:05")
    }

    /// The writer must emit the same string shape
    /// `LaunchAgentService.formatCalendar` renders on read-back ("Day N HH:mm"),
    /// not the ordinal form — otherwise a monthly reports agent's signature
    /// never converges and the ticker never settles.
    func testMonthlyReportsCadenceStringMatchesReaderFormat() {
        var p = AutomationPolicy(); p.isManaged = true
        p.reportsCadence = .monthly
        p.reportsDayOfMonth = 15
        let reports = ManagedAutomation.desiredSchedules(for: p, baseProfile: "alpha")
            .first { $0.launchAgentLabel == ManagedAutomation.label(for: .reports) }
        XCTAssertEqual(reports?.schedule, "Day 15 06:20", "reports staggered +20")
    }

    func testBundleLocationWarningOnlyOutsideApplicationsFolders() {
        let home = URL(fileURLWithPath: "/Users/dev", isDirectory: true)
        let inApps = "/Applications/JamfReports.app/Contents/MacOS/JamfReports"
        let inHomeApps = "/Users/dev/Applications/JamfReports.app/Contents/MacOS/JamfReports"
        let scratch = "/Users/dev/jr-nonnested/app/build/JamfReports.app/Contents/MacOS/JamfReports"
        XCTAssertNil(ManagedAutomation.bundleLocationWarning(executablePath: inApps, home: home))
        XCTAssertNil(
            ManagedAutomation.bundleLocationWarning(executablePath: inHomeApps, home: home))
        XCTAssertNil(ManagedAutomation.bundleLocationWarning(executablePath: nil, home: home))
        let warning = try? XCTUnwrap(
            ManagedAutomation.bundleLocationWarning(executablePath: scratch, home: home))
        XCTAssertEqual(warning?.contains("/Users/dev/jr-nonnested/app/build/JamfReports.app"), true)
        XCTAssertEqual(warning?.contains("/Contents/"), false)
    }
}
