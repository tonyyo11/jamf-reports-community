import Foundation

/// One-shot migrations applied at app launch.
///
/// MFS-2 (security audit C-02): existing workspaces created before
/// `.metadata_never_index` was added by `OnboardingFlow` may already be
/// Spotlight-indexed (the Track C audit observed 5,474 indexed items under
/// `~/Jamf-Reports`). Wave 1 closed the going-forward gap by dropping the
/// marker on workspace creation; this migration backfills:
///
/// 1. Drops `.metadata_never_index` into every existing profile workspace
///    that doesn't already have one.
/// 2. Calls `mdutil -i off <path>` per workspace (best-effort; logs but does
///    not fail on non-zero exit — the marker file alone is sufficient for
///    `mdimport` to skip future indexing of those trees).
/// 3. Triggers `WorkspacePermissionHardener.tighten(profile:)` on each
///    workspace to backfill 0644 artifacts created by older app builds or
///    by CLI runs that bypassed Wave 1 hooks.
///
/// The migration is idempotent — it gates on a per-version `UserDefaults`
/// sentinel (`JRC_SpotlightPurge_DoneForVersion`) and short-circuits when
/// the sentinel matches the current `CFBundleShortVersionString`. New
/// profiles created after the migration runs are still picked up by the
/// going-forward hooks in `OnboardingFlow.createWorkspace`.
@MainActor
enum WorkspaceMigration {

    /// `UserDefaults` key — value is the app version string the migration last completed under.
    static let sentinelKey = "JRC_SpotlightPurge_DoneForVersion"

