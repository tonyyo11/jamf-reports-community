import Foundation

/// Filesystem utilities shared across workspace-reading services.
///
/// Every snapshot picker in the app resolves "newest" through this one rule.
/// It used to be duplicated: four readers (`CoreDashboard.loadLatestJSONData`,
/// `HtmlReport.loadJSON`, the Protect picker, `DeviceInventoryService`) kept
/// their own mtime-ordered copies, so on a synced workspace — where the
/// provider re-stamps mtimes and leaves `… 2.json` conflict copies — the
/// workbook and the dashboards read different days with no error shown.
extension FileManager {

    /// Returns the URL of the newest `.json` file in `dir`, or nil if the
    /// directory doesn't exist, can't be read, or contains no JSON files.
    /// Skips hidden files.
    ///
    /// Epic #103: entries are canonicalized and must stay inside `dir`, so a
    /// symlink planted in a snapshot directory cannot point readers at a file
    /// outside the workspace.
    static func newestJSONFile(in dir: URL) -> URL? {
        newestSnapshot(inDirectory: dir, extensions: ["json"])
    }

    /// Newest snapshot file in `dir`. Same rule as `newestJSONFile` — the two
    /// names are kept because callers read differently (one is "any JSON in
    /// this dir", the other "the snapshot for this kind"), but they must never
    /// disagree about which file is newest.
    static func newestSnapshotFile(in dir: URL) -> URL? {
        newestSnapshot(inDirectory: dir, extensions: ["json"])
    }

    /// Shared body: enumerate, confine to `dir`, filter, order.
    private static func newestSnapshot(inDirectory dir: URL, extensions: Set<String>) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirPrefix = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let confined = files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> URL? in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(dirPrefix) ? resolved : nil
            }
        return newestSnapshot(among: confined)
    }

    /// Newest of an arbitrary candidate list, applying the same exclusions and
    /// the same ordering. Readers that assemble candidates themselves (several
    /// scan a kind subdirectory *and* a flat `<kind>_*.json` pattern) call this
    /// so they cannot drift from the directory helpers above.
    static func newestSnapshot(among urls: [URL]) -> URL? {
        urls.filter(isSelectableSnapshot).max { isOlderSnapshot($0, than: $1) }
    }

    /// Filename-level exclusions every snapshot picker applies before ordering.
    ///
    /// - `manifest.json` is integrity metadata, never data — and `ReportEngine`
    ///   writes it *after* the snapshot it describes, so it is always the newest
    ///   `.json` by mtime. Without this, enabling `jamf_cli.require_manifest`
    ///   would resolve every kind to the manifest and read zero rows.
    /// - A sync provider's conflict copy (`computers_… 2.json`) parses as valid
    ///   JSON and carries a fresh mtime, so it would outrank the real snapshot.
    /// - A `.partial` file is a staging artifact of an interrupted write.
    static func isSelectableSnapshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.lowercased() != SnapshotManifest.fileName
            && !name.contains(".partial")
            && !CloudStorage.isLikelySyncConflict(name)
    }

    /// Ordering for every snapshot picker: the canonical timestamp in the
    /// FILENAME wins, because on a synced volume the file provider re-stamps
    /// mtimes when it materializes a file. A stamped file always beats an
    /// unstamped one, and mtime only separates two files that both lack a stamp
    /// — which preserves the prior behaviour for non-snapshot directories and
    /// for the inventory CSV, whose export names carry no canonical stamp.
    /// (Bool isn't Comparable, so this can't be a tuple compare.)
    static func isOlderSnapshot(_ lhs: URL, than rhs: URL) -> Bool {
        let l = CloudStorage.snapshotTimestamp(of: lhs)
        let r = CloudStorage.snapshotTimestamp(of: rhs)
        switch (l, r) {
        case let (.some(a), .some(b)):
            return a == b ? snapshotMTime(lhs) < snapshotMTime(rhs) : a < b
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.none, .none):
            return snapshotMTime(lhs) < snapshotMTime(rhs)
        }
    }

    /// The date a snapshot file represents: its filename stamp when it has one,
    /// mtime only when it does not. Freshness captions read this so they cannot
    /// report a sync re-stamp as the collection time of the file being rendered.
    static func snapshotDate(of url: URL) -> Date? {
        CloudStorage.snapshotTimestamp(of: url)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
    }

    private static func snapshotMTime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
