import AppKit
import OSLog

/// Thin wrapper around `NSWorkspace` for the "Reveal in Finder", "Open file",
/// and "Copy to clipboard" actions wired throughout the UI.
///
/// Every public method validates that the path exists and refuses to follow
/// symlinks outside user data/report locations — defense against an attacker
/// who could plant a symlink in a workspace folder to trick the GUI into
/// revealing or opening files outside the sandboxed scope.
enum SystemActions {

    /// Reveal a file or directory in Finder. Returns `false` if the path is
    /// outside the allow-list or fails canonicalization; the rejection is also
    /// logged via `AppLogger.ui` so operators tailing console logs can spot it.
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        guard let resolved = canonicalize(url) else {
            AppLogger.ui.warning(
                "SystemActions.reveal: path not in allow-list: \(url.path, privacy: .private)"
            )
            notifyDenied(url, verb: "reveal")
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([resolved])
        return true
    }

    /// Surface a refused reveal/open so the click isn't silently swallowed.
    /// Posts on the main queue; `ContentView` turns it into a toast.
    private static func notifyDenied(_ url: URL, verb: String) {
        let message = "Can't \(verb) \"\(url.lastPathComponent)\" — it's outside the app's "
            + "allowed folders (~/Jamf-Reports, LaunchAgents, Logs)."
        NotificationCenter.default.post(
            name: .systemActionDenied, object: nil, userInfo: ["message": message])
    }

    /// Returns true when `url` should be opened directly via `NSWorkspace.open`
    /// without going through the file allow-list. Only `https` and `http` qualify;
    /// the caller also requires a non-empty host before actually opening.
    ///
    /// Extracted as a pure helper so tests can assert scheme-acceptance decisions
    /// without triggering real browser launches.
    static func isBrowserOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Open a file with the default application or a URL in the default browser.
    static func open(_ url: URL) {
        if isBrowserOpenable(url) {
            // Reject non-http(s) schemes disguised as URL components (javascript:, data:, file:).
            guard let host = url.host, !host.isEmpty else {
                notifyDenied(url, verb: "open")
                return
            }
            NSWorkspace.shared.open(url)
            return
        }
        guard let resolved = canonicalize(url) else {
            notifyDenied(url, verb: "open")
            return
        }
        NSWorkspace.shared.open(resolved)
    }

    /// Open a directory in Finder.
    static func openFolder(_ url: URL) {
        guard let resolved = canonicalize(url),
              FileManager.default.fileExists(atPath: resolved.path) else {
            notifyDenied(url, verb: "open")
            return
        }
        NSWorkspace.shared.open(resolved)
    }

    /// Returns true when `url` is within the allow-list used by `reveal` and
    /// `open`. Delegates to `canonicalize` so QuickLook preview and the
    /// reveal/open paths enforce an identical boundary.
    static func isURLAllowed(_ url: URL) -> Bool {
        canonicalize(url) != nil
    }

    /// Copy a string to the general pasteboard.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Resolve `~`, follow symlinks, and confirm the final path lives inside
    /// one of the allowed parents. Returns nil otherwise.
    ///
    /// Both the candidate and each parent are fully resolved before comparison
    /// so an allowed parent that is itself a symlink (e.g. `~/Jamf-Reports` on
    /// an external-drive workspace) does not cause false rejections.
    private static func canonicalize(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolved.path
        for parent in allowedParents() {
            let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedPath == parentPath || resolvedPath.hasPrefix(parentPath + "/") {
                return resolved
            }
        }
        return nil
    }

    /// B-04: narrowed to Jamf-owned data only.
    /// - Removed `/tmp` (TOCTOU/symlink-prone, shared across users on macOS;
    ///   canonicalize() resolves /tmp → /private/tmp anyway, leaving the
    ///   allow-list dead).
    /// - Removed `~/Documents` and `~/Downloads`: the audit found these too
    ///   broad to claim "bounded to Jamf data".
    ///
    /// B-04 follow-up (2026-06-01): the secondary `userExportTargetIsAllowed`
    /// path-prefix gate for NSSavePanel exports was removed. The save panel
    /// itself is stronger per-action consent than any prefix check, and the
    /// gate rejected legitimate destinations (network shares, iCloud Drive) —
    /// silently, in AuditView's case. This reveal/open allow-list remains the
    /// boundary for all programmatic (non-panel) actions.
    ///
    /// 2.7.0: the workspace entry follows `ProfileService.workspacesRoot()`
    /// rather than hardcoding `~/Jamf-Reports`. An operator who repoints the
    /// root at a synced team folder would otherwise find every Reveal-in-Finder
    /// and Open-report action silently refused, because the allow-list still
    /// described the old location. The default root stays listed too, so
    /// reports left behind by an earlier layout remain reachable.
    private static func allowedParents() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var parents = [
            ProfileService.workspacesRoot(),
            home.appendingPathComponent("Library/LaunchAgents"),
            home.appendingPathComponent("Library/Logs/JamfReports"),
        ]
        let fallback = WorkspaceRootStore.defaultRoot
        if !parents.contains(where: { sameResolvedPath($0, fallback) }) {
            parents.append(fallback)
        }
        return parents
    }

    private static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
