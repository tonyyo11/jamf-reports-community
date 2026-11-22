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
/// `snapshotTimestamp` is the primary defence: our writers always stamp a
/// filename with `yyyyMMddTHHmmss`, so *requiring* that stamp rejects every
/// provider's mangled copy without maintaining a per-provider blacklist that
/// would drift. `isLikelySyncConflict` is the second: every snapshot picker
/// runs it as a filter (`FileManager.isSelectableSnapshot`) before ordering,
/// so a conflict copy is dropped outright rather than ranked. It also names
/// the pattern for the operator in the Config Doctor.
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
        if let range = stem.range(
            of: #"\d{4}-\d{2}-\d{2}T\d{6}\d*$"#, options: .regularExpression
        ) {
            let match = String(stem[range])
            return dashedStampFormatter.date(from: String(match.prefix(17)))
        }
        return nil
    }

    /// Convenience over a file URL.
    static func snapshotTimestamp(of url: URL) -> Date? {
        snapshotTimestamp(stem: url.deletingPathExtension().lastPathComponent)
    }

    /// Backup folder names are UTC (`CLIBridge.backup` builds them from `ISO8601Time`), unlike
    /// snapshot names, so they get their own formatter; `BackupRecord.dateInName` reads them
    /// the same way.
    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Timestamp leading a backup directory name (`20260820T060000`, UTC), plus the
    /// `-N` disambiguator `CLIBridge.uniqueBackupDirectoryName` appends when two
    /// backups land in the same second. Returns nil for any name that is not a
    /// canonical backup directory — the caller must treat that as "cannot order
    /// safely", never as "oldest".
    static func backupDirectoryTimestamp(name: String) -> (date: Date, sequence: Int)? {
        guard let range = name.range(of: #"^\d{8}T\d{6}"#, options: .regularExpression),
              let date = backupStampFormatter.date(from: String(name[range])) else {
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

    /// Local midnight of the date in a canonical `summary_yyyy-MM-dd.json` name, else nil.
    /// Local time, like `snapshotTimestamp`, so both put a file on the same calendar day.
    static func summaryDate(of url: URL) -> Date? {
        let name = url.lastPathComponent
        guard isCanonicalSummaryFilename(name) else { return nil }
        let day = String(name.dropFirst("summary_".count).prefix(10))
        // DateFormatter rolls 2026-02-31 over to March 3; only a date that formats back to the
        // same text is a real one.
        guard let date = summaryDayFormatter.date(from: day),
              summaryDayFormatter.string(from: date) == day else { return nil }
        return date
    }

    private static let summaryDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        return f
    }()

    /// Best-effort recognition of a sync provider's conflict/duplicate copy.
    /// Applied as a filter by every snapshot picker (via
    /// `FileManager.isSelectableSnapshot`) *and* surfaced to the operator by
    /// the Config Doctor. Best-effort is acceptable because the canonical-name
    /// requirement in `snapshotTimestamp` already demotes anything this misses.
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
        /// A folder outside iCloud Drive's own path that iCloud syncs: Desktop and Documents.
        case iCloudDesktopAndDocuments
        case otherFileProvider
        case detachedVolume

        var displayName: String {
            switch self {
            case .oneDrive: "OneDrive / SharePoint"
            case .iCloudDrive: "iCloud Drive"
            case .dropbox: "Dropbox"
            case .box: "Box"
            case .googleDrive: "Google Drive"
            case .iCloudDesktopAndDocuments: "iCloud Desktop & Documents"
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

    /// Why a folder counts as shared with other Macs.
    enum SharedStorage: Equatable, Sendable {
        case provider(Provider)
        case networkVolume
        /// A sync daemon's marker file sits in the folder or one of its ancestors.
        case syncMarker(String)

        /// Where the folder is, for "on …" wording: the provider's name when one is known.
        var displayName: String {
            switch self {
            case .provider(let provider): provider.displayName
            case .networkVolume: "a network volume"
            case .syncMarker: "a folder a sync tool manages"
            }
        }
    }

    /// `URLResourceValues.volumeIsLocal`; nil when the volume cannot be asked. The default of
    /// the `volumeIsLocal` parameters, so a test can stand in for an NFS mount.
    @Sendable
    static func isOnLocalVolume(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
    }

    /// File names a sync daemon leaves in the folders it syncs: Syncthing, Nextcloud and
    /// ownCloud, Resilio. `.sync_<id>.db` and `._sync_<id>.db` are Nextcloud's journal.
    private static let syncMarkerNames: Set<String> = [
        ".stfolder", ".stignore", ".nextcloudsync.log", ".owncloudsync.log", ".sync",
    ]

    private static func isSyncMarker(_ name: String) -> Bool {
        syncMarkerNames.contains(name)
            || ((name.hasPrefix(".sync_") || name.hasPrefix("._sync_")) && name.hasSuffix(".db"))
    }

    /// Entry names in `path`, hidden ones included. `readdir` rather than `FileManager`, which
    /// leaves out `._` names, the form of Nextcloud's `._sync_<id>.db`.
    private static func entryNames(in path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            names.append(name)
        }
        return names
    }

    /// `url` and its ancestors, nearest first. The walk stops below the home folder (never home
    /// itself or above), and outside home below the root's own children, so a stray
    /// `~/.stignore` or an attribute on home does not make every workspace shared.
    private static func foldersBelowHome(from url: URL, home: URL) -> [URL] {
        let homePaths = Set([home.standardizedFileURL.path, home.resolvingSymlinksInPath().path])
        var folders: [URL] = []
        var folder = url.resolvingSymlinksInPath().standardizedFileURL
        while folder.path.split(separator: "/").count > 1, !homePaths.contains(folder.path) {
            folders.append(folder)
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        return folders
    }

    /// The marker found in `url` or an ancestor below home, nil when there is none.
    private static func syncMarker(in url: URL, home: URL) -> String? {
        foldersBelowHome(from: url, home: home).lazy
            .compactMap { entryNames(in: $0.path).first(where: isSyncMarker) }.first
    }

    /// How a folder outside a provider's own path is found to sync: the File Provider domain
    /// attribute macOS sets on a synced folder (iCloud Desktop & Documents sets it on `~/Desktop`
    /// and `~/Documents`), or `isUbiquitousItem`. Closures so a test can stand in for both: the
    /// attribute is kernel-protected and ubiquity cannot be set on disk.
    struct SyncProbe: Sendable {
        /// The folder's own `com.apple.file-provider-domain-id`, not followed through a link;
        /// nil when absent or unreadable, "" when present with a value that cannot be read.
        var fileProviderDomain: @Sendable (URL) -> String?
        var isUbiquitous: @Sendable (URL) -> Bool

        static let live = SyncProbe(
            fileProviderDomain: CloudStorage.fileProviderDomain(of:),
            isUbiquitous: {
                (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            })
    }

    @Sendable
    static func fileProviderDomain(of folder: URL) -> String? {
        let name = "com.apple.file-provider-domain-id"
        let size = getxattr(folder.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(folder.path, name, &bytes, size, 0, XATTR_NOFOLLOW)
        return read >= 0 ? String(decoding: bytes.prefix(read), as: UTF8.self) : ""
    }

    /// The provider syncing `url` or an ancestor below home by the probe's signals, nil when
    /// neither says so. Only a positive signal counts: an unreadable folder is not synced.
    private static func fileProviderFolder(
        _ url: URL, home: URL, probe: SyncProbe
    ) -> Provider? {
        for folder in foldersBelowHome(from: url, home: home) {
            if let domain = probe.fileProviderDomain(folder) {
                return domain.hasPrefix("com.apple.CloudDocs")
                    ? .iCloudDesktopAndDocuments : .otherFileProvider
            }
            if probe.isUbiquitous(folder) { return .iCloudDesktopAndDocuments }
        }
        return nil
    }

    /// Whether other Macs can write `url`: a sync-provider path, a folder a File Provider syncs
    /// (iCloud Desktop & Documents, `SyncProbe`), a volume that is not local (NFS, SMB or autofs
    /// outside `/Volumes`, probed on the symlink-resolved path), or a sync daemon's marker file
    /// in the folder or an ancestor below home. A tool that leaves no marker is not found;
    /// `shared_workspace.enabled: true` covers it.
    static func sharedStorage(
        for url: URL,
        volumeIsLocal: @Sendable (URL) -> Bool? = CloudStorage.isOnLocalVolume,
        syncProbe: SyncProbe = .live,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SharedStorage? {
        if let provider = provider(for: url) { return .provider(provider) }
        if let provider = fileProviderFolder(url, home: home, probe: syncProbe) {
            return .provider(provider)
        }
        if volumeIsLocal(url.resolvingSymlinksInPath()) == false { return .networkVolume }
        return syncMarker(in: url, home: home).map { .syncMarker($0) }
    }

    static func isSharedStorage(
        _ url: URL,
        volumeIsLocal: @Sendable (URL) -> Bool? = CloudStorage.isOnLocalVolume,
        syncProbe: SyncProbe = .live,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        sharedStorage(for: url, volumeIsLocal: volumeIsLocal, syncProbe: syncProbe, home: home)
            != nil
    }

    /// The provider `sharedStorage` names for `url`, by path or by `SyncProbe`; nil for local
    /// storage, a network volume or a sync marker, which have no provider name.
    static func syncProvider(for url: URL, syncProbe: SyncProbe = .live) -> Provider? {
        guard case .provider(let provider)? = sharedStorage(for: url, syncProbe: syncProbe)
        else { return nil }
        return provider
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
