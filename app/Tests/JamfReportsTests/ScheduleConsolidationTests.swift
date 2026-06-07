import XCTest
@testable import JamfReports

/// Spec for `ScheduleConsolidation.candidates` — the pure detector for hand-built
/// LaunchAgents the active managed policy now duplicates. Correctness weight is on
/// never recommending removal of (a) a managed agent, (b) work the policy does not
/// cover, or (c) collection on a profile managed deliberately excludes.
final class ScheduleConsolidationTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    private func handBuiltMulti(_ name: String, mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: name, profile: "", schedule: "Daily 08:00", cadence: "daily",
            mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "\(prefix).multi.\(name)",
            multiTarget: MultiTarget(scope: .all)
        )
    }

    private func handBuiltPerProfile(_ name: String, profile: String, mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: name, profile: profile, schedule: "Daily 08:00", cadence: "daily",
            mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "\(prefix).\(profile).\(name)",
            multiTarget: nil
        )
    }

    private func managedFreshnessAgent() -> Schedule {
        Schedule(
            name: "managed-freshness", profile: "", schedule: "Daily 06:00", cadence: "daily",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "\(prefix).multi.managed-freshness",
            multiTarget: MultiTarget(scope: .all)
        )
    }

    // MARK: - Gating on managed master switch

    func testUnmanaged_returnsEmpty() {
        let installed = [handBuiltMulti("morning-snapshot-all", mode: .snapshotOnly)]
        let policy = AutomationPolicy(isManaged: false)
        XCTAssertTrue(ScheduleConsolidation.candidates(installed: installed, policy: policy).isEmpty)
    }

    // MARK: - Common prod case (no exclusions)

    func testManagedNoExclusions_flagsHandBuiltNotManaged() {
        let installed = [
            handBuiltMulti("morning-snapshot-all", mode: .snapshotOnly),
            handBuiltPerProfile("weekly-jamf-cli-all", profile: "prod", mode: .jamfCLIFull),
            handBuiltMulti("weekly-backups", mode: .backup),
            managedFreshnessAgent(),  // reserved — must NOT be flagged
        ]
        let policy = AutomationPolicy(
            isManaged: true, freshnessEnabled: true, scanEnabled: true,
            reportsCadence: .weekly, backupsEnabled: true
        )
        let result = ScheduleConsolidation.candidates(installed: installed, policy: policy)
        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result.contains { $0.label.hasSuffix("managed-freshness") })
        XCTAssertEqual(
            Set(result.map(\.coveredBy)),
            ["data freshness", "report generation", "configuration backup"]
        )
    }

    // MARK: - Kind-not-enabled (under-recommend)

    func testReportsOff_doesNotFlagGenerateAgent() {
        let installed = [handBuiltPerProfile("weekly-gen", profile: "prod", mode: .jamfCLIOnly)]
        let policy = AutomationPolicy(isManaged: true, reportsCadence: .off)
        XCTAssertTrue(ScheduleConsolidation.candidates(installed: installed, policy: policy).isEmpty)
    }

    func testBackupsOff_doesNotFlagBackupAgent() {
        let installed = [handBuiltMulti("weekly-backups", mode: .backup)]
        let policy = AutomationPolicy(isManaged: true, backupsEnabled: false)
        XCTAssertTrue(ScheduleConsolidation.candidates(installed: installed, policy: policy).isEmpty)
    }

    func testSnapshotCoveredByScanWhenFreshnessOff() {
        let installed = [handBuiltMulti("refresh", mode: .snapshotOnly)]
        let policy = AutomationPolicy(isManaged: true, freshnessEnabled: false, scanEnabled: true)
        let result = ScheduleConsolidation.candidates(installed: installed, policy: policy)
        XCTAssertEqual(result.first?.coveredBy, "weekly deep scan")
    }

    // MARK: - excludedProfiles (under-recommend on partial coverage)

    func testExcludedPerProfileAgent_notFlagged_butIncludedProfileIs() {
        let installed = [
            handBuiltPerProfile("snap", profile: "dev", mode: .snapshotOnly),   // excluded
            handBuiltPerProfile("snap", profile: "prod", mode: .snapshotOnly),  // covered
        ]
        let policy = AutomationPolicy(isManaged: true, excludedProfiles: ["dev"])
        let result = ScheduleConsolidation.candidates(installed: installed, policy: policy)
        XCTAssertEqual(result.map(\.label), ["\(prefix).prod.snap"])
    }

    func testMultiAgentNotFlagged_whenAnyProfileExcluded() {
        let installed = [handBuiltMulti("morning-snapshot-all", mode: .snapshotOnly)]
        let policy = AutomationPolicy(isManaged: true, excludedProfiles: ["dev"])
        // managed all-profiles skips "dev" → partial coverage → do not recommend.
        XCTAssertTrue(ScheduleConsolidation.candidates(installed: installed, policy: policy).isEmpty)
    }

    // MARK: - coveringCapability mapping

    func testCoveringCapabilityMapping() {
        let p = AutomationPolicy(
            isManaged: true, freshnessEnabled: true, scanEnabled: true,
            reportsCadence: .weekly, backupsEnabled: true
        )
        XCTAssertEqual(ScheduleConsolidation.coveringCapability(for: .snapshotOnly, policy: p), "data freshness")
        XCTAssertEqual(ScheduleConsolidation.coveringCapability(for: .jamfCLIFull, policy: p), "report generation")
        XCTAssertEqual(ScheduleConsolidation.coveringCapability(for: .csvAssisted, policy: p), "report generation")
        XCTAssertEqual(ScheduleConsolidation.coveringCapability(for: .backup, policy: p), "configuration backup")
    }
}
