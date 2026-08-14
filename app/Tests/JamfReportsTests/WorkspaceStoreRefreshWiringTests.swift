import Foundation
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

    /// `autoRefreshAuditIfStale` guards re-entry so rapid profile switches or
    /// repeated launch-task firings can't stack concurrent audit runs. Setting
    /// the flag directly (rather than racing two real async calls) makes the
    /// guard's early-return deterministic to test.
    func testAutoRefreshAuditIfStaleSkipsWhenAlreadyInFlight() async {
        let store = WorkspaceStore(demoMode: false)
        store.autoAuditRefreshInFlight = true

        let auditCalled = CallFlag()
        await store.autoRefreshAuditIfStale(audit: { _ in
            auditCalled.set(true)
            return 0
        })

        XCTAssertFalse(auditCalled.value, "A second call must no-op while one is already in flight")
        XCTAssertTrue(
            store.autoAuditRefreshInFlight,
            "The no-op path must not clear a flag it didn't set"
        )
    }

    func testAutoRefreshAuditIfStaleClearsFlagOnCompletion() async {
        let store = WorkspaceStore(demoMode: false)
        await store.autoRefreshAuditIfStale(audit: { _ in 0 })
        XCTAssertFalse(
            store.autoAuditRefreshInFlight,
            "The flag must clear once the call completes, win or lose"
        )
    }
}

/// Thread-safe bool box so a `@Sendable` test closure can record whether it
/// ran, mirroring the `RouterCallCounter` idiom in CollectRouterTests.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set(_ newValue: Bool) { lock.withLock { _value = newValue } }
}
