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
        guard let newestMTime = newestSnapshotMTime(in: dataDir) else {
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

    /// Find the newest modification time across all regular files in `dataDir` and its
    /// subdirectories. Hidden files and directories themselves are excluded.
    ///
    /// - Returns: The most recent modification date, or nil if no regular files exist.
    nonisolated static func newestSnapshotMTime(in dataDir: URL) -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newestDate: Date?
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
            values.isRegularFile == true,
            let mtime = values.contentModificationDate else {
                continue
            }

            if let current = newestDate {
                if mtime > current { newestDate = mtime }
            } else {
                newestDate = mtime
            }
        }

        return newestDate
    }
}
