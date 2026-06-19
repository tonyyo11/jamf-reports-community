import Foundation

/// Tightens permissions on workspace artifacts so device data is owner-only readable.
///
/// The Python CLI writes generated reports, charts, and `jamf-cli-data/*.json`
/// snapshots with the process default umask, which on most macOS systems leaves
/// files as 0644 (world-readable). That exposes device serials, usernames, AD
/// emails, and compliance findings to any local user, every unsandboxed app,
/// the Spotlight indexer, and Time Machine metadata. This helper walks the
/// workspace after each successful CLI invocation and forces 0600 on every
/// regular file plus 0700 on every directory.
///
/// Companion to `OnboardingFlow.createWorkspace`'s `.metadata_never_index` drop
/// — that file kills new indexing; this helper closes the local-read gap.
///
/// Contract: this is **explicit invocation only**. Files newly created via
/// `Data.write(to:)`, `FileHandle.write(_:)`, or `FileManager.createFile(...)`
/// after a sweep are NOT re-secured automatically — call `tighten` again after
/// any new write. Wave 1 + Wave 2 wire `tighten` into every CLIBridge writer's
/// success branch; new write paths must follow the same convention or use the
/// per-file `chmod` helper inline.
///
/// Security audit refs: C-01 (reports world-readable), C-03 (regression in
/// permission mode across writers), C-04 (jamf-cli-data dirs at 0755).
@MainActor
enum WorkspacePermissionHardener {

    private static let fileMode: NSNumber = NSNumber(value: Int16(0o600))
    private static let dirMode:  NSNumber = NSNumber(value: Int16(0o700))

    /// Walk `<profile>` and tighten file/dir permissions in-place.
    ///
    /// Best-effort: per-entry failures are logged but do not abort the sweep.
    /// Symlinks are not followed — we set permissions on the link target only
    /// when the target lives inside the workspace.
    @discardableResult
    static func tighten(profile: String) -> SweepResult {
        guard ProfileService.isValid(profile) else {
            return SweepResult(touched: 0, failed: 0, enumerated: false)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return SweepResult(touched: 0, failed: 0, enumerated: false)
        }
        // C-13 defense-in-depth: when invoked via the profile entry point, the
        // resolved workspace must remain a child of the workspaces root.
        // Prevents a planted directory symlink at `<workspacesRoot>/<profile>`
        // from causing the sweep to chmod a tree outside the sandbox.
        let resolved = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let workspacesRoot = ProfileService.workspacesRoot()
            .resolvingSymlinksInPath().standardizedFileURL.path
        if resolved != workspacesRoot,
           !resolved.hasPrefix(workspacesRoot + "/") {
            AppLogger.collect.error(
                "WorkspacePermissionHardener: refusing sweep — profile=\(profile, privacy: .public) resolves outside workspaces root"
            )
            return SweepResult(touched: 0, failed: 0, enumerated: false)
        }
        // C-07/MFS-4: emit a unified-log entry so forensics can confirm the
        // sweep ran on a given profile + timestamp. Profile name is %{public}
        // because the slug is also visible in LaunchAgent labels and is not
        // itself a secret.
        AppLogger.collect.info(
            "WorkspacePermissionHardener.tighten profile=\(profile, privacy: .public)"
        )
        return tighten(directory: workspace)
    }

    /// Sweep an arbitrary directory tree (escape-hatch for tests + onboarding
    /// backfill). The caller is responsible for verifying the directory belongs
    /// to a trusted workspace before calling this.
    /// Sweep result so callers and forensic logs can confirm the sweep actually
    /// did work, not just that it returned without throwing. Per the silent-
    /// failure audit (post Wave 1+2): a sweep that touches zero files when the
    /// workspace is non-empty is itself a signal worth surfacing.
    @discardableResult
    static func tighten(directory root: URL) -> SweepResult {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            // Workspace deleted, unreadable, or otherwise un-enumerable. Surface
            // this loudly: a CLI run that completes "successfully" without a
            // matching tighten leaves files at 0644.
            AppLogger.collect.error(
                "WorkspacePermissionHardener: cannot enumerate \(root.lastPathComponent, privacy: .public) — sweep skipped"
            )
            return SweepResult(touched: 0, failed: 0, enumerated: false)
        }

        var touched = 0
        var failed = 0
        for case let url as URL in walker {
            let vals = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
            ])
            // Skip symlinks — chmod on a symlink modifies its target, which may
            // legitimately escape the workspace and we don't want to touch it.
            if vals?.isSymbolicLink == true { continue }

            let mode: NSNumber
            if vals?.isRegularFile == true {
                mode = fileMode
            } else if vals?.isDirectory == true {
                mode = dirMode
            } else {
                continue
            }

            do {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                touched += 1
            } catch {
                failed += 1
                let name = url.lastPathComponent
                AppLogger.collect.warning(
                    "WorkspacePermissionHardener: chmod failed on \(name): \(error.localizedDescription)"
                )
            }
        }
        return SweepResult(touched: touched, failed: failed, enumerated: true)
    }

    struct SweepResult: Sendable, Equatable {
        let touched: Int
        let failed: Int
        let enumerated: Bool
    }
}
