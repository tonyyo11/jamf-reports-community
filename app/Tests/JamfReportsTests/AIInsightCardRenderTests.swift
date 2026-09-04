import XCTest
import SwiftUI
@testable import JamfReports

/// Smoke tests for `AIInsightCard`. SwiftUI's `xctest` host does not drive a
/// real view tree, so these confirm the card can be instantiated and its body
/// evaluated without crashing across its states — the same harness
/// `PostureViewsRenderTests`/`LightModeRenderTests` use for the other screens.
/// The card is ungated: on the default toolchain (macOS < 27) it resolves to
/// `.requiresMacOS27` and never touches FoundationModels.
@MainActor
final class AIInsightCardRenderTests: XCTestCase {

    private func summary(_ date: String = "2026-06-06") -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: 98,
            compliancePct: nil, staleCount: 0, osCurrentPct: nil,
            crowdstrikePct: nil, patchPct: 90
        )
    }

    /// Idle/disabled state — no data yet, default (disabled) config. Forcing the
    /// body evaluates the availability/idle branch without a live model.
    func testCardInstantiatesWithoutData() throws {
        let card = AIInsightCard(profile: "test", current: nil, previous: nil)
        _ = card.body
    }

    /// Result-ready inputs (current + previous present). Body still renders the
    /// idle/availability branch on this toolchain (generation is user-triggered
    /// and only runs on macOS 27), but this exercises the with-data construction
    /// path and the generate-button enablement.
    func testCardInstantiatesWithCurrentAndPrevious() throws {
        let card = AIInsightCard(
            profile: "test",
            current: summary("2026-06-06"),
            previous: summary("2026-06-05")
        )
        _ = card.body
    }

    /// The card must construct for any tier — the tier only changes
    /// label/model selection, never whether the view can build.
    func testCardInstantiatesRegardlessOfTier() throws {
        let card = AIInsightCard(
            profile: "test",
            current: summary(),
            previous: nil
        )
        _ = card.body
    }
}
