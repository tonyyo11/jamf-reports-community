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

    // MARK: - Internals

    enum PathError: Error, LocalizedError {
        case invalidProfile(String)
        case configReadError(URL, Error)
        case resolutionEscaped(String, URL)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p): "Invalid profile: \(p)"
            case .configReadError(let u, let e): "Could not read config at \(u.lastPathComponent): \(e.localizedDescription)"
            case .resolutionEscaped(let val, let root): "Path '\(val)' escapes workspace root \(root.lastPathComponent)"
            }
        }
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
        
        // Absolute paths outside the workspace are allowed, matching the Python side.
        if expanded.hasPrefix("/") {
            return resolved
        }
        
        // If it's relative, it must stay inside the workspace.
        if isInside(resolved, root: workspace) {
            return resolved
        }
        
        throw PathError.resolutionEscaped(value, workspace)
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

    private static func configValue(workspace: URL, section: String, key: String) throws -> String? {
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        
        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw PathError.configReadError(configURL, error)
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
