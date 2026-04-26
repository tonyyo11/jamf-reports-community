import Foundation

/// Profile name validation and discovery.
///
/// A "profile" is a `jamf-cli` profile id that doubles as a workspace folder
/// name under `~/Jamf-Reports/<profile>/`. We never expose API client secrets
/// — those live in `jamf-cli`'s keychain. The GUI only ever sees the profile
/// id, the URL, and the on-disk workspace folder.
enum ProfileService {

    /// `^[a-z0-9][a-z0-9._-]*$` — the regex from the design handoff. Profile
    /// names are used in path construction (`~/Jamf-Reports/<name>/`) and
    /// LaunchAgent labels (`com.tonyyo.jrc.<name>.…`); a permissive pattern
    /// would let attackers slip in path traversal or arbitrary plist labels.
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Workspace root, always inside the user's home dir.
    static func workspacesRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports")
    }

    /// Path to a specific workspace. Returns nil for invalid names.
    static func workspaceURL(for profile: String) -> URL? {
        guard isValid(profile) else { return nil }
        return workspacesRoot().appendingPathComponent(profile, isDirectory: true)
    }

    /// Discover real workspaces by listing immediate subdirectories of
    /// `~/Jamf-Reports/` that contain a `config.yaml`. Returns sorted by name.
    /// In demo mode, the caller falls back to `DemoData.cliProfiles`.
    static func discoverLocal() -> [JamfCLIProfile] {
        let root = workspacesRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .filter(isValid)
            .filter { name in
                let cfg = root.appendingPathComponent(name).appendingPathComponent("config.yaml")
                return FileManager.default.fileExists(atPath: cfg.path)
            }
            .sorted()
            .map { name in
                JamfCLIProfile(
                    name: name,
                    url: "(local workspace)",
                    schedules: 0,
                    status: .idle
                )
            }
    }
}
