import Foundation

/// Evaluates whether jamf-cli snapshot data is fresh enough to skip a collect run.
///
/// The full-tree file enumeration is intentionally a complete directory scan;
/// at current scale (hundreds of JSON files per workspace) this is fast and
/// acceptable to run on a background Task before each Generate click.
enum SnapshotFreshness {

    enum Decision: Sendable {
        /// Newest snapshot is younger than the freshness threshold.
        case fresh(ageMinutes: Int)
        /// Newest snapshot is at or older than the freshness threshold.
        case stale(ageMinutes: Int)
        /// No regular files found in the data directory (or directory absent).
        case noSnapshots
    }

    /// Evaluate freshness of snapshots in `dataDir`.
    ///
    /// - Parameters:
    ///   - dataDir: The workspace's jamf-cli-data directory URL.
    ///   - threshold: Age in seconds below which snapshots are considered fresh. Default 3600 (1 hour).
    ///   - now: The reference instant to measure age against. Defaults to `Date()`. Injected for testing.
    /// - Returns: A `Decision` reflecting the age of the newest regular file found.
    static func evaluate(
        dataDir: URL,
        threshold: TimeInterval = 3600,
        now: Date = Date()
    ) -> Decision {
        guard let newestMTime = newestSnapshotMTime(in: dataDir, now: now) else {
            return .noSnapshots
        }

        let age = now.timeIntervalSince(newestMTime)
        let ageMinutes = Int(age / 60)

        if age < threshold {
            return .fresh(ageMinutes: ageMinutes)
        } else {
            return .stale(ageMinutes: ageMinutes)
        }
    }

    /// `evaluate(dataDir:)` for `profile`'s data directory; no snapshots for a name that is not
    /// a profile or whose data directory does not resolve.
    static func evaluate(profile: String) -> Decision {
        guard ProfileService.isValid(profile),
              let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return .noSnapshots }
        return evaluate(dataDir: dataDir)
    }

    /// The date of the newest snapshot file in `dataDir` and its subdirectories, picked as every
    /// freshness check picks one (`FileManager.newestSnapshotDate`): a manifest, a sync-conflict
    /// copy, a `.partial` file, a link or a file dated far ahead of `now` does not count. Hidden
    /// files and directories are excluded.
    ///
    /// - Returns: The newest date, or nil if no such file exists.
    nonisolated static func newestSnapshotMTime(in dataDir: URL, now: Date = Date()) -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: dataDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = enumerator.compactMap { $0 as? URL }
        return FileManager.newestSnapshotDate(among: files, now: now)
    }
}
