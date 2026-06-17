import TipKit

/// Central TipKit setup for the app's onboarding/guidance tips.
///
/// TipKit identifies a tip by its conforming type and persists each tip's
/// shown/dismissed state in a datastore. We configure that datastore once at
/// launch; the per-surface tip definitions live alongside this file (see
/// `ConfigTips`, `SourcesTips`, `OnboardingTips`, `WalkthroughTips`) and are
/// attached to controls via `.popoverTip(_:)` or rendered inline with
/// `TipView(_:)`.
enum AppTips {
    /// Configure the shared tip datastore. Call once, before any tip renders.
    ///
    /// Invoked from `JamfReportsApp.init()` so it only runs on the SwiftUI
    /// launch path — the headless `--scheduled-run` / `--check` CLI paths never
    /// build the scene and never need TipKit.
    ///
    /// `.immediate` shows a tip as soon as its anchor appears and the tip is
    /// eligible; each tip carries its own `options` to keep it from re-nagging.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Clear the shown/dismissed state for every tip so they appear again.
    ///
    /// Wired to Settings → Diagnostics → "Restore in-app tips" for users who
    /// dismissed the guidance and want it back (and for QA re-walkthroughs).
    /// Returns `true` when the datastore was reset.
    @discardableResult
    static func resetAll() -> Bool {
        do {
            try Tips.resetDatastore()
            return true
        } catch {
            return false
        }
    }
}
