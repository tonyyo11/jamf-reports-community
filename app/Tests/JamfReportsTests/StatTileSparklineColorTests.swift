import XCTest
import SwiftUI
@testable import JamfReports

/// Locks the wave-1 design-review refactor of StatTile.sparkColor (commit
/// a3d171d). The sentinel `sparkColor != Theme.Colors.gold` pattern was
/// replaced with `Color?`; this suite pins the resulting branch table so a
/// future refactor that inverts a case or drops the explicit-override path
/// fails loudly.
final class StatTileSparklineColorTests: XCTestCase {

    // MARK: - deltaTrend resolution (override = nil)

    func testUpTrendUsesOkColor() {
        XCTAssertEqual(
            StatTile.sparklineColor(override: nil, trend: .up),
            Theme.Colors.ok
        )
    }

    func testDownTrendUsesDangerColor() {
        XCTAssertEqual(
            StatTile.sparklineColor(override: nil, trend: .down),
            Theme.Colors.danger
        )
    }

    func testFlatTrendUsesGoldColor() {
        // Gemini 2026-05-14 cross-review MUST-FIX: explicit coverage on
        // .flat to prevent a "neutral trends show wrong color" regression.
        XCTAssertEqual(
            StatTile.sparklineColor(override: nil, trend: .flat),
            Theme.Colors.gold
        )
    }

    // MARK: - Explicit override beats deltaTrend

    func testExplicitOverrideWinsOverUpTrend() {
        XCTAssertEqual(
            StatTile.sparklineColor(override: Theme.Colors.tealBright, trend: .up),
            Theme.Colors.tealBright
        )
    }

    func testExplicitOverrideWinsOverFlatTrend() {
        // The wave-1 refactor's whole point: passing gold explicitly used to
        // collide with the gold sentinel. Now it works as an override.
        XCTAssertEqual(
            StatTile.sparklineColor(override: Theme.Colors.gold, trend: .flat),
            Theme.Colors.gold
        )
        XCTAssertEqual(
            StatTile.sparklineColor(override: Theme.Colors.danger, trend: .flat),
            Theme.Colors.danger
        )
    }
}
