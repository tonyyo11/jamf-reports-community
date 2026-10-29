import Foundation

/// Resolves per-profile workspace subdirectories that are configurable via
/// `config.yaml` (`jamf_cli.data_dir` and `charts.historical_csv_dir`).
///
/// All Swift call sites had been hardcoding the defaults (`jamf-cli-data` /
/// `snapshots`), which silently broke when a user pointed those keys at a
/// different folder. The Python side resolves them via `Config.resolve_path`
/// (relative paths resolve from the config file's directory). This helper
/// mirrors that behavior, reading the file through the engine's loader.
enum WorkspacePaths {

    /// The workspace's folder under the workspaces root. Every folder path starts here.
    static func workspaceURL(
        for workspace: WorkspaceID, under root: URL = ProfileService.workspacesRoot()
    ) -> URL {
        root.appendingPathComponent(workspace.pathComponent, isDirectory: true)
    }

    /// The conventional subdirectory name for generated report output.
    /// Used by `CLIBridge+Generation` to construct HTML and PDF output paths
    /// without duplicating the literal.
    static let generatedReportsDirName = "Generated Reports"

    /// `<workspace>/Generated Reports` by default; honors `output.output_dir`.
    static func outputDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return try resolve(
            rawValue: try configValue(workspace: workspace, section: "output", key: "output_dir")
                as? String,
            fallback: "Generated Reports",
            workspace: workspace,
            reportsFolder: true
        )
    }

    /// The folder every report is written to: `outputDir(for:)`, or `Generated Reports` in the
    /// workspace when the typed folder is refused, with one `[warn]` line on `onLine` naming
    /// it and why. Nil for a profile with no workspace.
    static func reportsDir(
        for profile: String, onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> URL? {
        guard let workspace = workspaceRoot(for: profile) else { return nil }
        do {
            return try outputDir(for: profile)
        } catch {
            // A peer can plant a link at the fallback's name; refused, nothing is written.
            guard let fallback = confinedFolderOrWarn(
                [generatedReportsDirName], under: workspace,
                onLine: onLine ?? CLIBridge.noOpOnLine) else { return nil }
            let typed = ((try? configValue(workspace: workspace, section: "output",
                                           key: "output_dir")) ?? nil) as? String ?? ""
            let reason = refusal(of: error, workspace: workspace)
            let msg = "[warn] output.output_dir \"\(ConfigSchema.displayText(typed))\" is not "
                + "used: \(reason). Writing to \(generatedReportsDirName) in the "
                + "workspace instead."
            AppLogger.report.warning("\(msg, privacy: .private)")
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return fallback
        }
    }

    /// The folder the Reports screen lists and Finder actions may open: `reportsDir(for:)` with
    /// symlinks resolved. A folder `resolve` accepted outside the workspace is already resolved,
    /// so it passes unchanged; the `Generated Reports` fallback is not, and a symlink there that
    /// leads out of the workspace is refused (nil) rather than followed.
    static func readableReportsDir(for profile: String) -> URL? {
        guard let workspace = workspaceRoot(for: profile),
              let dir = reportsDir(for: profile, onLine: nil) else { return nil }
        let resolved = dir.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: workspace)
                || resolved.path == dir.standardizedFileURL.path else { return nil }
        return resolved
    }

    /// Why `resolve` refused a typed folder, worded for a `[warn]` line. With the `workspace`
    /// it was resolved against, an opt-in this Mac has not confirmed is named as that.
    static func refusal(of error: Error, workspace: URL? = nil) -> String {
        switch error {
        case PathError.disallowedAbsolutePath(let url) where isSensitiveAbsolutePath(url):
            "that folder is reserved by macOS or holds credentials"
        case PathError.worldReadableFolder:
            "every account on this Mac can read it"
        case PathError.disallowedAbsolutePath:
            workspace.map { SharedConfigPin.pathOverrides(workspace: $0).absolutePaths } == true
                ? "output.allow_absolute_paths changed in the shared config.yaml, not confirmed "
                    + "on this Mac (Config Doctor)"
                : "it is outside the workspace and output.allow_absolute_paths is not true"
        case PathError.resolutionEscaped:
            "a relative path must stay inside the workspace"
        case PathError.symlinkedSubfolder:
            "it is a symbolic link inside the workspace"
        default:
            "config.yaml could not be read"
        }
    }

    /// `<output_dir>/archive` by default; honors `output.archive_dir`.
    ///
    /// Matches Python `Config.resolve_path("output", "archive_dir")`: when the user
    /// supplies a relative path it resolves against the config file's directory
    /// (the workspace root). Only the empty/unset fallback resolves relative to
    /// `output_dir`, mirroring Python's `out_path.parent / "archive"`.
    static func archiveDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        let raw = try configValue(workspace: workspace, section: "output", key: "archive_dir")
            as? String
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try confinedFolder(["archive"], under: try outputDir(for: profile))
        }
        return try resolve(
            rawValue: trimmed,
            fallback: "archive",
            workspace: workspace,
            reportsFolder: true
        )
    }

    /// `<workspace>/jamf-cli-data` by default; honors `jamf_cli.data_dir`.
    static func dataDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return try resolve(
            rawValue: try configValue(workspace: workspace, section: "jamf_cli", key: "data_dir")
                as? String,
            fallback: "jamf-cli-data",
            workspace: workspace
        )
    }

    /// `<workspace>/snapshots` by default; honors `charts.historical_csv_dir`.
    static func historicalDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return try resolve(
            rawValue: try configValue(
                workspace: workspace, section: "charts", key: "historical_csv_dir") as? String,
            fallback: "snapshots",
            workspace: workspace
        )
    }

    /// `<historical_csv_dir>/summaries` — the trend-summary directory written
    /// by `_emit_summary_json` on the Python side.
    static func summariesDir(for profile: String) throws -> URL {
        try confinedFolder(["summaries"], under: try historicalDir(for: profile))
    }

    /// `<jamf_cli.data_dir>/state` — per-report cadence state files
    /// (`<report>.last`) written by `StateFileStore` during `collect`.
    ///
    /// Co-located with the JSON snapshots on purpose: when an operator
    /// clears `jamf-cli-data` to force a fresh refresh, the cadence state
    /// goes with it. Profile-scoped via `data_dir` for multi-tenant use.
    ///
    /// PR-22 T-6.
    static func stateDir(for profile: String) throws -> URL {
        try confinedFolder(["state"], under: try dataDir(for: profile))
    }

    /// `<workspace>/automation/logs` — the run-history log directory written
    /// by LaunchAgent stdout/stderr redirection.
    ///
    /// This path is fixed by convention (not a config knob), so no YAML
    /// parsing is performed. The helper throws when `profile` fails
    /// `ProfileService.isValid`, enforcing the profile-name regex at one
    /// canonical site, and when `automation` or `logs` is a symlink (`confinedFolder`).
    static func runHistoryDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return try confinedFolder(["automation", "logs"], under: workspace)
    }

    /// `~/Library/Logs/JamfReports/diagnostics/<profile>` — where the native diagnostic bundle
    /// zip is written. Per user and outside the workspace, which may be a team folder every
    /// Mac reads; `SystemActions` already lets Finder reveal `~/Library/Logs/JamfReports`.
    /// Fixed by convention (not a config knob), so no YAML parsing.
    static func diagnosticsDir(
        for profile: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        guard let id = WorkspaceID(profile) else { throw PathError.invalidProfile(profile) }
        return home
            .appendingPathComponent("Library/Logs/JamfReports/diagnostics", isDirectory: true)
            .appendingPathComponent(id.pathComponent, isDirectory: true)
    }

    /// A fixed folder below a workspace (or below a config-derived folder such as `data_dir`),
    /// refused when any component of it is a symbolic link. A peer on a shared folder can
    /// plant a link at `automation`, `backups` or `_archive`, which would send this Mac's
    /// reads, writes and prunes to a folder of the peer's choosing.
    ///
    /// `root` is resolved first, so a workspace root that is itself a link (a synced
    /// `~/Library/CloudStorage` folder, iCloud, `/Volumes`) keeps working; each component below
    /// it is then checked with `lstat`. A component that does not exist yet passes.
    static func confinedFolder(_ components: [String], under root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var current = base
        var walked: [String] = []
        for component in components {
            current = current.appendingPathComponent(component, isDirectory: true)
            walked.append(component)
            if isSymbolicLink(current) {
                throw PathError.symlinkedSubfolder(walked.joined(separator: "/"))
            }
        }
        guard isInside(current.resolvingSymlinksInPath().standardizedFileURL, root: base) else {
            throw PathError.resolutionEscaped(components.joined(separator: "/"), base)
        }
        return current
    }

    /// `confinedFolder` for best-effort callers: nil for a refused folder, with one `[warn]`
    /// line (Console, and `onLine` when given) naming the folder and why.
    static func confinedFolderOrWarn(
        _ components: [String], under root: URL,
        onLine: @Sendable (CLIBridge.LogLine) -> Void = CLIBridge.noOpOnLine
    ) -> URL? {
        do {
            return try confinedFolder(components, under: root)
        } catch {
            let msg = "[warn] \(components.joined(separator: "/")) is not used: "
                + "\(refusal(of: error))."
            AppLogger.collect.warning("\(msg, privacy: .private)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
            return nil
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Internals

    enum PathError: Error, LocalizedError {
        case invalidProfile(String)
        case configReadError(URL, Error)
        case resolutionEscaped(String, URL)
        /// An absolute path was supplied that resolves outside the workspace
        /// AND is not on the allow-list (e.g. it points at `~/Library`,
        /// `~/.ssh`, `/etc`, `/var`, `/private`, `/System`). Refused even
        /// when `allow_absolute_paths: true` is set in workspace config.
        case disallowedAbsolutePath(URL)
        /// A report or archive folder in `/Users/Shared` or `~/Public`, which every local
        /// account can read. Refused even with the opt-in.
        case worldReadableFolder(URL)
        /// A fixed workspace subfolder (`automation/logs`, `backups`, ...) that is a symlink.
        case symlinkedSubfolder(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p): ProfileName.invalidMessage(p)
            case .configReadError(let u, let e): "Could not read config at \(u.lastPathComponent): \(e.localizedDescription)"
            case .resolutionEscaped(let val, let root): "Path '\(val)' escapes workspace root \(root.lastPathComponent)"
            case .disallowedAbsolutePath(let u): "Disallowed absolute path: \(u.path)"
            case .worldReadableFolder(let u): "World-readable folder: \(u.path)"
            case .symlinkedSubfolder(let f): "'\(f)' inside the workspace is a symbolic link"
            }
        }
    }

    /// True when an absolute path resolves to a known-sensitive location
    /// (system directories, `/Applications`, `~/Library`, every dot-entry directly under
    /// home, keychain config). Used by tests of the disallowed-absolute-path policy and by
    /// future callers that gate `output.allow_absolute_paths` enforcement.
    ///
    /// The path need not exist: a peer-edited config.yaml can name a folder the app would
    /// create. Matching ignores case (APFS is case-insensitive by default) and Unicode
    /// normalization form, so `~/library/LaunchAgents/x` is denied like `~/Library/...`.
    ///
    /// `workspaceRoot` keeps a workspace root under another dot-folder (`~/.jamf-reports`)
    /// usable: a stored root that newly failed this check would fall back to the default
    /// root and its history would look lost. The credential folders stay refused.
    static func isSensitiveAbsolutePath(_ url: URL, workspaceRoot: Bool = false) -> Bool {
        let path = folded(resolvedForPolicy(url))
        let homes = homeFolds()

        // Carve-out: `~/Library` is denied wholesale, but macOS mounts every
        // modern sync provider (OneDrive/SharePoint, Box, Dropbox, Google Drive,
        // iCloud Drive) under `~/Library/CloudStorage/<Provider>-<Account>/`.
        // Blanket-denying that made "publish reports to the team folder"
        // impossible while doing nothing for security — it is user data, not
        // application support. Everything else under `~/Library` stays denied.
        // Reaching it still requires `output.allow_absolute_paths: true`, and
        // ConfigDoctor warns about what syncing costs.
        let underHome = homes.compactMap { relative(path, under: $0) }
        if underHome.contains(where: { $0.hasPrefix("library/cloudstorage/") }) { return false }

        let denied = ["/etc", "/var", "/private", "/system", "/library", "/usr", "/bin", "/sbin",
                      "/applications"]
        if denied.contains(where: { relative(path, under: $0) != nil }) { return true }

        // Home dotfiles and dot-folders (.zshrc, .netrc, .gitconfig, .docker, .ssh, ...) are
        // where credentials and shell start-up files live; none is a place for reports.
        return underHome.contains { relative in
            if relative == "library" || relative.hasPrefix("library/") { return true }
            guard relative.hasPrefix(".") else { return false }
            let first = relative.split(separator: "/").first.map(String.init) ?? relative
            return !workspaceRoot || credentialFolders.contains(first)
        }
    }

    /// True for a folder every local account can read: `/Users/Shared`, `~/Public`, `/tmp` and
    /// `/var/tmp`.
    /// Applied only to the folders the engine writes reports into (`output.output_dir`,
    /// `output.archive_dir`, `retention.archive_dir`). A workspace root, `jamf_cli.data_dir`,
    /// a save panel or an explicit CLI path is a deliberate choice, and refusing one that
    /// already holds data would orphan it. Same matching as `isSensitiveAbsolutePath`.
    static func isWorldReadableSharedFolder(_ url: URL) -> Bool {
        let path = folded(resolvedForPolicy(url))
        // `/tmp` resolves to `/private/tmp`, which the symlink-resolved path then carries.
        let shared = ["/users/shared", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
        if shared.contains(where: { relative(path, under: $0) != nil }) { return true }
        return homeFolds().contains { relative(path, under: $0 + "/public") != nil }
    }

    /// Dot-folders refused even as a workspace root (the 2.8.3 list).
    private static let credentialFolders: Set<String> = [
        ".ssh", ".config", ".aws", ".gnupg", ".kube"
    ]

    /// `url` with symlinks resolved. A path that does not exist yet keeps its missing tail:
    /// the deepest existing ancestor is resolved and the rest appended, so an alias or a
    /// different spelling of an existing parent cannot hide a denied folder.
    static func resolvedForPolicy(_ url: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while existing.path != "/", !fm.fileExists(atPath: existing.path) {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return tail.reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL.path
    }

    /// Where a typed folder lands, for a row that asks a person to confirm it: built on the
    /// workspace as `resolve` builds it (a relative value is the workspace's, `~` expands),
    /// symlinks resolved through the deepest existing ancestor, and whether it is inside the
    /// workspace. It does not judge the folder; `resolve` still refuses what it refuses.
    static func destination(
        of typed: String, workspace: URL
    ) -> (path: String, insideWorkspace: Bool) {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let expanded = expandTilde(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : root.appendingPathComponent(expanded, isDirectory: true)
        let path = resolvedForPolicy(candidate)
        return (path, isInside(URL(fileURLWithPath: path), root: root))
    }

    private static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The home folder as typed and with symlinks resolved, folded for comparison.
    private static func homeFolds() -> [String] {
        let home = NSString(string: "~").expandingTildeInPath
        let resolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        return Array(Set([folded(home), folded(resolved)]))
    }

    /// `path` below `root` ("" for `root` itself), or nil when it is not inside it.
    private static func relative(_ path: String, under root: String) -> String? {
        if path == root { return "" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    private static func workspaceRoot(for profile: String) -> URL? {
        guard let url = ProfileService.workspaceURL(for: profile) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves a raw config value against the workspace (symlinks resolved): a relative path
    /// must stay inside it; an absolute path outside it needs `output.allow_absolute_paths`
    /// and is never a system or credentials folder. `reportsFolder` marks a folder reports or
    /// archives are written to, which also refuses `/Users/Shared` and `~/Public`.
    /// `retention.archive_dir` follows it too.
    static func resolve(
        rawValue: String?,
        fallback: String,
        workspace: URL,
        reportsFolder: Bool = false
    ) throws -> URL {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback : trimmed
        let expanded = expandTilde(value)
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            candidate = workspace.appendingPathComponent(expanded, isDirectory: true)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        // B-05: default-deny for absolute paths outside the workspace. Even
        // non-sensitive absolute paths (e.g. /Volumes/Share, another user's
        // home) are refused unless the workspace's config opts in via
        // `output.allow_absolute_paths: true`. Sensitive locations are still
        // refused even when the opt-in is set.
        if expanded.hasPrefix("/") {
            if isSensitiveAbsolutePath(resolved) {
                throw PathError.disallowedAbsolutePath(resolved)
            }
            if isInside(resolved, root: workspace) {
                return resolved
            }
            if reportsFolder, isWorldReadableSharedFolder(resolved) {
                throw PathError.worldReadableFolder(resolved)
            }
            let optedIn = optIn((try? configValue(
                workspace: workspace, section: "output", key: "allow_absolute_paths"
            )) ?? nil) == true
            // SF-8 (option b): record the opt-in decision alongside the policy
            // decision, so "Disallowed absolute path" can be told apart from a
            // missing or unreadable opt-in. The typed value stays out of the log.
            AppLogger.collect.info(
                "WorkspacePaths: allow_absolute_paths opts in: \(optedIn, privacy: .public)"
            )
            if optedIn {
                AppLogger.collect.warning(
                    "WorkspacePaths: accepting absolute path outside workspace via opt-in"
                )
                return resolved
            }
            throw PathError.disallowedAbsolutePath(resolved)
        }

        // If it's relative, it must stay inside the workspace.
        if isInside(resolved, root: workspace) {
            return resolved
        }

        throw PathError.resolutionEscaped(value, workspace)
    }

    /// `output.allow_absolute_paths` as read from `rawMapping`: true for true, yes, on or 1, false
    /// for false, no, off or 0 (any case, quoted or not), nil for anything else. The opt-in has
    /// always taken these spellings; the Config Doctor suggests writing true.
    static func optIn(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        guard let word = ((value as? String) ?? (value as? Int).map { String($0) })?.lowercased()
        else { return nil }
        if ["yes", "on", "1"].contains(word) { return true }
        return ["no", "off", "0"].contains(word) ? false : nil
    }

    static func expandTilde(_ value: String) -> String {
        guard value.hasPrefix("~") else { return value }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + String(value.dropFirst(1)) }
        return value
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// SF-8: `<workspace>/config.yaml` read through the engine's loader, so a value has the
    /// type the decoder would give it (a path is a `String`, the opt-in a `Bool`) and a key set
    /// twice reads as its last value. Nil only when the section/key isn't present.
    private static func configValue(workspace: URL, section: String, key: String) throws -> Any? {
        // A pinned key that drifted on a shared workspace reads as its safe value.
        if let safe = SharedConfigPin.safePathValue(
            workspace: workspace, section: section, key: key) {
            return safe
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }

        let text: String
        do {
            text = try ConfigLoader.readText(at: configURL)
        } catch {
            throw PathError.configReadError(configURL, error)
        }

        do {
            return ConfigLoader.rawValue(
                at: [section, key], in: try ConfigLoader.rawMapping(fromYAML: text))
        } catch {
            // YAMLCodec rejects only documents whose top level is not a
            // mapping (e.g. an empty file or a sequence at the root). Both
            // are legitimate "no value here" outcomes; surface a debug log
            // so an unparseable config doesn't masquerade as a missing key.
            AppLogger.collect.warning(
                "WorkspacePaths: could not parse config.yaml: \(error.localizedDescription, privacy: .private)"
            )
        }
        return nil
    }
}
