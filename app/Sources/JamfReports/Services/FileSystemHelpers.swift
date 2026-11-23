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

    /// Newest `.html` snapshot in `dir`, by the same rule. jamf-cli's `dashboard`
    /// is the one kind saved as a page rather than JSON.
    static func newestHTMLSnapshot(in dir: URL) -> URL? {
        newestSnapshot(inDirectory: dir, extensions: ["html"])
    }

    /// "<name>: not a regular file" when the newest `fileExtension` entry by stamp in `dir` is a
    /// link, folder or other non-regular file. The pickers above drop a link that resolves
    /// outside `dir`, so one planted at the newest stamp would read as "never collected"; a
    /// caller that claims something about the cache (the collect's "using cached" note, the
    /// dashboard section) asks this first. A screen that only reads data keeps the drop: a
    /// refused link is not data. A link that stays inside `dir` is reported too, though the
    /// pickers would have resolved it: nothing here writes one. The listing follows a folder
    /// swapped for a link after the caller confined it; nothing is opened, only the newest name
    /// is read.
    static func plantedNewestSnapshot(in dir: URL, fileExtension: String) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let newest = newestSnapshot(
                among: entries.filter { $0.pathExtension.lowercased() == fileExtension }),
              !isRegularFile(newest) else { return nil }
        return ConfigSchema.displayText(newest.lastPathComponent) + ": not a regular file"
    }

    /// `lstat`, so a link is not followed.
    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// The date of the newest snapshot among `urls`, as every freshness check dates it: regular
    /// files only (`lstat`, so a planted link counts for nothing), the pickers' exclusions
    /// (manifest, conflict copy, `.partial`), the stamp in the name before the mtime, and a file
    /// dated more than `SharedWorkspace.clockSkewTolerance` ahead of `now` left out, since a peer
    /// can name or touch one for the year 2999 and make a folder look fresh for good.
    static func newestSnapshotDate(among urls: [URL], now: Date = Date()) -> Date? {
        let candidates = urls.filter { url in
            guard isRegularFile(url), let date = snapshotDate(of: url) else { return false }
            return date.timeIntervalSince(now) <= SharedWorkspace.clockSkewTolerance
        }
        return newestSnapshot(among: candidates).flatMap(snapshotDate(of:))
    }

    /// Shared body: enumerate, confine to `dir`, filter, order. The candidate comes back as
    /// `dir` as given plus the entry's name, never as the resolved target, so a link at the
    /// newest name reaches the reader as a link and is refused there (`BoundedFile` opens with
    /// `O_NOFOLLOW`). A `dir` that is itself a link is no snapshot folder at all.
    private static func newestSnapshot(inDirectory dir: URL, extensions: Set<String>) -> URL? {
        guard let files = snapshotFolderEntries(in: dir) else { return nil }
        let dirPrefix = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let confined = files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .filter {
                $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(dirPrefix)
            }
            .map { dir.appendingPathComponent($0.lastPathComponent) }
        return newestSnapshot(among: confined)
    }

    /// The entries of a snapshot kind folder: nil when `dir` is missing, unreadable or itself a
    /// link, so every listing of a kind folder applies the one rule the pickers do. (The data
    /// folder above the kind folders may be a link; a kind folder may not.)
    static func snapshotFolderEntries(
        in dir: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = [.contentModificationDateKey],
        options: DirectoryEnumerationOptions = [.skipsHiddenFiles]
    ) -> [URL]? {
        guard !isLink(dir) else { return nil }
        return try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: options)
    }

    /// `lstat` says `url` is a symbolic link.
    static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
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
