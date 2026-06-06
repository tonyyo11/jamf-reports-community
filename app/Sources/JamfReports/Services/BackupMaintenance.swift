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
    static func pruneScheduledBackups(
        profile: String,
        keep: Int,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        guard let backupsRoot = backupsRoot(for: profile) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let scheduled = entries
            .filter { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return isDir && manifestLabel(of: url)?.hasPrefix("scheduled-") == true
            }
            .sorted { mtime($0) > mtime($1) }

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

    /// Post-success housekeeping run by both the GUI "Run now" backup path
    /// (`CLIBridge+Run`) and the headless `--scheduled-run` path (`main.swift`).
    /// Prunes old scheduled backups and sweeps abandoned `.tmp-*` staging dirs.
    /// Both paths must call this and nothing else — do not inline the two steps
    /// at call sites or they will diverge again.
    static func performPostSuccessHousekeeping(
        profile: String,
        keep: Int = defaultKeepCount,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) {
        pruneScheduledBackups(profile: profile, keep: keep, onLine: onLine)
        cleanStaleTempDirs(profile: profile)
    }

    /// Delete `.tmp-*` staging directories older than `staleTempAge`.
    /// Returns the names of the directories removed (for logging/tests).
    @discardableResult
    static func cleanStaleTempDirs(profile: String, now: Date = Date()) -> [String] {
        guard let backupsRoot = backupsRoot(for: profile) else { return [] }
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
