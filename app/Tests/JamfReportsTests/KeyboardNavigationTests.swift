import XCTest
@testable import JamfReports

// Pure helpers — no @MainActor needed. All inputs are value types.
final class KeyboardNavigationTests: XCTestCase {

    // MARK: - nextVisibleTab

    func testNextTabAdvancesInSidebarOrder() {
        let v = TabVisibility()
        let result = nextVisibleTab(from: .overview, in: v)
        // .fleet is the second entry in Tab.sidebarOrder
        XCTAssertEqual(result, .fleet)
    }

    func testNextTabWrapsAroundFromLastToFirst() {
        let v = TabVisibility()
        // .settings is the last entry in Tab.sidebarOrder
        let result = nextVisibleTab(from: .settings, in: v)
        XCTAssertEqual(result, .overview)
    }

    func testNextTabSkipsHiddenTab() {
        var v = TabVisibility()
        v.toggle(.fleet)
        // Starting from .overview the next visible should skip .fleet → .devices
        let result = nextVisibleTab(from: .overview, in: v)
        XCTAssertEqual(result, .devices)
    }

    func testNextTabSkipsHiddenTabAtBoundary() {
        // .settings is core (cannot be hidden), so use .backups (non-core, second-to-last).
        // Hide .backups; from .sources (immediately before it), next should skip to .settings.
        var v = TabVisibility()
        v.toggle(.backups)
        let result = nextVisibleTab(from: .sources, in: v)
        XCTAssertEqual(result, .settings)
    }

    func testNextTabIsNonNilBecauseCoreTabsAlwaysRemainVisible() {
        // nil is unreachable in practice: Tab.sidebarOrder includes .overview
        // (core, cannot be hidden) so the ordered-visible list is never empty.
        let v = TabVisibility()
        XCTAssertNotNil(nextVisibleTab(from: .overview, in: v))
    }

    func testNextTabCurrentNotInSidebarOrderReturnsFirstVisible() {
        // .onboarding is a core tab that is NOT in Tab.sidebarOrder.
        let v = TabVisibility()
        let result = nextVisibleTab(from: .onboarding, in: v)
        XCTAssertEqual(result, Tab.sidebarOrder.first)
    }

    // MARK: - previousVisibleTab

    func testPrevTabMovesBackwardInSidebarOrder() {
        let v = TabVisibility()
        // .fleet is index 1; prev should be .overview (index 0)
        let result = previousVisibleTab(from: .fleet, in: v)
        XCTAssertEqual(result, .overview)
    }

    func testPrevTabWrapsAroundFromFirstToLast() {
        let v = TabVisibility()
        // .overview is first; wrapping backward lands on the last entry (.settings)
        let result = previousVisibleTab(from: .overview, in: v)
        XCTAssertEqual(result, Tab.sidebarOrder.last)
    }

    func testPrevTabSkipsHiddenTab() {
        var v = TabVisibility()
        v.toggle(.fleet)
        // Backward from .devices, .fleet is hidden → should land on .overview
        let result = previousVisibleTab(from: .devices, in: v)
        XCTAssertEqual(result, .overview)
    }

    func testPrevTabSkipsHiddenTabAtBoundary() {
        var v = TabVisibility()
        // Hide .fleet (index 1). Backward from .devices (index 2) skips it → .overview.
        v.toggle(.fleet)
        let result = previousVisibleTab(from: .devices, in: v)
        XCTAssertEqual(result, .overview)
    }

    func testPrevTabCurrentNotInSidebarOrderReturnsFirstVisible() {
        let v = TabVisibility()
        let result = previousVisibleTab(from: .onboarding, in: v)
        XCTAssertEqual(result, Tab.sidebarOrder.first)
    }

    // MARK: - profileAt

    func testProfileAtZeroReturnsFirstProfile() {
        let profiles = makeProfiles(["alpha", "beta", "gamma"])
        XCTAssertEqual(profileAt(index: 0, in: profiles)?.name, "alpha")
    }

    func testProfileAtLastValidIndexReturnsLastProfile() {
        let profiles = makeProfiles(["alpha", "beta", "gamma"])
        XCTAssertEqual(profileAt(index: 2, in: profiles)?.name, "gamma")
    }

    func testProfileAtOutOfRangeReturnsNil() {
        let profiles = makeProfiles(["alpha", "beta", "gamma"])
        // Cmd-4 with 3 profiles → no-op
        XCTAssertNil(profileAt(index: 3, in: profiles))
        XCTAssertNil(profileAt(index: 9, in: profiles))
    }

    func testProfileAtNegativeIndexReturnsNil() {
        let profiles = makeProfiles(["alpha"])
        XCTAssertNil(profileAt(index: -1, in: profiles))
    }

    func testProfileAtOnEmptyListReturnsNil() {
        XCTAssertNil(profileAt(index: 0, in: []))
    }

    func testCmdOneWithOneProfileReturnsFirstProfile() {
        // Cmd-1 always maps to index 0
        let profiles = makeProfiles(["solo"])
        XCTAssertEqual(profileAt(index: 0, in: profiles)?.name, "solo")
    }

    func testCmdFiveWithThreeProfilesReturnsNil() {
        let profiles = makeProfiles(["a", "b", "c"])
        XCTAssertNil(profileAt(index: 4, in: profiles))
    }

    // MARK: - sidebarOrder sanity

    func testSidebarOrderContainsNoDuplicates() {
        let order = Tab.sidebarOrder
        XCTAssertEqual(order.count, Set(order).count, "Tab.sidebarOrder must not contain duplicates")
    }

    func testSidebarOrderDoesNotContainOnboarding() {
        // .onboarding is core but not shown in the sidebar nav groups
        XCTAssertFalse(Tab.sidebarOrder.contains(.onboarding))
    }

    func testSidebarOrderContainsAllNonOnboardingCases() {
        let expected = Set(Tab.allCases).subtracting([.onboarding])
        let actual = Set(Tab.sidebarOrder)
        XCTAssertEqual(actual, expected,
            "sidebarOrder must list every Tab except .onboarding")
    }

    // MARK: - Helpers

    private func makeProfiles(_ names: [String]) -> [JamfCLIProfile] {
        names.map { JamfCLIProfile(name: $0, url: "", schedules: 0, status: .idle) }
    }
}
