import Foundation

/// Resolves the running app's user-facing version string.
@MainActor
struct AppVersionState {
    /// Compile-time fallback semver, used when there is no app bundle (tests,
    /// `swift run`). MUST equal `MARKETING_VERSION` in `build-app.sh` — a test
    /// (`AppVersionDriftTests`) enforces this so a half-finished version bump
    /// fails CI instead of shipping a stale fallback.
    static let fallbackVersion = "2.5.0"

    // Version string: pull from the bundle when available, fall back to the
    // compile-time constant so tests (which have no app bundle) still behave.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion
    }
}
