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
    /// Pass `profile` for a report: the folder its `output.output_dir` resolves to is allowed too.
    @discardableResult
    static func reveal(_ url: URL, profile: String? = nil) -> Bool {
        guard let resolved = canonicalize(url, profile: profile) else {
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
        notify(refusalMessage(.outsideAllowedFolders, url: url, verb: verb))
    }

    private static func notify(_ message: String) {
        NotificationCenter.default.post(
            name: .systemActionDenied, object: nil, userInfo: ["message": message])
    }

    /// Why a programmatic reveal/open was refused.
    enum Refusal: Equatable {
        case outsideAllowedFolders
        /// Inside the allow-list, but nothing is there yet — a workspace folder
        /// the app creates on first use, such as run logs before the first run.
        case missingFolder
    }

    /// The toast for a refused action. Pure, so tests can pin the wording.
    static func refusalMessage(_ refusal: Refusal, url: URL, verb: String) -> String {
        switch refusal {
        case .outsideAllowedFolders:
            return "Can't \(verb) \"\(url.lastPathComponent)\" — it's outside the app's "
                + "allowed folders (~/Jamf-Reports, LaunchAgents, Logs)."
        case .missingFolder:
            return "Can't \(verb) \"\(url.lastPathComponent)\" — the folder does not exist yet."
        }
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
    /// `profile` as for `reveal`.
    static func open(_ url: URL, profile: String? = nil) {
        if isBrowserOpenable(url) {
            // Reject non-http(s) schemes disguised as URL components (javascript:, data:, file:).
            guard let host = url.host, !host.isEmpty else {
                notifyDenied(url, verb: "open")
                return
            }
            NSWorkspace.shared.open(url)
            return
        }
        guard let resolved = canonicalize(url, profile: profile) else {
            notifyDenied(url, verb: "open")
            return
        }
        NSWorkspace.shared.open(resolved)
    }

    /// Open a directory in Finder. A missing folder inside the allow-list gets
    /// its own message: it used to read as "outside the allowed folders".
    /// `profile` as for `reveal`.
    static func openFolder(_ url: URL, profile: String? = nil) {
        guard let resolved = canonicalize(url, profile: profile) else {
            notifyDenied(url, verb: "open")
            return
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            notify(refusalMessage(.missingFolder, url: url, verb: "open"))
            return
        }
        NSWorkspace.shared.open(resolved)
    }

    /// Returns true when `url` is within the allow-list used by `reveal` and
    /// `open`. Delegates to `canonicalize` so QuickLook preview and the
    /// reveal/open paths enforce an identical boundary. `profile` as for `reveal`.
    static func isURLAllowed(_ url: URL, profile: String? = nil) -> Bool {
        canonicalize(url, profile: profile) != nil
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
    ///
    /// The profile's reports folder is read last, only for a path no fixed parent covers: it
    /// costs a config.yaml read, and `isURLAllowed` runs on every Quick Look refresh.
    private static func canonicalize(_ url: URL, profile: String?) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolved.path
        if allowedParents().contains(where: { contains($0, resolvedPath) }) { return resolved }
        if let profile, let reports = WorkspacePaths.readableReportsDir(for: profile),
           contains(reports, resolvedPath) {
            return resolved
        }
        return nil
    }

    private static func contains(_ parent: URL, _ resolvedPath: String) -> Bool {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedPath == parentPath || resolvedPath.hasPrefix(parentPath + "/")
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
    ///
    /// A report folder outside the workspace (`output.output_dir` with
    /// `output.allow_absolute_paths`) is not listed here: it belongs to one profile, so
    /// `canonicalize` adds it for the profile the caller names, and only once
    /// `WorkspacePaths.readableReportsDir` accepted it, which refuses system and
    /// credential folders.
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
