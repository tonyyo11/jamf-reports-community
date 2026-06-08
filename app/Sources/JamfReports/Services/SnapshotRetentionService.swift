import Foundation

/// Admin-controlled jamf-cli snapshot lifecycle (v2.2.0).
///
/// **Default is OFF — nothing is ever removed.** Raw snapshots are a reporting
/// input (per-device day-over-day / week-over-week history, especially mSCP),
/// and many deployments host `~/Jamf-Reports` on cloud storage where capacity
/// is not a concern. Cleanup runs only when the operator sets `retention.enabled`.
///
/// When enabled, the default mode is `archive`: files past the horizon are MOVED
/// to `<archive>/jamf-cli-data/<kind>/` (still on disk; the admin chooses whether
/// to trash them), not deleted. `delete` mode removes them. The durable trend
/// `summaries/` are never touched unless `include_summaries` is true.
///
/// Non-snapshot subdirectories (`state`, `sofa`) and the archive itself are never
/// swept. The once-per-day marker lives at the workspace root, OUTSIDE the swept
/// `jamf-cli-data/` tree.
enum SnapshotRetentionService {

    enum Mode: Sendable, Equatable { case archive, delete }

    struct Policy: Sendable {
        var enabled: Bool
        var mode: Mode
        var keepDays: Int
        var keepCount: Int
        var includeSummaries: Bool

        /// Nothing to do when disabled or when neither an age nor a count rule
        /// would ever remove a file.
        var isActive: Bool { enabled && (keepDays > 0 || keepCount > 0) }
    }

    /// `jamf-cli-data` subdirectories that are NOT device snapshots and must
    /// never be on a snapshot-retention horizon.
    static let nonSnapshotSubdirs: Set<String> = ["state", "sofa"]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func policy(from config: RetentionConfig?) -> Policy {
        guard let config else {
            return Policy(enabled: false, mode: .archive, keepDays: 365,
                          keepCount: 0, includeSummaries: false)
        }
        return Policy(
            enabled: config.isEnabled,
            mode: config.resolvedMode == .delete ? .delete : .archive,
            keepDays: config.keepDays,
            keepCount: config.keepCount,
            includeSummaries: config.includesSummaries
        )
    }

    // MARK: - Once-per-day wiring (call site: ReportEngine.collect)

    /// Sweep at most once per calendar day, only when retention is enabled.
    /// Reads config + marker itself, so every collect path can call it safely;
    /// best-effort (never throws into the collect).
    @discardableResult
    static func sweepIfDue(
        profile: String,
        now: Date = Date(),
        onLine: @Sendable (CLIBridge.LogLine) -> Void = CLIBridge.noOpOnLine
    ) -> Int {
        guard ProfileService.isValid(profile),
              let workspace = ProfileService.workspaceURL(for: profile) else { return 0 }
        let config = loadRetentionConfig(workspace: workspace)
        let pol = policy(from: config)
        guard pol.isActive else { return 0 }

        let today = dayFormatter.string(from: now)
        let marker = workspace.appendingPathComponent(".retention-last")
        if (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == today { return 0 }

        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return 0 }
        let archiveRoot = resolvedArchiveRoot(config: config, workspace: workspace)
        let summariesDir = pol.includeSummaries ? try? WorkspacePaths.summariesDir(for: profile) : nil

        let acted = sweep(
            dataDir: dataDir, summariesDir: summariesDir,
            archiveRoot: archiveRoot, policy: pol, now: now, onLine: onLine
        )
        try? today.write(to: marker, atomically: true, encoding: .utf8)
        if acted > 0 {
            let verb = pol.mode == .archive ? "archived" : "deleted"
            onLine(.init(timestamp: now, level: .info,
                         text: "[info] retention: \(verb) \(acted) snapshot file(s) for \(profile)"))
        }
        return acted
    }

