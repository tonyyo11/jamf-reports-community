import XCTest
@testable import JamfReports

/// v2.2.0 catch-up-on-wake target selection (the pure decision; the collect
/// execution reuses the CollectRouter path exercised elsewhere).
final class CatchUpCollectTests: XCTestCase {

    func testNoTargetsWhenUnmanaged() {
        XCTAssertTrue(
            WorkspaceStore.catchUpTargets(policy: AutomationPolicy(),
                                          discovered: ["alpha", "beta"]).isEmpty
        )
    }

    func testNoTargetsWhenFreshnessDisabled() {
        var p = AutomationPolicy(); p.isManaged = true; p.freshnessEnabled = false
        XCTAssertTrue(
            WorkspaceStore.catchUpTargets(policy: p, discovered: ["alpha"]).isEmpty
        )
    }

    func testManagedFreshnessReturnsAllValidProfiles() {
        var p = AutomationPolicy(); p.isManaged = true
        XCTAssertEqual(
            WorkspaceStore.catchUpTargets(policy: p, discovered: ["alpha", "beta"]),
            ["alpha", "beta"]
        )
    }

    func testExcludedAndInvalidProfilesAreDropped() {
        var p = AutomationPolicy(); p.isManaged = true; p.excludedProfiles = ["dummy"]
        XCTAssertEqual(
            WorkspaceStore.catchUpTargets(
                policy: p, discovered: ["alpha", "dummy", "Bad Slug", "beta"]
            ),
            ["alpha", "beta"]
        )
    }
}
