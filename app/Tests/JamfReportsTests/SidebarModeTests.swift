import XCTest
@testable import JamfReports

@MainActor
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

    /// The third press while narrow lands on a visible expanded sidebar, which cycling from the
    /// stored mode would skip.
    func testCyclingWhileNarrowReachesExpanded() {
        var state = (stored: SidebarMode.expanded, overridden: false)
        var shown: [SidebarMode] = []
        for _ in 0..<3 {
            state = SidebarMode.cycled(stored: state.stored, isNarrow: true,
                                       overridden: state.overridden)
            shown.append(SidebarMode.effective(stored: state.stored, isNarrow: true,
                                               overridden: state.overridden))
        }
        XCTAssertEqual(shown, [.hidden, .expanded, .compact])
    }

    func testCyclingWhileWideCyclesStoredModeWithoutOverride() {
        let result = SidebarMode.cycled(stored: .expanded, isNarrow: false, overridden: false)
        XCTAssertEqual(result.stored, .compact)
        XCTAssertFalse(result.overridden)
    }

    /// At or below the minimum window the rule could never apply.
    func testThresholdIsAboveMinimumWindowWidth() {
        XCTAssertGreaterThan(Theme.Metrics.sidebarAutoCompactBelow,
                             JamfReportsApp.minSupportedWidth)
    }
}
