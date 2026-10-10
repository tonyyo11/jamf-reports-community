import Foundation

/// Housekeeping for the workspace `backups/` directory:
///
/// - **Retention**: scheduled backups (label prefix `scheduled-`) beyond the
///   newest `defaultKeepCount` are pruned after each scheduled backup run.
///   Manual backups (created from BackupsView, any other label) are never
///   touched — deleting an operator's named backup is not housekeeping.
/// - **Stale temp cleanup**: `CLIBridge.backup` stages into `.tmp-<UUID>`
///   before its atomic rename. An interrupted run (crash, force-quit, jamf-cli
///   hang) strands that directory; production showed one months old. Anything
///   matching the pattern and older than 24 hours is safe to delete.
enum BackupMaintenance {

    /// Scheduled backups kept per profile (mirrors `output.keep_latest_runs`).
    static let defaultKeepCount = 10

    /// Age past which an orphaned `.tmp-*` staging dir is considered abandoned.
    static let staleTempAge: TimeInterval = 86_400  // 24 hours

    /// `URLResourceValues.volumeIsLocal`; nil when the volume cannot be asked. The default of
    /// the `volumeIsLocal` parameters below, so a test can stand in for an NFS mount.
    @Sendable
    static func isOnLocalVolume(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
    }

    /// The profile's `shared_workspace.enabled`: true when set to true, or when config.yaml
    /// exists but cannot be loaded. False when there is no config.yaml.
    private static func sharedWorkspaceEnabled(profile: String) -> Bool {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return false }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }
        do {
            let config = try ConfigLoader.load(from: configURL)
            // The same tri-state `ReportEngine.coordinationGate` reads; only an explicit
            // true counts here, the auto case is the path check below.
            return config.sharedWorkspace?.isEnabled(workspaceIsSynced: false) ?? false
        } catch {
            // A config that exists but will not load may still say the folder is shared.
            // Reading that as "not shared" would unscope the prune and could delete another
            // Mac's backups; keeping more is the safe failure.
            AppLogger.collect.warning(
                "BackupMaintenance: config.yaml unreadable, treating storage as shared")
            return true
        }
    }

    /// Why `backupsRoot` counts as shared with other Macs, or nil for local storage.
    /// A sync-provider path, a volume that is not local (NFS or autofs outside `/Volumes`)
    /// and `shared_workspace.enabled: true` each suffice: pruning wrongly scoped to this Mac
    /// only keeps backups, while pruning wrongly unscoped deletes another Mac's.
    private static func sharedStorageDescription(
        _ backupsRoot: URL, profile: String,
        volumeIsLocal: @Sendable (URL) -> Bool?
    ) -> String? {
        if let provider = CloudStorage.provider(for: backupsRoot) {
            return "on \(provider.displayName)"
        }
        if volumeIsLocal(backupsRoot) == false { return "on a network volume" }
        if sharedWorkspaceEnabled(profile: profile) { return "in a shared workspace" }
        return nil
    }

    /// `yyyyMMdd` stamp for scheduled-backup labels.
    static func dateStamp(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: now)
    }

    /// Delete scheduled backups beyond the newest `keep`, oldest first.
    ///
    /// "Scheduled" is determined by the manifest.json label having the
    /// `scheduled-` prefix — directory names are timestamps and carry no
    /// origin information.
    ///
    /// This is the only unconditional `removeItem` in the app's housekeeping,
    /// so it is deliberately fail-safe in three ways:
    ///
    /// 1. **Ordering comes from the directory NAME**, never mtime. The names
    ///    are `yyyyMMddTHHmmss`; a sync provider re-stamps directory mtimes
    ///    when it materializes children, which would scramble the sort and
    ///    delete the newest backups instead of the oldest.
    /// 2. **Any unparseable name aborts the whole prune.** If we cannot order
    ///    every candidate confidently we delete none of them — growing the
    ///    backups directory is recoverable, deleting the wrong one is not.
    /// 3. **On shared storage, only this machine's own backups are pruned.**
    ///    A shared folder holds every Mac's backups, so an unscoped prune would
    ///    spend this machine's `keep` budget on other people's work and cut
    ///    everyone's retention. Shared means a sync-provider path, a non-local volume or
    ///    `shared_workspace.enabled: true` . Ownership comes from the
    ///    `.jrc-host` stamp written beside each backup; anything without one — a pre-2.7.0
    ///    backup, or another Mac's — is left alone, because we only delete what
    ///    we can prove is ours. Local storage keeps the original unscoped
    ///    behaviour: there is one writer by definition, and scoping it would
    ///    silently stop pruning every existing single-Mac install.
    static func pruneScheduledBackups(
        profile: String,
        keep: Int,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil,
        volumeIsLocal: @Sendable (URL) -> Bool? = BackupMaintenance.isOnLocalVolume
    ) {
        guard let backupsRoot = backupsRoot(for: profile) else { return }
        let sharedWhere = sharedStorageDescription(
            backupsRoot, profile: profile, volumeIsLocal: volumeIsLocal)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var candidates = entries.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDir && manifestLabel(of: url)?.hasPrefix("scheduled-") == true
        }

        if let sharedWhere {
            let mine = candidates.filter { ownerHostID(of: $0) == SharedWorkspace.currentHost.id }
            let others = candidates.count - mine.count
            if others > 0 {
                onLine?(.init(
                    timestamp: Date(), level: .info,
                    text: "[info] backups are \(sharedWhere) — pruning only this "
                        + "Mac's \(mine.count) scheduled backup(s); leaving \(others) belonging "
                        + "to another machine (or made before ownership was recorded)."
                ))
            }
            candidates = mine
        }

        let stamped = candidates.compactMap { url -> (url: URL, key: (Date, Int))? in
            guard let parsed = CloudStorage.backupDirectoryTimestamp(
                name: url.lastPathComponent
            ) else {
                return nil
            }
            return (url, (parsed.date, parsed.sequence))
        }
        guard stamped.count == candidates.count else {
            let unparseable = candidates.count - stamped.count
            onLine?(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(unparseable) backup folder(s) have non-standard names — "
                    + "skipping prune so none are deleted out of order."
            ))
            return
        }

        let scheduled = stamped
            .sorted { lhs, rhs in
                lhs.key.0 == rhs.key.0 ? lhs.key.1 > rhs.key.1 : lhs.key.0 > rhs.key.0
            }
            .map(\.url)

        guard scheduled.count > keep else { return }
        for url in scheduled.dropFirst(keep) {
            do {
                try fm.removeItem(at: url)
                onLine?(.init(
                    timestamp: Date(), level: .info,
                    text: "[info] pruned old scheduled backup \(url.lastPathComponent)"
                ))
            } catch {
                onLine?(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] could not prune backup \(url.lastPathComponent): \(error.localizedDescription)"
                ))
            }
        }
    }

    /// Post-success housekeeping run by both the `jamf-reports backup` command
    /// (`UtilityCommands`) and the headless `--scheduled-run` path (`main.swift`).
    /// Prunes old scheduled backups and sweeps abandoned `.tmp-*` staging dirs.
    /// Both paths must call this and nothing else — do not inline the two steps
    /// at call sites or they will diverge again.
    static func performPostSuccessHousekeeping(
        profile: String,
        keep: Int = defaultKeepCount,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        // Stamp first: retention below can only scope to this machine on shared
        // storage if the backup that just finished says who made it.
        stampNewestScheduledBackup(profile: profile)
        pruneScheduledBackups(profile: profile, keep: keep, onLine: onLine)
        cleanStaleTempDirs(profile: profile)
    }

    /// Delete `.tmp-*` staging directories older than `staleTempAge`.
    /// Returns the names of the directories removed (for logging/tests).
    @discardableResult
    static func cleanStaleTempDirs(
        profile: String, now: Date = Date(),
        volumeIsLocal: @Sendable (URL) -> Bool? = BackupMaintenance.isOnLocalVolume
    ) -> [String] {
        guard let backupsRoot = backupsRoot(for: profile) else { return [] }
        // Staleness here can only come from mtime — a `.tmp-<UUID>` name carries
        // no timestamp. On synced storage that mtime is the provider's, and the
        // directory may belong to another Mac's in-flight backup, so don't sweep.
        if sharedStorageDescription(
            backupsRoot, profile: profile, volumeIsLocal: volumeIsLocal) != nil {
            return []
        }
        let fm = FileManager.default
        // .tmp-* dirs are dot-prefixed → must NOT skip hidden files here.
        guard let entries = try? fm.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return [] }

        var removed: [String] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(".tmp-"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  now.timeIntervalSince(mtime(url)) >= staleTempAge else {
                continue
            }
            do {
                try fm.removeItem(at: url)
                removed.append(name)
                AppLogger.cli.info(
                    "BackupMaintenance: removed abandoned staging dir \(name, privacy: .public)"
                )
            } catch {
                AppLogger.cli.warning(
                    "BackupMaintenance: could not remove \(name, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        return removed
    }

    // MARK: - Private

    private static func backupsRoot(for profile: String) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        let root = workspace.appendingPathComponent("backups", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return root
    }

    /// The `label` field from a backup directory's manifest.json, or nil.
    /// Filename of the ownership stamp written beside a scheduled backup.
    static let ownerStampName = ".jrc-host"

    /// Record which machine produced `backupDir`.
    ///
    /// Best-effort: a backup without a stamp is simply never auto-pruned on
    /// shared storage, which is the safe direction.
    static func stampOwnership(of backupDir: URL) {
        let url = backupDir.appendingPathComponent(ownerStampName)
        try? Data(SharedWorkspace.currentHost.id.utf8).write(to: url, options: .atomic)
    }

    /// Host id recorded for `backupDir`, or nil when unstamped.
    static func ownerHostID(of backupDir: URL) -> String? {
        let url = backupDir.appendingPathComponent(ownerStampName)
        guard let data = try? Data(contentsOf: url), data.count <= 512,
              let id = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Stamp the newest scheduled backup as this machine's. Called right after
    /// a backup completes, before retention runs.
    static func stampNewestScheduledBackup(profile: String) {
        guard let backupsRoot = backupsRoot(for: profile),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: backupsRoot, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        let newest = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { manifestLabel(of: $0)?.hasPrefix("scheduled-") == true }
            .compactMap { url -> (URL, Date, Int)? in
                guard let p = CloudStorage.backupDirectoryTimestamp(name: url.lastPathComponent)
                else { return nil }
                return (url, p.date, p.sequence)
            }
            .max { lhs, rhs in lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 < rhs.1 }
        guard let newest else { return }
        stampOwnership(of: newest.0)
    }

    private static func manifestLabel(of backupDir: URL) -> String? {
        let manifestURL = backupDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload["label"] as? String
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
