import Foundation

/// Installs a `jamf-reports` symlink into a PATH directory pointing at this
/// app's in-bundle executable, so the GUI binary doubles as the included CLI
/// (the `code`/`subl` pattern). When invoked as `jamf-reports <subcommand>`,
/// `App/main.swift` routes to the CLI before any GUI init.
///
/// No privilege escalation: the app only writes the symlink itself when the
/// target directory is already writable. Otherwise it returns the exact
/// `sudo` command for the user to run — the app never invokes `sudo` or an
/// admin AppleScript.
enum CLIInstaller {
    static let linkName = "jamf-reports"

    /// On the default PATH (`/etc/paths`) for every macOS install. Apple-silicon
    /// Macs often lack it by default, so the manual command `mkdir -p`s it first.
    static let defaultTargetDir = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    enum Outcome: Equatable {
        case installed(path: String)
        case alreadyInstalled(path: String)
        /// Target dir not writable — run this command (includes `sudo`) yourself.
        case manual(command: String)
        case failed(reason: String)
    }

    /// The binary the symlink points at: `.../JamfReports.app/Contents/MacOS/JamfReports`
    /// in a bundle, or the built executable in dev. Symlinks resolved so the link
    /// target is stable.
    static func sourceBinary() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    /// Create (or verify) the symlink. `source`/`targetDir`/`fileManager` are
    /// injectable for tests; production calls use the defaults.
    static func install(
        source: URL? = sourceBinary(),
        targetDir: URL = defaultTargetDir,
        fileManager fm: FileManager = .default
    ) -> Outcome {
        guard let source = source?.resolvingSymlinksInPath() else {
            return .failed(reason: "could not locate the app executable")
        }
        let dest = targetDir.appendingPathComponent(linkName)
        let manual =
            "sudo mkdir -p \"\(targetDir.path)\" && sudo ln -sf \"\(source.path)\" \"\(dest.path)\""

        // Inspect what's already at the destination before touching it.
        if let existing = try? fm.destinationOfSymbolicLink(atPath: dest.path) {
            let resolved = URL(fileURLWithPath: existing, relativeTo: targetDir).resolvingSymlinksInPath()
            if resolved.path == source.path { return .alreadyInstalled(path: dest.path) }
            // A stale symlink (ours or another tool's) — safe to replace below.
        } else if fm.fileExists(atPath: dest.path) {
            // A real file/dir we didn't create — never clobber it.
            return .failed(reason: "\(dest.path) exists and is not a symlink — remove it, then retry")
        }

        var isDir: ObjCBool = false
        let dirWritable = fm.fileExists(atPath: targetDir.path, isDirectory: &isDir)
            && isDir.boolValue && fm.isWritableFile(atPath: targetDir.path)
        guard dirWritable else { return .manual(command: manual) }

        do {
            if (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil {
                try fm.removeItem(at: dest)  // stale symlink only — real files handled above
            }
            try fm.createSymbolicLink(at: dest, withDestinationURL: source)
            return .installed(path: dest.path)
        } catch {
            return .manual(command: manual)
        }
    }
}
