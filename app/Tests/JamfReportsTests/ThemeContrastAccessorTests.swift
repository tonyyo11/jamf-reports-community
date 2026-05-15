import XCTest
import SwiftUI
@testable import JamfReports

/// Locks the Phase 5.1 contrast-aware accessor contract: every helper must
/// return the *stronger* token under `.increased` and the standard token
/// otherwise. A regression that inverts a ternary would silently undo the
/// system-Increase-Contrast support without breaking any pixel-diff test.
final class ThemeContrastAccessorTests: XCTestCase {

    func testTextTertiary() {
        XCTAssertEqual(Theme.Text.tertiary(.standard),  Theme.Colors.fgMuted)
        XCTAssertEqual(Theme.Text.tertiary(.increased), Theme.Colors.fg2)
    }

    func testTextDisabled() {
        XCTAssertEqual(Theme.Text.disabled(.standard),  Theme.Colors.fgDisabled)
        XCTAssertEqual(Theme.Text.disabled(.increased), Theme.Colors.fgMuted)
    }

    func testHairlineStandard() {
        XCTAssertEqual(Theme.Hairline.standard(.standard),  Theme.Colors.hairline)
        XCTAssertEqual(Theme.Hairline.standard(.increased), Theme.Colors.hairlineStrong)
    }

    func testSurfaceHigh() {
        XCTAssertEqual(Theme.Surface.high(.standard),  Color.white.opacity(0.08))
        XCTAssertEqual(Theme.Surface.high(.increased), Color.white.opacity(0.14))
    }

    func testSurfaceInteractive() {
        XCTAssertEqual(Theme.Surface.interactive(.standard),  Color.white.opacity(0.12))
        XCTAssertEqual(Theme.Surface.interactive(.increased), Color.white.opacity(0.20))
    }

    func testSurfaceInput() {
        XCTAssertEqual(Theme.Surface.input(.standard),  Color.white.opacity(0.05))
        XCTAssertEqual(Theme.Surface.input(.increased), Color.white.opacity(0.10))
    }
}
