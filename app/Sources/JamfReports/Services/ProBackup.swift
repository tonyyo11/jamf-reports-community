import Foundation

/// Whether a backup includes Jamf Pro on storage other Macs reach. `pro backup` writes
/// configuration that can hold secrets (LDAP, SMTP and API-client settings, scripts with
/// embedded values), so on a sync provider, a network volume or a shared workspace the operator
/// decides once per workspace (`backup.pro_on_synced_storage`), as for Jamf Protect. Local
/// storage is unchanged and needs no key.
enum ProBackup {
    /// `backup.pro_on_synced_storage` as this Mac may use it.
    enum Setting: Sendable, Equatable {
        /// Absent: the operator has not chosen.
        case notChosen
        /// false (or anything the app could not read as a boolean): the operator's no.
        case declined
        case allowed
        /// true in config.yaml, but not confirmed on this Mac yet (`SharedConfigPin`).
        case awaitingConfirmation
        /// config.yaml cannot be read, so the choice is unknown and Jamf Pro is skipped.
        case configUnreadable
    }

    /// config.yaml as the backup and the Backups screen both read it: the one reader. A file
    /// that exists but does not decode has a `failure` (redacted) and no config.
    struct ConfigRead: Sendable {
        let config: ReportConfig?
        let failure: String?
    }

    static func readConfig(profile: String) -> ConfigRead {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return ConfigRead(config: nil, failure: nil)
        }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ConfigRead(config: nil, failure: nil)
        }
        do {
            return ConfigRead(config: try ConfigLoader.load(from: url), failure: nil)
        } catch {
            return ConfigRead(
                config: nil, failure: LogRedactor.redact(error.localizedDescription))
        }
    }

    /// Why a skipped Jamf Pro part is skipped, which decides what the run says about it.
    enum SkipKind: Sendable, Equatable {
        /// The operator said no (or config.yaml cannot be read): a decision, so the run is not
        /// Partial and nothing needs attention.
        case declined
        /// Not chosen yet: Partial, with a Needs-attention item.
        case asking
        /// The operator wants it but this Mac has not confirmed it: Partial.
        case awaitingConfirmation

        var makesRunPartial: Bool { self != .declined }
    }

    enum Plan: Equatable {
        /// Local storage: back up as always.
        case run
        /// The operator opted in: back up, and log it.
        case runOnSyncedStorage(place: String)
        /// No choice yet, but scheduled backups already ran here: keep going for a few runs
        /// while the operator is asked, so an upgrade never stops them silently.
        case runWhileAsking(place: String, runsLeft: Int)
        case skip(reason: String, kind: SkipKind)
    }

    /// `place` is `BackupMaintenance.sharedStorageDescription`; nil means local storage.
    /// `decodeFailure` is set when config.yaml cannot be read: the choice is then unknown, and
    /// unknown never sends Jamf Pro configuration to shared storage.
    static func plan(
        setting: Setting,
        place: String?,
        decodeFailure: String? = nil,
        hasScheduledHistory: () -> Bool,
        graceRunsUsed: () -> Int
    ) -> Plan {
        guard let place else { return .run }
        switch decodeFailure == nil ? setting : .configUnreadable {
        case .configUnreadable:
            // Fixed text: the decode error carries a path, so it goes in the log line only.
            return .skip(
                reason: "this workspace is \(place), and config.yaml could not be read, so the "
                    + "Jamf Pro backup choice is unknown",
                kind: .declined)
        case .allowed:
            return .runOnSyncedStorage(place: place)
        case .declined:
            return .skip(reason: syncedStorageReason(place: place), kind: .declined)
        case .awaitingConfirmation:
            return .skip(
                reason: "\(SharedConfigPin.Key.proBackupOnSyncedStorage.rawValue) is on in "
                    + "config.yaml and waiting for confirmation on this Mac (Config Doctor)",
                kind: .awaitingConfirmation)
        case .notChosen:
            let left = BackupMaintenance.graceRunsBeforeAsking - graceRunsUsed()
            if left > 0, hasScheduledHistory() {
                return .runWhileAsking(place: place, runsLeft: left)
            }
            return .skip(reason: syncedStorageReason(place: place), kind: .asking)
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
        let setting: Setting
    }

    static func syncedStorageChoice(
        profile: String, config: ReportConfig?, decodeFailure: String? = nil,
        appSupport: URL = AppSupport.directory()
    ) -> SyncedStorageChoice? {
        let detected = ProfileProductType.detect(from: config, profile: profile)
        guard detected.type == .jamfPro,
              let workspace = ProfileService.workspaceURL(for: profile),
              let place = BackupMaintenance.sharedStorageDescription(
                workspace.appendingPathComponent("backups", isDirectory: true),
                profile: profile, volumeIsLocal: CloudStorage.isOnLocalVolume,
                unreadableConfigIsShared: false, pinnedIsShared: true, appSupport: appSupport)
        else { return nil }
        return SyncedStorageChoice(
            place: place,
            setting: decodeFailure != nil ? .configUnreadable
                : SharedConfigPin.proBackupSetting(
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

    /// Uses up the grace: this Mac has seen an explicit value, so a peer deleting the key later
    /// cannot buy more runs. Best effort; the count read fails toward skipping anyway.
    static func exhaust(profile: String, appSupport: URL = AppSupport.directory()) {
        guard used(profile: profile, appSupport: appSupport)
                < BackupMaintenance.graceRunsBeforeAsking else { return }
        let url = url(profile: profile, appSupport: appSupport)
        guard let data = try? JSONSerialization.data(
                withJSONObject: ["runs": BackupMaintenance.graceRunsBeforeAsking]),
              (try? data.write(to: url, options: .atomic)) != nil else {
            AppLogger.collect.warning("ProBackupGrace: could not record the explicit choice")
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            case .invalidProfile(let profile): ProfileName.invalidMessage(profile)
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
