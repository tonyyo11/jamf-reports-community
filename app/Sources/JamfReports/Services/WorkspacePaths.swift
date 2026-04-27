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

    /// `<workspace>/jamf-cli-data` by default; honors `jamf_cli.data_dir`.
    static func dataDir(for profile: String) -> URL? {
        guard let workspace = workspaceRoot(for: profile) else { return nil }
        return resolve(
            rawValue: configValue(workspace: workspace, section: "jamf_cli", key: "data_dir"),
            fallback: "jamf-cli-data",
            workspace: workspace
        )
    }

    /// `<workspace>/snapshots` by default; honors `charts.historical_csv_dir`.
    static func historicalDir(for profile: String) -> URL? {
        guard let workspace = workspaceRoot(for: profile) else { return nil }
        return resolve(
            rawValue: configValue(workspace: workspace, section: "charts", key: "historical_csv_dir"),
            fallback: "snapshots",
            workspace: workspace
        )
    }

    /// `<historical_csv_dir>/summaries` — the trend-summary directory written
    /// by `_emit_summary_json` on the Python side.
    static func summariesDir(for profile: String) -> URL? {
        historicalDir(for: profile)?.appendingPathComponent("summaries", isDirectory: true)
    }

    // MARK: - Internals

    private static func workspaceRoot(for profile: String) -> URL? {
        guard let url = ProfileService.workspaceURL(for: profile) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves a raw config value against the workspace.
    /// - Absolute paths (`/...` or `~...`) are honored as-is, expanding `~` to home.
    /// - Relative paths resolve from the workspace (matching `Config.resolve_path`,
    ///   since the workspace is the config file's directory).
    /// - Empty/missing values fall back to the documented default.
    /// - Returns nil if the resolved path escapes the workspace; callers fall
    ///   back to `<workspace>/<fallback>`.
    private static func resolve(rawValue: String?, fallback: String, workspace: URL) -> URL {
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
        if isInside(resolved, root: workspace) {
            return resolved
        }
        // Absolute paths outside the workspace are intentionally allowed —
        // the Python tool also lets users point these elsewhere.
        if expanded.hasPrefix("/") {
            return resolved
        }
        return workspace.appendingPathComponent(fallback, isDirectory: true)
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

    /// Reads a single `<section>.<key>` scalar from `<workspace>/config.yaml`.
    /// Uses the same minimal YAML pattern as `DeviceInventoryService`: section
    /// headers at column 0, two-space-indented `key: value` lines.
    private static func configValue(workspace: URL, section: String, key: String) -> String? {
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        var inSection = false
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if !rawLine.hasPrefix(" "), trimmed.hasSuffix(":") {
                let header = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                inSection = (header == section)
                continue
            }
            guard inSection, let colon = trimmed.firstIndex(of: ":") else { continue }

            let lineKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard lineKey == key else { continue }

            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#") {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value
        }
        return nil
    }
}
