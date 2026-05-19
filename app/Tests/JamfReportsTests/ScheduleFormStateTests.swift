import XCTest
@testable import JamfReports

/// PR-23 T-17: the Schedules-form tier picker. `ScheduleFormState.tiers`
/// tracks the operator's tier selection; it follows the mode default until
/// the operator touches a checkbox, after which it's pinned.
@MainActor
final class ScheduleFormStateTests: XCTestCase {

    // MARK: - Mode → default tier set

    func testSnapshotOnlyDefaultsToRefreshTier() {
        XCTAssertEqual(Schedule.RunMode.snapshotOnly.defaultTiers, [.refresh])
    }

    func testGenerateModesDefaultToAllTiers() {
        let all = Set(CollectionTier.allCases)
        XCTAssertEqual(Schedule.RunMode.jamfCLIFull.defaultTiers, all)
        XCTAssertEqual(Schedule.RunMode.csvAssisted.defaultTiers, all)
    }

    func testJamfCLIOnlyDefaultIsHarmlessAllTiers() {
        // jamf-cli-only never collects, so its tier set is moot. It returns
        // all tiers as a harmless default — the form hides the picker for
        // this mode rather than relying on the value.
        XCTAssertEqual(
            Schedule.RunMode.jamfCLIOnly.defaultTiers,
            Set(CollectionTier.allCases)
        )
    }

    // MARK: - Form initial state

    func testFreshFormDefaultsToSnapshotOnlyTierSet() {
        let form = ScheduleFormState()
        XCTAssertEqual(form.mode, .snapshotOnly)
        XCTAssertEqual(form.tiers, [.refresh],
                       "Fresh form mode is snapshot-only, so tiers start at [.refresh]")
        XCTAssertFalse(form.userTouchedTiers)
    }

    // MARK: - syncTiersToMode

    func testSyncFollowsModeWhenUserHasNotTouched() {
        var form = ScheduleFormState()
        form.mode = .jamfCLIFull
        form.syncTiersToMode()
        XCTAssertEqual(form.tiers, Set(CollectionTier.allCases),
                       "Mode change re-syncs the default when the user hasn't overridden")
    }

    func testSyncIsNoOpAfterUserTouch() {
        var form = ScheduleFormState()
        // Operator manually narrows to scan-only.
        form.tiers = [.scan]
        form.userTouchedTiers = true
        // Mode flips to jamf-cli-full, which defaults to all tiers...
        form.mode = .jamfCLIFull
        form.syncTiersToMode()
        XCTAssertEqual(form.tiers, [.scan],
                       "Once the user has touched the picker, mode changes must not clobber it")
    }

    func testSyncBackToSnapshotOnlyNarrowsWhenUntouched() {
        var form = ScheduleFormState()
        form.mode = .jamfCLIFull
        form.syncTiersToMode()
        XCTAssertEqual(form.tiers, Set(CollectionTier.allCases))
        // Flip back — still untouched, so it narrows again.
        form.mode = .snapshotOnly
        form.syncTiersToMode()
        XCTAssertEqual(form.tiers, [.refresh])
    }

    // MARK: - toSchedule carries the tier set

    func testToScheduleCarriesTiers() {
        var form = ScheduleFormState(defaultProfile: "prod")
        form.name = "Nightly"
        form.tiers = [.refresh, .scan]
        let schedule = form.toSchedule()
        XCTAssertEqual(schedule.tiers, [.refresh, .scan])
    }

    func testToScheduleTiersIsNonNil() {
        // The form always produces a concrete tier set — only legacy plists
        // parsed without --tiers yield a nil Schedule.tiers.
        let form = ScheduleFormState(defaultProfile: "prod")
        XCTAssertNotNil(form.toSchedule().tiers)
    }
}