    /// Resolved raw-snapshot archive root: `retention.archive_dir` if set, else
    /// `<workspace>/_archive`. Distinct from the reports archive
    /// (`output.archive_dir`) so the two never collide.
    ///
    /// Absolute `archive_dir` values are confined to `ProfileService.workspacesRoot()`.
    /// An out-of-bounds absolute path is rejected with a warning and falls back to the
    /// default, matching the allow-list idiom used by `SystemActions`.
    static func resolvedArchiveRoot(config: RetentionConfig?, workspace: URL) -> URL {
        let defaultArchive = workspace.appendingPathComponent("_archive", isDirectory: true)
        let raw = config?.resolvedArchiveDir ?? ""
        guard !raw.isEmpty else { return defaultArchive }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            // Relative path — join to workspace; always confined by construction.
            return workspace.appendingPathComponent(expanded, isDirectory: true)
        }
        // Absolute path: confine to workspacesRoot using the SystemActions allow-list idiom.
        let candidate = URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath()
        let allowedRoot = ProfileService.workspacesRoot()
            .resolvingSymlinksInPath().path
        if candidate.path == allowedRoot || candidate.path.hasPrefix(allowedRoot + "/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        AppLogger.engine.warning(
            "SnapshotRetentionService: archive_dir '\(expanded, privacy: .public)' is outside workspacesRoot — falling back to default _archive"
        )
        return defaultArchive
    }

    private static func loadRetentionConfig(workspace: URL) -> RetentionConfig? {
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let config = try? ConfigLoader.load(from: configURL) else { return nil }
        return config.retention
    }

    // MARK: - Core sweep (testable with explicit dirs)

    /// Sweep every snapshot kind under `dataDir` (skipping non-snapshot subdirs
    /// and any `_`-prefixed dir), plus `summariesDir` when provided. Returns the
    /// number of files archived/deleted.
    @discardableResult
    static func sweep(
        dataDir: URL,
        summariesDir: URL?,
        archiveRoot: URL,
        policy: Policy,
        now: Date = Date(),
        onLine: @Sendable (CLIBridge.LogLine) -> Void = CLIBridge.noOpOnLine
    ) -> Int {
        guard policy.isActive else { return 0 }
        let fm = FileManager.default
        var acted = 0

        let subdirs = (try? fm.contentsOfDirectory(
            at: dataDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        for subdir in subdirs {
            guard (try? subdir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let name = subdir.lastPathComponent
            if nonSnapshotSubdirs.contains(name) || name.hasPrefix("_") { continue }
            acted += sweepDirectory(
                subdir, archiveSubpath: "jamf-cli-data/\(name)",
                archiveRoot: archiveRoot, policy: policy, now: now, fm: fm, onLine: onLine
            )
        }

        if let summariesDir {
            // WARNING: when mode == .delete this permanently removes durable trend summaries.
            // Both include_summaries and enabled must be explicitly opted into (both default false).
            acted += sweepDirectory(
                summariesDir, archiveSubpath: "summaries",
                archiveRoot: archiveRoot, policy: policy, now: now, fm: fm, onLine: onLine
            )
        }
        return acted
    }

    private static func sweepDirectory(
        _ dir: URL,
        archiveSubpath: String,
        archiveRoot: URL,
        policy: Policy,
        now: Date,
        fm: FileManager,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return 0 }

        let files: [(url: URL, modified: Date)] = entries.compactMap { url in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard vals?.isRegularFile == true, let modified = vals?.contentModificationDate
            else { return nil }
            return (url, modified)
        }
        guard !files.isEmpty else { return 0 }

        // Newest first → index == rank.
        let sorted = files.sorted { $0.modified > $1.modified }
        let cutoff = now.addingTimeInterval(-Double(policy.keepDays) * 86_400)

        var acted = 0
        for (rank, entry) in sorted.enumerated() {
            // Keep a file if EITHER rule protects it: within the count floor
            // (N newest) OR within the age horizon. Act only when neither does.
            let protectedByCount = policy.keepCount > 0 && rank < policy.keepCount
            let protectedByAge = policy.keepDays > 0 && entry.modified >= cutoff
            if protectedByCount || protectedByAge { continue }
            if act(on: entry.url, archiveSubpath: archiveSubpath, archiveRoot: archiveRoot,
                   policy: policy, fm: fm, onLine: onLine) {
                acted += 1
            }
        }
        return acted
    }

    /// Archive (move) or delete one file. Returns true on success.
    private static func act(
        on url: URL,
        archiveSubpath: String,
        archiveRoot: URL,
        policy: Policy,
        fm: FileManager,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> Bool {
        switch policy.mode {
        case .delete:
            do { try fm.removeItem(at: url); return true }
            catch {
                AppLogger.engine.warning(
                    "SnapshotRetentionService: delete failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        case .archive:
            let destDir = archiveRoot.appendingPathComponent(archiveSubpath, isDirectory: true)
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: url, to: dest)
                return true
            } catch {
                AppLogger.engine.warning(
                    "SnapshotRetentionService: archive failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }
    }
}
