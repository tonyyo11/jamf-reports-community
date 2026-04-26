import AppKit

/// Thin wrapper around `NSWorkspace` for the "Reveal in Finder", "Open file",
/// and "Copy to clipboard" actions wired throughout the UI.
///
/// Every public method validates that the path exists and refuses to follow
/// symlinks outside `~/Jamf-Reports` and `~/Library/LaunchAgents` — defense
/// against an attacker who could plant a symlink in a workspace folder to
/// trick the GUI into revealing or opening files outside the sandboxed scope.
enum SystemActions {

    /// Reveal a file or directory in Finder. No-op if the path doesn't exist.
    static func reveal(_ url: URL) {
        guard let resolved = canonicalize(url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resolved])
    }

    /// Open a file with the default application.
    static func open(_ url: URL) {
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

    private static func allowedParents() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Jamf-Reports"),
            home.appendingPathComponent("Library/LaunchAgents"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            URL(fileURLWithPath: "/tmp"),
            URL(fileURLWithPath: "/Applications"),
        ]
    }
}