    /// Run the one-shot Spotlight + permissions backfill for the current app version.
    ///
    /// Idempotent: re-running for the same version is a no-op for already-processed
    /// profiles (the marker file is skipped if present, the hardener walk converges to
    /// owner-only on second run, and `mdutil -i off` is itself idempotent). Newly added
    /// profiles between runs *will* be processed because the migration walks the
    /// workspace root each invocation.
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        version: String = currentAppVersion()
    ) -> Bool {
        if defaults.string(forKey: sentinelKey) == version {
            return false
        }
        let result = run(defaults: defaults)
        // SF-5: only stamp the sentinel when every profile reported success.
        // Otherwise leave it unset so the next launch retries.
        if result.allSucceeded {
            defaults.set(version, forKey: sentinelKey)
        } else {
            let failed = result.failedProfiles.joined(separator: ", ")
            AppLogger.collect.error(
                "WorkspaceMigration: sentinel NOT stamped — failures: \(failed, privacy: .public)"
            )
        }
        return true
    }

    /// Per-profile migration outcome — `succeeded` is the AND of marker drop,
    /// Spotlight disable, and the permission sweep for the profile.
    struct ProfileResult: Sendable, Equatable {
        let profile: String
        let succeeded: Bool
    }

    /// Aggregate of every profile processed in a `run`. Callers (notably
    /// `runIfNeeded`) gate the per-version sentinel on `allSucceeded`.
    struct RunResult: Sendable, Equatable {
        let profiles: [ProfileResult]

        var allSucceeded: Bool { profiles.allSatisfy { $0.succeeded } }
        var failedProfiles: [String] { profiles.filter { !$0.succeeded }.map { $0.profile } }
    }

    /// Force a run, ignoring the sentinel. Exposed for tests; production callers
    /// should use `runIfNeeded` so we don't walk the workspace on every launch.
    @discardableResult
    static func run(defaults: UserDefaults = .standard) -> RunResult {
        let root = ProfileService.workspacesRoot()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            AppLogger.collect.info("WorkspaceMigration: workspaces root absent — skipping")
            return RunResult(profiles: [])
        }
        let profiles = discoverProfiles(under: root)
        AppLogger.collect.info(
            "WorkspaceMigration: starting Spotlight + permissions backfill for \(profiles.count, privacy: .public) profile(s)"
        )

        var results: [ProfileResult] = []
        for profile in profiles {
            guard let workspace = ProfileService.workspaceURL(for: profile) else {
                results.append(ProfileResult(profile: profile, succeeded: false))
                continue
            }
            let marker = dropNeverIndexMarker(at: workspace)
            let spotlight = disableSpotlight(at: workspace)
            let sweep = WorkspacePermissionHardener.tighten(profile: profile)
            let succeeded = marker && spotlight && (sweep.enumerated && sweep.failed == 0)
            results.append(ProfileResult(profile: profile, succeeded: succeeded))
        }
        return RunResult(profiles: results)
    }

    /// Helper: app's `CFBundleShortVersionString`, falling back to a constant
    /// so unit tests (no host bundle) don't trip on a nil version.
    static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0-test"
    }

    // MARK: - Private

    /// Enumerate immediate subdirectories of the workspaces root whose names
    /// pass `ProfileService.isValid`. Mirrors `ProfileService.discoverLocal`'s
    /// disk-walk filter but skips the jamf-cli enrichment because we only need
    /// directory names here.
    private static func discoverProfiles(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        // C-13: skip symlinks so a planted directory symlink at the workspace
        // root (e.g. `~/Jamf-Reports/foo -> /Users/victim/Documents`) cannot
        // trick the hardener into chmodding the link target.
        // `URL.resourceValues(.isSymbolicLinkKey)` reports the link itself,
        // not the resolved target, which is exactly what we want.
        return entries
            .filter { url in
                let vals = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                if vals?.isSymbolicLink == true {
                    AppLogger.collect.warning(
                        "WorkspaceMigration: skipping symlink entry \(url.lastPathComponent, privacy: .public)"
                    )
                    return false
                }
                return vals?.isDirectory == true
            }
            .map { $0.lastPathComponent }
            .filter(ProfileService.isValid)
    }

    /// Returns true when the marker is present after the call (already-existed
    /// counts as success). Returns false only when a write was attempted and
    /// failed — that's the case where SF-5 must keep the sentinel unstamped.
    private static func dropNeverIndexMarker(at workspace: URL) -> Bool {
        let fm = FileManager.default
        let marker = workspace.appendingPathComponent(".metadata_never_index")
        if fm.fileExists(atPath: marker.path) { return true }
        do {
            try Data().write(to: marker, options: .atomic)
            try? fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: marker.path
            )
            AppLogger.collect.info(
                "WorkspaceMigration: dropped .metadata_never_index in \(workspace.lastPathComponent, privacy: .private)"
            )
            return true
        } catch {
            AppLogger.collect.warning(
                "WorkspaceMigration: failed to write .metadata_never_index: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    /// Returns true when Spotlight indexing was successfully toggled off (or
    /// when mdutil exited non-zero with the benign "already disabled" message,
    /// which the marker file still covers). Returns false only when the
    /// invocation itself failed.
    /// SF-6: log when `/usr/bin/mdutil` is missing so install-audit reports
    /// show why the marker file became the sole defense.
    private static func disableSpotlight(at workspace: URL) -> Bool {
        let mdutil = URL(fileURLWithPath: "/usr/bin/mdutil")
        guard FileManager.default.isExecutableFile(atPath: mdutil.path) else {
            AppLogger.collect.warning(
                "WorkspaceMigration: mdutil unavailable — relying on .metadata_never_index marker only"
            )
            // Marker alone is sufficient for `mdimport` to skip indexing, so we
            // treat this as a successful migration step rather than a failure.
            return true
        }
        let process = Process()
        process.executableURL = mdutil
        process.arguments = ["-i", "off", workspace.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // Common: a workspace that was never indexed returns non-zero with
                // "Indexing and searching disabled." — informational, not a failure.
                AppLogger.collect.info(
                    "WorkspaceMigration: mdutil -i off exited \(process.terminationStatus, privacy: .public) (best-effort)"
                )
            }
            return true
        } catch {
            AppLogger.collect.warning(
                "WorkspaceMigration: mdutil invocation failed: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }
}
