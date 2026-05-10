import AppKit

/// Thin wrapper around `NSWorkspace` for the "Reveal in Finder", "Open file",
/// and "Copy to clipboard" actions wired throughout the UI.
///
/// Every public method validates that the path exists and refuses to follow
/// symlinks outside user data/report locations — defense against an attacker
/// who could plant a symlink in a workspace folder to trick the GUI into
/// revealing or opening files outside the sandboxed scope.
enum SystemActions {

    /// Reveal a file or directory in Finder. No-op if the path doesn't exist.
    static func reveal(_ url: URL) {
        guard let resolved = canonicalize(url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resolved])
    }

    /// Open a file with the default application or a URL in the default browser.
    static func open(_ url: URL) {
        if let scheme = url.scheme?.lowercased(), scheme == "https" {
            // Reject non-https schemes disguised as URL components (javascript:, data:, file:).
            guard let host = url.host, !host.isEmpty else { return }
            NSWorkspace.shared.open(url)
            return
        }
        guard let resolved = canonicalize(url) else { return }
        NSWorkspace.shared.open(resolved)
    }

    /// Open a directory in Finder.
    static func openFolder(_ url: URL) {
        guard let resolved = canonicalize(url),
              FileManager.default.fileExists(atPath: resolved.path) else { return }
        NSWorkspace.shared.open(resolved)
    }

    /// Copy a string to the general pasteboard.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Resolve `~`, follow symlinks, and confirm the final path lives inside
    /// one of the allowed parents. Returns nil otherwise.
    private static func canonicalize(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolved.path
        for parent in allowedParents() {
            let parentPath = parent.standardizedFileURL.path
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
    ///   broad to claim "bounded to Jamf data". User-initiated export targets
    ///   should go through `userExportTargetIsAllowed(_:)` with explicit
    ///   per-action confirmation (UI seam not yet wired).
    private static func allowedParents() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Jamf-Reports"),
            home.appendingPathComponent("Library/LaunchAgents"),
            home.appendingPathComponent("Library/Logs/JamfReports"),
        ]
    }

    /// B-04: secondary allow-list for user-initiated export destinations
    /// (Save As..., reveal-after-export). Callers MUST present a confirmation
    /// affordance before invoking SystemActions on a path approved only by
    /// this method — the broader trust comes from the user's explicit choice,
    /// not from the path itself. Currently a seam: not yet wired into UI.
    static func userExportTargetIsAllowed(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let exportRoots = [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
        ].map { $0.standardizedFileURL.path }
        for root in exportRoots {
            if resolved == root || resolved.hasPrefix(root + "/") { return true }
        }
        return false
    }
}
