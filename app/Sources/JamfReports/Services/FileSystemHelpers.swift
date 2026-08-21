import Foundation

/// Filesystem utilities shared across workspace-reading services.
extension FileManager {

    /// Returns the URL of the newest `.json` file in `dir`, or nil if the
    /// directory doesn't exist, can't be read, or contains no JSON files.
    /// Skips hidden files.
    ///
    /// Epic #103: entries are canonicalized and must stay inside `dir`, so a
    /// symlink planted in a snapshot directory cannot point readers at a file
    /// outside the workspace.
    ///
    /// "Newest" is the timestamp in the FILENAME, not the mtime: on a synced
    /// volume the file provider re-stamps mtimes, so an mtime-ordered pick
    /// disagreed with the filename-ordered readers (`newestSnapshotFile`,
    /// `MSCPChartDataBuilder`) reading the same directory — two dashboards,
    /// two different days, no error shown. mtime survives only as a tiebreak
    /// among files that carry no canonical stamp at all, which preserves the
    /// prior behaviour for non-snapshot directories.
    ///
    /// Sync-conflict copies (`computers_… 2.json`) are dropped outright: they
    /// carry no canonical stamp, so ranking them by their fresh sync mtime
    /// would promote a duplicate over the real snapshot.
    static func newestJSONFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirPrefix = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return files
            .filter { $0.pathExtension == "json" }
            // manifest.json is integrity metadata, never a snapshot. Without this
            // the 2.6 SnapshotManifest.record writer's manifest.json (always newest
            // by mtime after a collect) would be returned as "newest" to all ~15
            // newestJSONFile consumers, emptying their dashboards. Matches
            // newestSnapshotFile's exclusion form.
            .filter { $0.lastPathComponent.lowercased() != SnapshotManifest.fileName }
            .filter { !CloudStorage.isLikelySyncConflict($0.lastPathComponent) }
            .compactMap { url -> URL? in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(dirPrefix) ? resolved : nil
            }
            .max { lhs, rhs in isOlder(lhs, than: rhs) }
    }

    /// Ordering for the `newest*` helpers: a canonical filename stamp always
    /// beats a file without one, and mtime only separates two files that both
    /// lack a stamp (Bool isn't Comparable, so this can't be a tuple compare).
    private static func isOlder(_ lhs: URL, than rhs: URL) -> Bool {
        let l = CloudStorage.snapshotTimestamp(of: lhs)
        let r = CloudStorage.snapshotTimestamp(of: rhs)
        switch (l, r) {
        case let (.some(a), .some(b)):
            return a == b ? mtime(lhs) < mtime(rhs) : a < b
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.none, .none):
            return mtime(lhs) < mtime(rhs)
        }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Newest snapshot file in `dir`, chosen by the parsed filename timestamp
    /// (`dateFromSnapshotFilename`, mtime fallback) rather than raw mtime, and
    /// excluding `manifest.json`. Use this for snapshot-KIND dirs so accuracy
    /// checks read the same day as the chart/drift builders on synced storage
    /// where mtimes lie. Symlink confinement matches `newestJSONFile`.
    static func newestSnapshotFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirPrefix = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return files
            .filter { $0.pathExtension == "json" }
            .filter { $0.lastPathComponent.lowercased() != "manifest.json" }
            .filter { !CloudStorage.isLikelySyncConflict($0.lastPathComponent) }
            .compactMap { url -> URL? in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(dirPrefix) ? resolved : nil
            }
            .max { lhs, rhs in isOlder(lhs, than: rhs) }
    }
}
