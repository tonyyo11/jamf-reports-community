import Foundation

/// Trims jamf-cli snapshot directories to a configurable retention horizon.
///
/// Per-resource directory under `<profile>/jamf-cli-data/*/`: keeps the most
/// recent `minimumKeep` files AND everything from the last `minimumDays` days,
/// whichever set is larger. This prevents runaway disk growth on large fleets
/// (~30 GB/year on a 9,800-device fleet) while ensuring recent data is never
/// discarded even when all snapshots fall beyond the day horizon.
///
/// Call site: wire `sweep(profile:)` into the cold-tier completion handler
/// (e.g., `RefreshCoordinator`) guarded by a 24-hour per-profile cooldown.
/// The service itself has no timer — the caller is responsible for rate-limiting.
@MainActor
enum SnapshotRetentionService {

    // MARK: - Policy

    /// Retention parameters for a sweep run.
    struct Policy: Sendable {
        /// Always keep at least this many files per resource directory,
        /// regardless of age. Prevents sweeping all data when the profile
        /// has been dormant for longer than `minimumDays`.
        var minimumKeep: Int = 30

        /// Also keep every file modified within this many days.
        /// Files older than this threshold AND beyond `minimumKeep` rank are removed.
        var minimumDays: Int = 90

        static let `default` = Policy()
    }

    // MARK: - Public API

    /// Sweeps all resource subdirectories under `<profile>/jamf-cli-data/`,
    /// trimming files that are both older than `policy.minimumDays` AND ranked
    /// beyond `policy.minimumKeep` (by descending modification date).
    ///
    /// - Parameters:
    ///   - profile: The workspace profile name. Must satisfy `ProfileService.isValid`.
    ///   - policy: Retention thresholds. Defaults to `.default` (30 files / 90 days).
    /// - Returns: Total number of files removed across all resource subdirectories.
    /// - Throws: `RetentionError.invalidProfile` when `profile` fails validation.
    ///           Filesystem errors from individual file removals are caught per-file
    ///           and logged; they do not abort the sweep.
    @discardableResult
    static func sweep(profile: String, policy: Policy = .default) throws -> Int {
        guard ProfileService.isValid(profile) else {
            throw RetentionError.invalidProfile(profile)
        }

        let dataDir = try WorkspacePaths.dataDir(for: profile)

        let fm = FileManager.default
        guard fm.fileExists(atPath: dataDir.path) else { return 0 }

        let subdirs = (try? fm.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []

        var totalRemoved = 0
        for subdir in subdirs {
            guard (try? subdir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            totalRemoved += sweepDirectory(subdir, policy: policy, fm: fm)
        }
        return totalRemoved
    }

    // MARK: - Errors

    enum RetentionError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p):
                "SnapshotRetentionService: '\(p)' is not a valid profile name."
            }
        }
    }

    // MARK: - Private

    private static func sweepDirectory(
        _ dir: URL,
        policy: Policy,
        fm: FileManager
    ) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return 0 }

        // Collect regular files with their modification dates.
        let files: [(url: URL, modified: Date)] = entries.compactMap { url in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard vals?.isRegularFile == true,
                  let modified = vals?.contentModificationDate
            else { return nil }
            return (url, modified)
        }

        guard !files.isEmpty else { return 0 }

        // Sort newest-first so index position == rank (0 = newest).
        let sorted = files.sorted { $0.modified > $1.modified }
        let cutoff = Date().addingTimeInterval(-Double(policy.minimumDays) * 86_400)

        var removed = 0
        for (rank, entry) in sorted.enumerated() {
            // Keep if within the minimum-keep count (rank is 0-based).
            if rank < policy.minimumKeep { continue }
            // Keep if within the day horizon.
            if entry.modified >= cutoff { continue }
            // Both conditions failed — remove.
            do {
                try fm.removeItem(at: entry.url)
                removed += 1
            } catch {
                AppLogger.engine.warning(
                    "SnapshotRetentionService: could not remove \(entry.url.lastPathComponent): \(error)"
                )
            }
        }
        return removed
    }
}
