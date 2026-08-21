import Foundation

/// Cloud-sync awareness for workspace paths and filenames.
///
/// The workspace is designed as a local, single-writer store. Operators
/// nonetheless host it — or at least the generated reports — on OneDrive,
/// SharePoint, Box, Dropbox, iCloud Drive, or a mounted share so a team can
/// read the output. Two provider behaviours break assumptions elsewhere in
/// the codebase:
///
/// - **mtimes lie.** A file provider re-stamps modification dates when it
///   materializes or syncs a file, so "newest by mtime" disagrees with
///   "newest by the timestamp in the filename". Readers must order by name.
/// - **conflicting writes fork the file.** Two machines writing one path
///   produce sibling copies (`summary_2026-08-20 2.json`,
///   `computers_… (1).json`, `… (Mac's conflicted copy 2026-08-20).json`).
///   Those parse as valid JSON and would be ingested as real data.
///
/// `snapshotTimestamp` is the defence: our writers always stamp a filename
/// with `yyyyMMddTHHmmss`, so *requiring* that stamp rejects every provider's
/// mangled copy without maintaining a per-provider blacklist that would drift.
/// `isLikelySyncConflict` is diagnostics only — it names the pattern for the
/// operator, and a false negative there is harmless because no ordering
/// decision depends on it.
enum CloudStorage {

    // MARK: - Filename canonicality

    // Configuration is inherited verbatim from the MSCPChartDataBuilder statics
    // these replaced: POSIX locale, iso8601 calendar, and NO explicit time zone
    // so both stamps resolve in local time. Do not pin a zone here — every
    // day-bucketing caller assumes local, and changing it would silently shift
    // which calendar day an existing snapshot belongs to.
    private static let snapshotStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        return f
    }()

    private static let dashedStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        return f
    }()

    /// Strict timestamp for a snapshot filename stem (`ea-results_20240615T120000`),
    /// or the Python-era dashed form. Returns nil — never an mtime fallback —
    /// when the stem carries no canonical stamp, which is exactly what a sync
    /// conflict copy looks like.
    static func snapshotTimestamp(stem: String) -> Date? {
        if let range = stem.range(of: #"\d{8}T\d{6}$"#, options: .regularExpression) {
            return snapshotStampFormatter.date(from: String(stem[range]))
        }
        if let range = stem.range(of: #"\d{4}-\d{2}-\d{2}T\d{6}$"#, options: .regularExpression) {
            return dashedStampFormatter.date(from: String(stem[range]))
        }
        // Dashed form with trailing microseconds: ...T210038673146
        if let range = stem.range(of: #"\d{4}-\d{2}-\d{2}T\d{6}\d*$"#, options: .regularExpression) {
            let match = String(stem[range])
            return dashedStampFormatter.date(from: String(match.prefix(17)))
        }
        return nil
    }

    /// Convenience over a file URL.
    static func snapshotTimestamp(of url: URL) -> Date? {
        snapshotTimestamp(stem: url.deletingPathExtension().lastPathComponent)
    }

    /// Timestamp leading a backup directory name (`20260820T060000`), plus the
    /// `-N` disambiguator `CLIBridge.uniqueBackupDirectoryName` appends when two
    /// backups land in the same second. Returns nil for any name that is not a
    /// canonical backup directory — the caller must treat that as "cannot order
    /// safely", never as "oldest".
    static func backupDirectoryTimestamp(name: String) -> (date: Date, sequence: Int)? {
        guard let range = name.range(of: #"^\d{8}T\d{6}"#, options: .regularExpression),
              let date = snapshotStampFormatter.date(from: String(name[range])) else {
            return nil
        }
        let rest = String(name[range.upperBound...])
        if rest.isEmpty { return (date, 0) }
        guard let seqRange = rest.range(of: #"^-\d+$"#, options: .regularExpression) else {
            return nil
        }
        let digits = rest[seqRange].dropFirst()
        return (date, Int(digits) ?? 0)
    }

    /// Canonical `summary_yyyy-MM-dd.json` name. A conflict copy
    /// (`summary_2026-08-20 2.json`) fails, which keeps duplicate daily
    /// summaries out of the trend store.
    static func isCanonicalSummaryFilename(_ name: String) -> Bool {
        name.range(of: #"^summary_\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil
    }

    /// Best-effort recognition of a sync provider's conflict/duplicate copy.
    /// Diagnostics only — used to tell the operator what it found. Ordering
    /// never depends on this; it depends on the canonical-name requirement.
    static func isLikelySyncConflict(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        let patterns = [
            #"\s\d+$"#,                  // Finder / OneDrive: "name 2"
            #"\s\(\d+\)$"#,              // Box / browser downloads: "name (1)"
            #"\scopy(\s\d+)?$"#,         // Finder duplicate: "name copy", "name copy 2"
            #"conflicted copy"#,         // Dropbox
            #"\(.*conflict.*\)$"#,       // generic provider conflict marker
        ]
        for pattern in patterns
        where stem.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    // MARK: - Volume / provider detection

    enum Provider: String, Sendable {
        case oneDrive
        case iCloudDrive
        case dropbox
        case box
        case googleDrive
        case otherFileProvider
        case detachedVolume

        var displayName: String {
            switch self {
            case .oneDrive: "OneDrive / SharePoint"
            case .iCloudDrive: "iCloud Drive"
            case .dropbox: "Dropbox"
            case .box: "Box"
            case .googleDrive: "Google Drive"
            case .otherFileProvider: "a cloud-sync folder"
            case .detachedVolume: "a mounted volume"
            }
        }
    }

    /// The sync provider backing `url`, or nil when it is on ordinary local
    /// storage. Purely path-shape based (no I/O beyond a volume-local probe),
    /// so it is safe to call from a config-validation path.
    static func provider(for url: URL) -> Provider? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = NSString(string: "~").expandingTildeInPath

        if let range = path.range(of: "/Library/CloudStorage/") {
            let tail = String(path[range.upperBound...])
            let folder = tail.split(separator: "/").first.map(String.init) ?? tail
            return providerForCloudStorageFolder(folder)
        }
        if path.hasPrefix("\(home)/Library/Mobile Documents/") { return .iCloudDrive }
        if path == "\(home)/Dropbox" || path.hasPrefix("\(home)/Dropbox/") { return .dropbox }
        if path == "\(home)/Box" || path.hasPrefix("\(home)/Box/") { return .box }
        if path.hasPrefix("/Volumes/") { return .detachedVolume }
        return nil
    }

    private static func providerForCloudStorageFolder(_ folder: String) -> Provider {
        let lower = folder.lowercased()
        if lower.hasPrefix("onedrive") || lower.hasPrefix("sharepoint") { return .oneDrive }
        if lower.hasPrefix("dropbox") { return .dropbox }
        if lower.hasPrefix("box") { return .box }
        if lower.hasPrefix("googledrive") { return .googleDrive }
        if lower.hasPrefix("icloud") { return .iCloudDrive }
        return .otherFileProvider
    }

    /// Names of files in `dir` that look like a provider's conflict copy.
    /// Non-recursive, best-effort; an unreadable directory yields `[]`.
    static func conflictCopies(in dir: URL, fileManager: FileManager = .default) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .map(\.lastPathComponent)
            .filter(isLikelySyncConflict)
            .sorted()
    }
}
