import Foundation

/// Resolves per-profile workspace subdirectories that are configurable via
/// `config.yaml` (`jamf_cli.data_dir` and `charts.historical_csv_dir`).
///
/// All Swift call sites had been hardcoding the defaults (`jamf-cli-data` /
/// `snapshots`), which silently broke when a user pointed those keys at a
/// different folder. The Python side resolves them via `Config.resolve_path`
/// (relative paths resolve from the config file's directory). This helper
/// mirrors that behavior with a tiny YAML scanner so the GUI does not need a
/// full YAML parser.
enum WorkspacePaths {

    /// `<workspace>/Generated Reports` by default; honors `output.output_dir`.
    static func outputDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return try resolve(
            rawValue: try configValue(workspace: workspace, section: "output", key: "output_dir"),
            fallback: "Generated Reports",
            workspace: workspace
        )
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
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let output = try outputDir(for: profile)
            return output.appendingPathComponent("archive", isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
        return try resolve(
            rawValue: trimmed,
            fallback: "archive",
            workspace: workspace,
            isArchive: true
        )
    }

    /// `<workspace>/jamf-cli-data` by default; honors `jamf_cli.data_dir`.
    static func dataDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return try resolve(
            rawValue: try configValue(workspace: workspace, section: "jamf_cli", key: "data_dir"),
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
            rawValue: try configValue(workspace: workspace, section: "charts", key: "historical_csv_dir"),
            fallback: "snapshots",
            workspace: workspace
        )
    }

    /// `<historical_csv_dir>/summaries` — the trend-summary directory written
    /// by `_emit_summary_json` on the Python side.
    static func summariesDir(for profile: String) throws -> URL {
        try historicalDir(for: profile).appendingPathComponent("summaries", isDirectory: true)
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
        try dataDir(for: profile)
            .appendingPathComponent("state", isDirectory: true)
    }

    /// `<workspace>/automation/logs` — the run-history log directory written
    /// by LaunchAgent stdout/stderr redirection.
    ///
    /// This path is fixed by convention (not a config knob), so no YAML
    /// parsing is performed. The helper throws only when `profile` fails
    /// `ProfileService.isValid`, enforcing the profile-name regex at one
    /// canonical site.
    static func runHistoryDir(for profile: String) throws -> URL {
        guard let workspace = workspaceRoot(for: profile) else {
            throw PathError.invalidProfile(profile)
        }
        return workspace
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
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

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p): "Invalid profile: \(p)"
            case .configReadError(let u, let e): "Could not read config at \(u.lastPathComponent): \(e.localizedDescription)"
            case .resolutionEscaped(let val, let root): "Path '\(val)' escapes workspace root \(root.lastPathComponent)"
            case .disallowedAbsolutePath(let u): "Disallowed absolute path: \(u.path)"
            }
        }
    }

    /// True when an absolute path resolves to a known-sensitive location
    /// (system directories, user dotfiles, keychain config). Used by tests
    /// of the disallowed-absolute-path policy and by future callers that
    /// gate `output.allow_absolute_paths` enforcement.
    static func isSensitiveAbsolutePath(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let denied: [String] = [
            "/etc", "/var", "/private", "/System", "/Library", "/usr", "/bin", "/sbin"
        ]
        let home = NSString(string: "~").expandingTildeInPath
        let homeDenied: [String] = [
            "\(home)/Library", "\(home)/.ssh", "\(home)/.config",
            "\(home)/.aws", "\(home)/.gnupg", "\(home)/.kube"
        ]
        for prefix in denied {
            if resolved == prefix || resolved.hasPrefix(prefix + "/") { return true }
        }
        for prefix in homeDenied {
            if resolved == prefix || resolved.hasPrefix(prefix + "/") { return true }
        }
        return false
    }

    private static func workspaceRoot(for profile: String) -> URL? {
        guard let url = ProfileService.workspaceURL(for: profile) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves a raw config value against the workspace.
    private static func resolve(
        rawValue: String?,
        fallback: String,
        workspace: URL,
        isArchive: Bool = false
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
            let optedIn = (try? configValue(
                workspace: workspace, section: "output", key: "allow_absolute_paths"
            )) ?? nil
            // SF-8 (option b): record the resolved opt-in value alongside the
            // policy decision. If a future config shape (flow-style, dotted
            // keys, tab indentation) ends up parsed as nil, this entry shows
            // *why* the user got "Disallowed absolute path" rather than the
            // expected acceptance.
            AppLogger.engine.info(
                "WorkspacePaths: allow_absolute_paths resolved to \(optedIn ?? "<nil>", privacy: .public)"
            )
            if isTruthyConfigValue(optedIn) {
                AppLogger.engine.warning(
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

    /// Recognize the YAML truthy values our minimal scanner produces (already
    /// trimmed of quotes and comments by `configValue`).
    private static func isTruthyConfigValue(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        return v == "true" || v == "yes" || v == "1" || v == "on"
    }

    private static func expandTilde(_ value: String) -> String {
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

    /// SF-8: parse `<workspace>/config.yaml` via the project's `YAMLCodec` so
    /// flow-style mappings (`output: {allow_absolute_paths: true}`), tab
    /// indentation, dotted keys, and other shapes the previous minimal
    /// line-scanner silently skipped resolve correctly. Falls through to a
    /// nil result only when the section/key genuinely isn't present.
    private static func configValue(workspace: URL, section: String, key: String) throws -> String? {
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }

        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw PathError.configReadError(configURL, error)
        }

        do {
            let document = try YAMLCodec.decode(text)
            if case .mapping(let root) = document.root,
               case .mapping(let sectionMap)? = root.value(for: section),
               let value = sectionMap.value(for: key) {
                return value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // YAMLCodec rejects only documents whose top level is not a
            // mapping (e.g. an empty file or a sequence at the root). Both
            // are legitimate "no value here" outcomes; surface a debug log
            // so an unparseable config doesn't masquerade as a missing key.
            AppLogger.engine.warning(
                "WorkspacePaths: could not parse config.yaml: \(error.localizedDescription, privacy: .private)"
            )
        }
        return nil
    }
}
