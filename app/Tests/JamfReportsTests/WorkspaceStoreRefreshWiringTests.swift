import XCTest
@testable import JamfReports

/// PR-24: the `canRefresh` gate that both refresh entry points
/// (`triggerRefresh`, `observeProfileSwitchRefresh`) consult before
/// touching `RefreshCoordinator`. It's the single demo / invalid-profile
/// guard at the `WorkspaceStore` boundary.
@MainActor
final class WorkspaceStoreRefreshWiringTests: XCTestCase {

    func testCanRefreshIsFalseInDemoMode() {
        let store = WorkspaceStore(demoMode: true)
        XCTAssertFalse(
            store.canRefresh(profileSlug: "prod"),
            "Demo mode has no real Jamf data — refreshes must not fire"
        )
    }

    func testCanRefreshIsTrueForValidProfileWhenNotDemo() {
        let store = WorkspaceStore(demoMode: false)
        XCTAssertTrue(store.canRefresh(profileSlug: "prod"))
        XCTAssertTrue(store.canRefresh(profileSlug: "cbp-prod"))
    }

    func testCanRefreshIsFalseForInvalidProfile() {
        let store = WorkspaceStore(demoMode: false)
        // Spaces, punctuation, and empty all fail ProfileService.isValid.
        XCTAssertFalse(store.canRefresh(profileSlug: "Bad Profile!"))
        XCTAssertFalse(store.canRefresh(profileSlug: ""))
        XCTAssertFalse(store.canRefresh(profileSlug: "../escape"))
    }

    func testTriggerRefreshEngagesCoordinatorForValidProfile() {
        // End-to-end: a non-demo trigger reaches the coordinator, which
        // registers the in-flight task synchronously (isRefreshing flips
        // true before the awaited collect runs).
        let store = WorkspaceStore(demoMode: false)
        store.triggerRefresh(for: "prodprofile")
        XCTAssertTrue(
            store.coordinator.isRefreshing(profile: "prodprofile", tier: .refresh),
            "A valid non-demo trigger must start a Refresh-tier task"
        )
    }

    func testTriggerRefreshIsNoOpInDemoMode() {
        let store = WorkspaceStore(demoMode: true)
        store.triggerRefresh(for: "prodprofile")
        XCTAssertFalse(
            store.coordinator.isRefreshing(profile: "prodprofile", tier: .refresh),
            "Demo mode must not engage the coordinator"
        )
    }

    func testRegisterForegroundRefreshIsIdempotent() {
        // The genuine assertion here is "doesn't crash / doesn't trap on a
        // second call" — the observer-token guard returns early. Observer
        // count isn't externally observable, but a double call must be safe
        // because the root view's .task can re-run on a shell remount.
        let store = WorkspaceStore(demoMode: false)
        store.registerForegroundRefresh()
        store.registerForegroundRefresh()
    }
}
