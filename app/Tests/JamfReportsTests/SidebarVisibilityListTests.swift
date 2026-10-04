import XCTest
@testable import JamfReports

final class SidebarVisibilityListTests: XCTestCase {

    private var listed: [Tab] { SettingsView.toggleableGroups.flatMap(\.tabs) }

    /// Every tab the user may hide has a switch, once, and no tab that cannot be hidden does.
    func testEveryHideableTabHasExactlyOneSwitch() {
        let hideable = Tab.allCases.filter { !$0.isCoreTab }
        XCTAssertEqual(Set(listed), Set(hideable))
        XCTAssertEqual(listed.count, hideable.count, "no tab listed twice")
        XCTAssertTrue(listed.allSatisfy { !$0.isCoreTab })
    }

    func testGroupsAndSearchesCanBeHidden() {
        XCTAssertTrue(listed.contains(.groupInventory))
        var visibility = TabVisibility()
        visibility.toggle(.groupInventory)
        XCTAssertFalse(visibility.isVisible(.groupInventory))
        XCTAssertTrue(TabVisibility.parse(visibility.serialize()).isVisible(.protectDashboard))
    }

    func testTheGroupsAreTheSidebarsInTheSidebarsOrder() {
        let sidebar = Tab.navGroups.map(\.label)
        let shown = SettingsView.toggleableGroups.map(\.label)
        XCTAssertEqual(shown, sidebar.filter { shown.contains($0) })
        XCTAssertEqual(SettingsView.toggleableGroups.first { $0.label == "FLEET" }?.tabs,
                       [.mobileFleet, .protectDashboard, .groupInventory])
        XCTAssertFalse(shown.contains("SYSTEM"), "Settings is core, so its group is empty")
    }
}
