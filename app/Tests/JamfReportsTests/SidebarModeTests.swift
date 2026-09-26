import XCTest
@testable import JamfReports

final class SidebarModeTests: XCTestCase {

    func testExpandedShowsCompactWhenNarrow() {
        XCTAssertEqual(SidebarMode.effective(stored: .expanded, isNarrow: true, overridden: false),
                       .compact)
    }

    func testOverrideKeepsExpandedWhenNarrow() {
        XCTAssertEqual(SidebarMode.effective(stored: .expanded, isNarrow: true, overridden: true),
                       .expanded)
    }

    func testWideWindowShowsStoredMode() {
        for mode in SidebarMode.allCases {
            XCTAssertEqual(SidebarMode.effective(stored: mode, isNarrow: false, overridden: false),
                           mode)
        }
    }

    func testCompactAndHiddenAreNeverChangedByWidth() {
        for mode in [SidebarMode.compact, .hidden] {
            for overridden in [false, true] {
                XCTAssertEqual(
                    SidebarMode.effective(stored: mode, isNarrow: true, overridden: overridden),
                    mode)
            }
        }
    }

    /// Mirrors ContentView.cycleSidebar: cycling from the mode on screen while narrow sets the
    /// override, so the third press lands on a visible expanded sidebar.
    func testCyclingWhileNarrowReachesExpanded() {
        var stored = SidebarMode.expanded
        var overridden = false
        var shown: [SidebarMode] = []
        for _ in 0..<3 {
            let current = SidebarMode.effective(stored: stored, isNarrow: true,
                                                overridden: overridden)
            overridden = true
            stored = current.next()
            shown.append(SidebarMode.effective(stored: stored, isNarrow: true,
                                               overridden: overridden))
        }
        XCTAssertEqual(shown, [.hidden, .expanded, .compact])
    }

    /// At or below the minimum window the rule could never apply.
    func testThresholdIsAboveMinimumWindowWidth() {
        XCTAssertGreaterThan(Theme.Metrics.sidebarAutoCompactBelow,
                             JamfReportsApp.minSupportedWidth)
    }
}
