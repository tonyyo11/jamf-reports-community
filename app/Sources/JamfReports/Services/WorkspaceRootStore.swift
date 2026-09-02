import Foundation

/// Where `~/Jamf-Reports/` actually lives.
///
/// The default is the user's home directory, which is what every install used
/// before 2.7.0 and what a single-Mac operator should keep. A team that wants
/// several Macs reporting on the same tenants points this at a synced folder
/// (OneDrive/SharePoint, Box, Dropbox, or a mounted share) so history, raw
/// snapshots and reports accumulate in one place.
///
/// **This is per-machine on purpose.** A provider mounts the same team folder
/// under the signed-in user's home — `/Users/alice/Library/CloudStorage/...`
/// on one Mac and `/Users/bob/...` on the next — so the path is not shareable
/// and cannot live in the workspace's own `config.yaml`. Coordination *policy*
/// (lease length, collect interval) does live there, in `shared_workspace:`,
/// because every machine must agree on it. See `SharedWorkspace`.
enum WorkspaceRootStore {

    /// UserDefaults key holding the operator's chosen root. Absent = default.
    static let defaultsKey = "workspacesRootPath"

    /// Environment override consulted before UserDefaults. Set by the LaunchAgent
    /// plists the app writes, so a scheduled run never depends on the GUI's
    /// preferences being readable, and settable by hand for the included CLI
    /// (`JRC_WORKSPACES_ROOT=… jamf-reports check --profile prod`).
    static let environmentKey = "JRC_WORKSPACES_ROOT"

    enum Validation: Equatable {
        case ok
        /// Path is fine but does not exist yet; the caller may create it.
        case missing
        case notADirectory
        case notWritable
        case sensitiveLocation

        var isUsable: Bool { self == .ok || self == .missing }

        var message: String? {
            switch self {
            case .ok, .missing: return nil
            case .notADirectory: return "That path is a file, not a folder."
            case .notWritable: return "That folder is not writable by your account."
            case .sensitiveLocation:
                return "That location is reserved by macOS or holds credentials."
            }
        }
    }

    /// The active workspace root.
    ///
    /// Resolution order — first match wins:
    /// 1. `JRC_TEST_WORKSPACES_ROOT` (DEBUG only) so tests are never affected
    ///    by a real preference on the developer's machine.
    /// 2. `JRC_WORKSPACES_ROOT` — explicit, used by headless runs.
    /// 3. The stored preference.
    /// 4. `~/Jamf-Reports`.
    ///
    /// A stored path that has become unusable (share unmounted, folder deleted)
    /// is **not** silently swapped for the default: doing so would start a
    /// second, empty history beside the real one. The path is returned as
    /// configured and `ConfigDoctorService` reports why nothing can be read.
    static func current(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if DEBUG
        if let path = environment["JRC_TEST_WORKSPACES_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif

        if let path = environment[environmentKey], !path.isEmpty {
            return refusingSensitive(URL(fileURLWithPath: path, isDirectory: true))
        }

        if let stored = defaults.string(forKey: defaultsKey),
           !stored.trimmingCharacters(in: .whitespaces).isEmpty {
            return refusingSensitive(URL(fileURLWithPath: stored, isDirectory: true))
        }

        return defaultRoot
    }

    /// Re-check the one validation rule that must hold on every read.
    ///
    /// `set(_:)` validates fully, but neither the environment variable nor the
    /// preferences key can only be written through it — `defaults write` and a
    /// hand-edited launchd job both reach this path. Only the sensitive-location
    /// rule is re-applied: a system directory or credential store is never a
    /// legitimate workspace, whereas a root that is merely *unreachable* is the
    /// ordinary state of an unmounted share and must be returned as configured.
    /// Silently substituting the default there would start a second, empty
    /// history beside the real one and read as total data loss.
    private static func refusingSensitive(_ url: URL) -> URL {
        guard WorkspacePaths.isSensitiveAbsolutePath(url) else { return url }
        AppLogger.platform.error(
            """
            workspace root \(url.path, privacy: .public) is a reserved location \
            — using the default
            """
        )
        return defaultRoot
    }

    /// `~/Jamf-Reports` — the value used when nothing is configured.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports")
    }

    /// Home-relative display form of the workspace root (`~/Jamf-Reports`, or
    /// the configured path when it lives outside the home directory).
    ///
    /// Every screen that shows the user where a file lives must go through this
    /// — a hardcoded `~/Jamf-Reports/...` in UI copy names a path that stops
    /// existing the moment the root is moved to a team folder.
    static var displayRoot: String {
        let path = ProfileService.workspacesRoot().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Display path for one profile's workspace, with an optional subpath.
    static func displayPath(profile: String, subpath: String = "") -> String {
        let base = "\(displayRoot)/\(profile)"
        return subpath.isEmpty ? base : "\(base)/\(subpath)"
    }

    /// True when the operator has moved the root off its default.
    static func isCustomised(defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.string(forKey: defaultsKey), !stored.isEmpty else {
            return false
        }
        return URL(fileURLWithPath: stored, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
            != defaultRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Pre-flight a candidate root. Pure apart from the filesystem probe.
    static func validate(_ url: URL, fileManager: FileManager = .default) -> Validation {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL

        // The root holds device inventory and run logs; it must never be aimed
        // at a system directory or a credential store. The CloudStorage
        // carve-out in isSensitiveAbsolutePath is what lets a provider mount
        // under ~/Library/CloudStorage through.
        if WorkspacePaths.isSensitiveAbsolutePath(resolved) { return .sensitiveLocation }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .notADirectory }
        guard fileManager.isWritableFile(atPath: resolved.path) else { return .notWritable }
        return .ok
    }

    /// Persist a new root. Creates the folder when it does not exist yet.
    ///
    /// Existing workspaces are **not** moved — the operator either points at a
    /// folder that already holds them or copies them across deliberately. A
    /// silent multi-gigabyte relocation onto a synced volume is not something
    /// to do on a button press.
    @discardableResult
    static func set(
        _ url: URL?,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let url else {
            defaults.removeObject(forKey: defaultsKey)
            return defaultRoot
        }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let validation = validate(resolved, fileManager: fileManager)
        guard validation.isUsable else {
            throw RootError.rejected(validation)
        }
        if validation == .missing {
            try fileManager.createDirectory(
                at: resolved,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let previous = current(defaults: defaults, environment: [:])
        defaults.set(resolved.path, forKey: defaultsKey)
        if previous.resolvingSymlinksInPath().standardizedFileURL.path != resolved.path {
            // Managed LaunchAgent plists embed the old root in WorkingDirectory
            // and their run environment, and a root move changes neither mode,
            // cadence, tiers nor exclusions — so the reconcile signature would
            // find them unchanged and leave them pointing at the old location.
            ManagedAutomation.invalidateManagedPlists(defaults: defaults)
        }
        AppLogger.platform.notice(
            "workspace root set to \(resolved.path, privacy: .public)"
        )
        return resolved
    }

    enum RootError: Error, LocalizedError {
        case rejected(Validation)

        var errorDescription: String? {
            switch self {
            case .rejected(let validation):
                return validation.message ?? "That folder cannot be used as a workspace root."
            }
        }
    }
}
