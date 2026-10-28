import Foundation

/// Whether a backup includes Jamf Pro on storage other Macs reach. `pro backup` writes
/// configuration that can hold secrets (LDAP, SMTP and API-client settings, scripts with
/// embedded values), so on a sync provider, a network volume or a shared workspace the operator
/// decides once per workspace (`backup.pro_on_synced_storage`), as for Jamf Protect. Local
/// storage is unchanged and needs no key.
enum ProBackup {
    enum Plan: Equatable {
        /// Local storage: back up as always.
        case run
        /// The operator opted in: back up, and log it.
        case runOnSyncedStorage(place: String)
        /// No choice yet, but scheduled backups already ran here: keep going for a few runs
        /// while the operator is asked, so an upgrade never stops them silently.
        case runWhileAsking(place: String, runsLeft: Int)
        /// `asking` is true when the operator has not chosen, false for a no.
        case skip(reason: String, asking: Bool)
    }

    /// `setting` is `backup.pro_on_synced_storage` as this Mac may use it
    /// (`SharedConfigPin.proBackupOnSyncedStorage`): nil when absent. `place` is
    /// `BackupMaintenance.sharedStorageDescription`; nil means local storage.
    static func plan(
        setting: Bool?,
        place: String?,
        hasScheduledHistory: () -> Bool,
        graceRunsUsed: () -> Int
    ) -> Plan {
        guard let place else { return .run }
        switch setting {
        case true?:
            return .runOnSyncedStorage(place: place)
        case false?:
            return .skip(reason: syncedStorageReason(place: place), asking: false)
        case nil:
            let left = BackupMaintenance.graceRunsBeforeAsking - graceRunsUsed()
            if left > 0, hasScheduledHistory() {
                return .runWhileAsking(place: place, runsLeft: left)
            }
            return .skip(reason: syncedStorageReason(place: place), asking: true)
        }
    }

    /// The concern and how to allow it; the organization's storage policy decides, not the app.
    static func syncedStorageReason(place: String) -> String {
        "this workspace is \(place), and a Jamf Pro backup contains LDAP, SMTP and API-client "
            + "configuration and scripts that can hold secrets. If your organization's storage "
            + "policy allows it, turn on Jamf Pro backups for this folder in Backups "
            + "(\(SharedConfigPin.Key.proBackupOnSyncedStorage.rawValue))"
    }

    /// The `[warn]` line for a skipped Jamf Pro part.
    static func skipLine(reason: String) -> String {
        "[warn] Jamf Pro not backed up: \(reason)"
    }

    /// The `[partial]` line that makes the run Partial (a skip is not a failure: no `[error]`,
    /// no failure record, and backup mode never retries).
    static let partialLine =
        "[partial] Jamf Pro configuration is not backed up; the choice is set in Backups"

    static func choiceNeededMessage(place: String, runsLeft: Int?) -> String {
        let tail = runsLeft.map {
            "; \($0) scheduled backup\($0 == 1 ? "" : "s") will still run before they stop"
        } ?? "; Jamf Pro backups are stopped until it is made"
        return "Jamf Pro backups on this workspace (\(place)) need a choice in Backups" + tail
    }

    /// Where a Jamf Pro workspace's backups sit on storage other Macs reach, and whether this
    /// Mac backs Jamf Pro up there. Nil when the storage is local or the profile is not Jamf
    /// Pro. Probes the volume, so call it off the main actor.
    struct SyncedStorageChoice: Sendable, Equatable {
        let place: String
        /// Nil: no choice made yet.
        let setting: Bool?
    }

    static func syncedStorageChoice(
        profile: String, config: ReportConfig?, appSupport: URL = AppSupport.directory()
    ) -> SyncedStorageChoice? {
        let detected = ProfileProductType.detect(from: config, profile: profile)
        guard detected.type == .jamfPro,
              let workspace = ProfileService.workspaceURL(for: profile),
              let place = BackupMaintenance.sharedStorageDescription(
                workspace.appendingPathComponent("backups", isDirectory: true),
                profile: profile, volumeIsLocal: CloudStorage.isOnLocalVolume,
                unreadableConfigIsShared: false)
        else { return nil }
        return SyncedStorageChoice(
            place: place,
            setting: SharedConfigPin.proBackupOnSyncedStorage(
                config?.backup?.proOnSyncedStorage, profile: profile, appSupport: appSupport))
    }
}

/// How many scheduled Jamf Pro backups ran on this Mac while the choice was still open. Per
/// Mac, in Application Support, never in a workspace that other Macs write.
enum ProBackupGrace {
    static func url(profile: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent(
            "pro-backup-grace-\(ProfileName.pathComponent(profile)).json")
    }

    /// Runs counted so far. An unreadable record reads as used up: failing toward a skip keeps
    /// secrets off shared storage, and keeping them there is the direction that cannot be undone.
    static func used(profile: String, appSupport: URL = AppSupport.directory()) -> Int {
        let url = url(profile: profile, appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? BoundedFile.read(url, limit: 512, followSymlinks: false),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = object["runs"] as? Int, runs >= 0
        else { return BackupMaintenance.graceRunsBeforeAsking }
        return min(runs, BackupMaintenance.graceRunsBeforeAsking)
    }

    /// Counts one run. Throws when the count cannot be saved; the caller then skips.
    static func record(profile: String, appSupport: URL = AppSupport.directory()) throws {
        let url = url(profile: profile, appSupport: appSupport)
        let next = used(profile: profile, appSupport: appSupport) + 1
        let data = try JSONSerialization.data(withJSONObject: ["runs": next])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Scoped write of one backup choice, the Backups screen's switches:
/// `protect.backup_on_synced_storage` or `backup.pro_on_synced_storage`. Like
/// `NotifyConfigWriter` it rewrites only the block it names (a dropped comment is copied out
/// first) and confirms the value it wrote on this Mac, since the switch is the operator's act.
enum BackupChoiceConfigWriter {
    enum Choice: Sendable {
        case protect, pro

        var block: String { self == .protect ? "protect" : "backup" }
        var key: String {
            self == .protect ? "backup_on_synced_storage" : "pro_on_synced_storage"
        }
        var pinKey: SharedConfigPin.Key {
            self == .protect ? .protectBackupOnSyncedStorage : .proBackupOnSyncedStorage
        }
    }

    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    static func apply(_ choice: Choice, on: Bool, to root: inout YAMLCodec.YAMLMapping) {
        var block = root.value(for: choice.block)?.mapping ?? .init(entries: [])
        block.set(choice.key, value: .scalar(.bool(on)))
        root.set(choice.block, value: .mapping(block))
    }

    @discardableResult
    static func save(
        _ choice: Choice, on: Bool, profile: String, appSupport: URL = AppSupport.directory()
    ) throws -> ConfigSaveReport {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        let report = try ConfigService.saveBlock(key: choice.block, profile: profile) {
            apply(choice, on: on, to: &$0)
        }.report
        SharedConfigPin.confirmWritten(
            String(on), key: choice.pinKey, profile: profile, appSupport: appSupport)
        return report
    }
}
