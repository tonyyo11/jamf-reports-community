import Foundation

/// Tracks whether the user has seen the current app version's "What's New" banner.
/// Compares against `UserDefaults` so the banner shows exactly once per version upgrade.
@MainActor
struct AppVersionState {
    // Version string: pull from the bundle when available, fall back to a hard-coded constant
    // so tests (which have no app bundle) still compile and behave correctly.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "2.0.0"
    }

    private static let defaultsKey = "lastSeenAppVersion"

    private(set) static var lastSeenVersion: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// `true` when the user has not yet acknowledged the current version's "What's New" card.
    /// Returns `false` on a fresh install (`lastSeenVersion` is empty) so the post-onboarding
    /// prompt is shown instead.
    static var shouldShowWhatsNew: Bool {
        let last = lastSeenVersion
        return !last.isEmpty && last != currentVersion
    }

    /// Call once when the user dismisses the "What's New" banner.
    static func markCurrentVersionSeen() {
        lastSeenVersion = currentVersion
    }
}
