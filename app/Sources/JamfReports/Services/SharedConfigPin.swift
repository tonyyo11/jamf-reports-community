import CryptoKit
import Foundation
import os

/// Per-Mac record of the config.yaml values a shared workspace's peers could use against this Mac.
///
/// On a shared (synced) workspace every Mac that can write the folder writes config.yaml, and
/// three things in it are obeyed by every other Mac: where reports and snapshots are written
/// (`output.*`, `jamf_cli.data_dir`, with `allow_absolute_paths`), whether snapshots are deleted
/// (`retention`), and where the webhook goes (`notify.url`). Those keys stay in config.yaml, since
/// every Mac sharing the folder must agree on them, but each Mac pins the values it was set up
/// with in `AppSupport` and does not follow a later change until its operator confirms it.
///
/// A local workspace is never pinned. Pinning applies when `shared_workspace.enabled` is true,
/// the folder is on shared storage (`CloudStorage.isSharedStorage`), or a pin already exists; an
/// opt-out written into the shared file never turns an existing pin off, since a peer could
/// write it.
struct SharedConfigPin: Codable, Sendable, Equatable {
    var allowAbsolutePaths: Bool
    var outputDir: String
    var archiveDir: String
    var dataDir: String
    var retentionEnabled: Bool
    var retentionMode: String
    var retentionArchiveDir: String
    /// `shared_workspace.enabled` as typed: "true", "false" or "" when absent.
    var sharedEnabled: String
    var historicalDir: String
    var protectProfile: String
    /// `notify.detail` lowercased; "full" when absent.
    var notifyDetail: String
    /// Keys (`Key.rawValue`) pinned at first sight that this Mac's operator has not yet
    /// confirmed: an absolute folder outside the workspace, and `retention.mode: delete`.
    var unconfirmed: [String] = []
    /// Keys (`Key.rawValue`) this pin holds a value for. A key missing from it, because the app
    /// learned it after the pin was written, is pinned at its first sight rather than read as
    /// changed, so an upgrade does not stop every Mac's webhook.
    var pinnedKeys: [String] = Key.allCases.map(\.rawValue)
    /// `host` or `host:port` of the webhook URL. The URL itself is a credential and never
    /// leaves config.yaml; `notifyURLHash` is its SHA-256, so a changed path or token drifts too.
    var notifyURLHost: String
    var notifyURLHash: String = ""
    /// `html.history_file` as typed, tilde expanded: a file the HTML report appends to.
    var htmlHistoryFile: String = ""
    /// `branding.logo_path` as typed, tilde expanded: a file the workbook embeds.
    var brandingLogoPath: String = ""
    /// `notify.heartbeat`: whether the tick posts its daily card to the pinned webhook.
    var notifyHeartbeat: Bool = false
    /// `protect.backup_on_synced_storage`: whether a backup on shared storage includes Protect.
    var protectBackupOnSyncedStorage: Bool = false
    /// `backup.pro_on_synced_storage`: whether a backup on shared storage includes Jamf Pro.
    /// An absent key pins as false; whether it was absent is read from config.yaml, not the pin.
    var proBackupOnSyncedStorage: Bool = false
    /// `output.timestamp_authority`, pinned as the webhook is: `host[:port]` and the SHA-256 of
    /// the URL, which can carry a token.
    var timestampAuthorityHost: String = ""
    var timestampAuthorityHash: String = ""

    /// One pinned key, named as it is written in config.yaml.
    enum Key: String, CaseIterable, Sendable {
        case allowAbsolutePaths = "output.allow_absolute_paths"
        case outputDir = "output.output_dir"
        case archiveDir = "output.archive_dir"
        case dataDir = "jamf_cli.data_dir"
        case retentionEnabled = "retention.enabled"
        case retentionMode = "retention.mode"
        case retentionArchiveDir = "retention.archive_dir"
        case sharedEnabled = "shared_workspace.enabled"
        case historicalDir = "charts.historical_csv_dir"
        case protectProfile = "protect.profile"
        case notifyDetail = "notify.detail"
        case notifyURL = "notify.url"
        case notifyHeartbeat = "notify.heartbeat"
        case htmlHistoryFile = "html.history_file"
        case brandingLogoPath = "branding.logo_path"
        case protectBackupOnSyncedStorage = "protect.backup_on_synced_storage"
        case proBackupOnSyncedStorage = "backup.pro_on_synced_storage"
        case timestampAuthority = "output.timestamp_authority"

        /// `text(of:)` with everything a comparison needs: a URL's full hash.
        fileprivate func token(of pin: SharedConfigPin) -> String {
            switch self {
            case .notifyURL: "\(pin.notifyURLHost) \(pin.notifyURLHash)"
            case .timestampAuthority:
                "\(pin.timestampAuthorityHost) \(pin.timestampAuthorityHash)"
            default: text(of: pin)
            }
        }

        /// The keys that name a folder or file the app reads or writes.
        var isFolder: Bool {
            switch self {
            case .outputDir, .archiveDir, .dataDir, .historicalDir, .retentionArchiveDir,
                 .htmlHistoryFile, .brandingLogoPath: true
            default: false
            }
        }

        /// Place in `allCases`, which orders the rows and warnings.
        fileprivate var position: Int { Key.allCases.firstIndex(of: self) ?? Int.max }

        fileprivate func text(of pin: SharedConfigPin) -> String {
            switch self {
            case .allowAbsolutePaths: String(pin.allowAbsolutePaths)
            case .outputDir: pin.outputDir
            case .archiveDir: pin.archiveDir
            case .dataDir: pin.dataDir
            case .retentionEnabled: String(pin.retentionEnabled)
            case .retentionMode: pin.retentionMode
            case .retentionArchiveDir: pin.retentionArchiveDir
            case .sharedEnabled: pin.sharedEnabled
            case .historicalDir: pin.historicalDir
            case .protectProfile: pin.protectProfile
            case .notifyDetail: pin.notifyDetail
            case .notifyHeartbeat: String(pin.notifyHeartbeat)
            case .htmlHistoryFile: pin.htmlHistoryFile
            case .brandingLogoPath: pin.brandingLogoPath
            case .protectBackupOnSyncedStorage: String(pin.protectBackupOnSyncedStorage)
            case .proBackupOnSyncedStorage: String(pin.proBackupOnSyncedStorage)
            case .notifyURL: Self.urlText(pin.notifyURLHost, pin.notifyURLHash)
            case .timestampAuthority:
                Self.urlText(pin.timestampAuthorityHost, pin.timestampAuthorityHash)
            }
        }

        private static func urlText(_ host: String, _ hash: String) -> String {
            hash.isEmpty ? host : "\(host) (URL fingerprint \(hash.prefix(8)))"
        }

        fileprivate func copy(from source: SharedConfigPin, into pin: inout SharedConfigPin) {
            switch self {
            case .allowAbsolutePaths: pin.allowAbsolutePaths = source.allowAbsolutePaths
            case .outputDir: pin.outputDir = source.outputDir
            case .archiveDir: pin.archiveDir = source.archiveDir
            case .dataDir: pin.dataDir = source.dataDir
            case .retentionEnabled: pin.retentionEnabled = source.retentionEnabled
            case .retentionMode: pin.retentionMode = source.retentionMode
            case .retentionArchiveDir: pin.retentionArchiveDir = source.retentionArchiveDir
            case .sharedEnabled: pin.sharedEnabled = source.sharedEnabled
            case .historicalDir: pin.historicalDir = source.historicalDir
            case .protectProfile: pin.protectProfile = source.protectProfile
            case .notifyDetail: pin.notifyDetail = source.notifyDetail
            case .notifyHeartbeat: pin.notifyHeartbeat = source.notifyHeartbeat
            case .htmlHistoryFile: pin.htmlHistoryFile = source.htmlHistoryFile
            case .brandingLogoPath: pin.brandingLogoPath = source.brandingLogoPath
            case .protectBackupOnSyncedStorage:
                pin.protectBackupOnSyncedStorage = source.protectBackupOnSyncedStorage
            case .proBackupOnSyncedStorage:
                pin.proBackupOnSyncedStorage = source.proBackupOnSyncedStorage
            case .notifyURL:
                pin.notifyURLHost = source.notifyURLHost
                pin.notifyURLHash = source.notifyURLHash
            case .timestampAuthority:
                pin.timestampAuthorityHost = source.timestampAuthorityHost
                pin.timestampAuthorityHash = source.timestampAuthorityHash
            }
        }
    }

    struct Drift: Sendable, Equatable {
        let key: Key
        let pinned: String
        /// True when `pinned` is a note (first sight, unreadable pin) rather than a pinned value,
        /// so a value that merely looks like a note is still shown as a value.
        let pinnedIsNote: Bool
        /// What the row shows. The webhook shows host, port and a short fingerprint.
        let current: String
        /// What Confirm compares: the whole value, including the full URL hash.
        let currentToken: String

        init(
            key: Key, pinned: String, current: String, currentToken: String? = nil,
            pinnedIsNote: Bool = false
        ) {
            self.key = key
            self.pinned = pinned
            self.pinnedIsNote = pinnedIsNote
            self.current = current
            self.currentToken = currentToken ?? current
        }
    }

    /// Each key whose value differs, in `Key.allCases` order.
    static func diff(pinned: SharedConfigPin, current: SharedConfigPin) -> [Drift] {
        Key.allCases.compactMap { key in
            let was = key.text(of: pinned)
            let now = key.text(of: current)
            return key.token(of: pinned) == key.token(of: current)
                ? nil
                : Drift(key: key, pinned: was, current: now, currentToken: key.token(of: current))
        }
    }

    static let firstSightNote = "(first seen, not confirmed)"
    static let unreadableNote = "(pin unreadable)"
    static let configUnreadableNote = "(config.yaml unreadable)"

    /// The pin for a workspace seen for the first time. What is already in the shared file may
    /// have been written by a peer, so a folder outside the workspace, a `delete` retention,
    /// Protect backups on synced storage turned on and a timestamp authority are pinned as
    /// unconfirmed: every run uses the safe value for them until one Confirm. The webhook host
    /// and the other keys are trust-on-first-use.
    static func firstPin(current: SharedConfigPin, workspace: URL) -> SharedConfigPin {
        var pin = current
        pin.pinnedKeys = Key.allCases.map(\.rawValue)
        pin.unconfirmed = unconfirmedKeys(
            current: current, workspace: workspace, among: Set(Key.allCases)).map(\.rawValue)
        return pin
    }

    /// Of `keys`, those whose value in `current` must wait for a Confirm.
    private static func unconfirmedKeys(
        current: SharedConfigPin, workspace: URL, among keys: Set<Key>
    ) -> [Key] {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        func outside(_ value: String) -> Bool {
            guard value.hasPrefix("/") else { return false }
            let path = URL(fileURLWithPath: value)
                .resolvingSymlinksInPath().standardizedFileURL.path
            return path != root && !path.hasPrefix(root + "/")
        }
        let folders: [(Key, String)] = [
            (.outputDir, current.outputDir), (.archiveDir, current.archiveDir),
            (.dataDir, current.dataDir), (.historicalDir, current.historicalDir),
            (.retentionArchiveDir, current.retentionArchiveDir),
            (.htmlHistoryFile, current.htmlHistoryFile),
        ]
        var waiting = folders.filter { outside($0.1) }.map(\.0)
        if current.retentionMode == RetentionConfig.Mode.delete.rawValue {
            waiting.append(.retentionMode)
        }
        if current.protectBackupOnSyncedStorage { waiting.append(.protectBackupOnSyncedStorage) }
        if current.proBackupOnSyncedStorage { waiting.append(.proBackupOnSyncedStorage) }
        // An address this Mac would send to is never taken on first sight.
        if !current.timestampAuthorityHash.isEmpty { waiting.append(.timestampAuthority) }
        return waiting.filter(keys.contains)
    }

    /// `pin` with a first-sight pin for each key it holds no value for, nil when it holds them
    /// all. The same unconfirmed rule applies to those keys as at a workspace's first sight.
    static func adoptingMissingKeys(
        _ pin: SharedConfigPin, current: SharedConfigPin, workspace: URL
    ) -> SharedConfigPin? {
        let missing = Set(Key.allCases.filter { !pin.pinnedKeys.contains($0.rawValue) })
        guard !missing.isEmpty else { return nil }
        var upgraded = pin
        for key in missing {
            key.copy(from: current, into: &upgraded)
            upgraded.pinnedKeys.append(key.rawValue)
        }
        upgraded.unconfirmed += unconfirmedKeys(
            current: current, workspace: workspace, among: missing).map(\.rawValue)
        return upgraded
    }

    // MARK: - Reading config.yaml

    /// The pinned values as config.yaml holds them now, read the way `WorkspacePaths`,
    /// `RetentionConfig` and `NotifyConfig` read them. Nil when the file is missing or unreadable.
    static func current(workspace: URL) -> SharedConfigPin? {
        let url = workspace.appendingPathComponent("config.yaml")
        guard let text = try? ConfigLoader.readText(at: url),
              let root = try? ConfigLoader.rawMapping(fromYAML: text) else { return nil }
        func raw(_ section: String, _ key: String) -> Any? {
            ConfigLoader.rawValue(at: [section, key], in: root)
        }
        func path(_ section: String, _ key: String) -> String {
            let typed = (raw(section, key) as? String) ?? ""
            return WorkspacePaths.expandTilde(
                typed.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let mode = ((raw("retention", "mode") as? String) ?? "").lowercased()
        let detail = ((raw("notify", "detail") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let notifyDetail = detail.isEmpty ? "full" : detail
        let typedURL = ((raw("notify", "url") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let authority = ((raw("output", "timestamp_authority") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        // The Protect login is `profiles.protect` once that block exists, as `EnvironmentProfiles`
        // reads it, so the one pin key covers both forms and a peer cannot add the block unseen.
        // Read as the decoder reads it, so the pinned name is the one jamf-cli receives.
        let protectProfile = ConfigLoader.rawValue(at: ["profiles"], in: root) is [String: Any]
            ? raw("profiles", "protect") : raw("protect", "profile")
        return SharedConfigPin(
            allowAbsolutePaths: WorkspacePaths.optIn(raw("output", "allow_absolute_paths")) == true,
            outputDir: path("output", "output_dir"),
            archiveDir: path("output", "archive_dir"),
            dataDir: path("jamf_cli", "data_dir"),
            retentionEnabled: (raw("retention", "enabled") as? Bool) ?? false,
            retentionMode: RetentionConfig.Mode(rawValue: mode)?.rawValue ?? "archive",
            retentionArchiveDir: path("retention", "archive_dir"),
            sharedEnabled: (raw("shared_workspace", "enabled") as? Bool).map { String($0) } ?? "",
            historicalDir: path("charts", "historical_csv_dir"),
            protectProfile: (ConfigLoader.textValue(protectProfile) ?? "")
                .trimmingCharacters(in: .whitespaces),
            notifyDetail: notifyDetail,
            notifyURLHost: webhookHost(typedURL),
            notifyURLHash: typedURL.isEmpty ? "" : SharedConfigPin.sha256Hex(typedURL),
            htmlHistoryFile: path("html", "history_file"),
            brandingLogoPath: path("branding", "logo_path"),
            notifyHeartbeat: (raw("notify", "heartbeat") as? Bool) ?? false,
            protectBackupOnSyncedStorage:
                (raw("protect", "backup_on_synced_storage") as? Bool) ?? false,
            proBackupOnSyncedStorage:
                (raw("backup", "pro_on_synced_storage") as? Bool) ?? false,
            timestampAuthorityHost: webhookHost(authority),
            timestampAuthorityHash: authority.isEmpty ? "" : SharedConfigPin.sha256Hex(authority)
        )
    }

    private static func webhookHost(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return "" }
        return parsed.port.map { "\(host):\($0)" } ?? host
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Store

    /// `<AppSupport>/shared-config-pin-<WorkspaceID.pathComponent>.json`, 0600: the name a pin
    /// had before 2.12, when the workspace ID was its profile. Nil for a name that is no
    /// workspace ID, which has no pin.
    static func storeURL(workspace: String, appSupport: URL) -> URL? {
        WorkspaceID(workspace).map {
            appSupport.appendingPathComponent("shared-config-pin-\($0.pathComponent).json")
        }
    }

    /// What the store holds. Only a missing file is a first sight: a pin that exists but
    /// cannot be read is `unreadable`, never a reason to pin the file's current contents.
    enum Stored: Sendable {
        case absent
        case unreadable
        case pin(SharedConfigPin)

        var pin: SharedConfigPin? {
            if case .pin(let pin) = self { return pin }
            return nil
        }
    }

    static func read(profile: String, appSupport: URL) -> Stored {
        guard let url = storeURL(workspace: profile, appSupport: appSupport),
              FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let pin = try? JSONDecoder().decode(SharedConfigPin.self, from: data)
        else { return .unreadable }
        return .pin(pin)
    }

    static func load(profile: String, appSupport: URL) -> SharedConfigPin? {
        read(profile: profile, appSupport: appSupport).pin
    }

    static func save(_ pin: SharedConfigPin, profile: String, appSupport: URL) throws {
        guard let url = storeURL(workspace: profile, appSupport: appSupport) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pin).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Check

    /// What `check` found. `drifts` is empty for a local workspace, a first sight and a clean one.
    struct Check: Sendable {
        let workspace: URL?
        let pinned: SharedConfigPin?
        let drifts: [Drift]
        /// Lines for the run log about the check itself, such as a pin that could not be saved.
        var notes: [String] = []
        /// No pin applies: the workspace is not shared and this Mac holds no pin for it (or the
        /// profile has no workspace). Only then is a nil `pinned` with no drifts a clean answer.
        var isLocal = false

        func isDrifted(_ key: Key) -> Bool { drifts.contains { $0.key == key } }
    }

    /// The token an unreadable config.yaml's drifts carry: no real value has it, so a Confirm shown
    /// while the file could not be read never matches an unset key once it can.
    static let unreadableToken = "\u{0}unreadable"

    /// Compares config.yaml with this Mac's pin. A shared workspace with no pin yet pins what it
    /// holds now (the values the operator set up with) and reports no drift. `persist: false`
    /// writes nothing: the pin a first sight or an upgrade would write is only compared against.
    static func check(
        profile: String, appSupport: URL = AppSupport.directory(), persist: Bool = true,
        syncProbe: CloudStorage.SyncProbe = .live
    ) -> Check {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return Check(workspace: nil, pinned: nil, drifts: [], isLocal: true)
        }
        let current: SharedConfigPin
        switch sharedCurrent(
            profile: profile, workspace: workspace, appSupport: appSupport, syncProbe: syncProbe) {
        case .local:
            return Check(workspace: workspace, pinned: nil, drifts: [], isLocal: true)
        case .unreadable:
            // Fail closed: a pinned or shared workspace whose config.yaml cannot be read now (gone,
            // oversized, not a file) has no value to compare, so every key reads as changed.
            let drifts = Key.allCases.map {
                Drift(key: $0, pinned: configUnreadableNote, current: configUnreadableNote,
                      currentToken: unreadableToken, pinnedIsNote: true)
            }
            return Check(workspace: workspace, pinned: nil, drifts: drifts)
        case .readable(let read): current = read
        }
        switch read(profile: profile, appSupport: appSupport) {
        case .absent:
            var notes: [String] = []
            let first = firstPin(current: current, workspace: workspace)
            do {
                if persist { try save(first, profile: profile, appSupport: appSupport) }
            } catch {
                notes.append("[warn] shared config could not be pinned on this Mac: "
                    + error.localizedDescription)
            }
            return Check(workspace: workspace, pinned: first,
                         drifts: unconfirmedDrifts(pin: first, current: current, among: []),
                         notes: notes)
        case .unreadable:
            // Fail closed: with no pin to compare against, every key reads as changed.
            let drifts = Key.allCases.map {
                Drift(key: $0, pinned: unreadableNote, current: $0.text(of: current),
                      currentToken: $0.token(of: current), pinnedIsNote: true)
            }
            return Check(workspace: workspace, pinned: nil, drifts: drifts)
        case .pin(let stored):
            var notes: [String] = []
            var pinned = stored
            let upgraded = adoptingMissingKeys(stored, current: current, workspace: workspace)
            if let upgraded { pinned = upgraded }
            let optedOut = repinningBackupOptOuts(&pinned, current: current)
            if upgraded != nil || optedOut {
                do {
                    if persist { try save(pinned, profile: profile, appSupport: appSupport) }
                } catch {
                    notes.append("[warn] shared config could not be pinned on this Mac: "
                        + error.localizedDescription)
                }
            }
            let changed = diff(pinned: pinned, current: current)
            return Check(workspace: workspace, pinned: pinned,
                         drifts: unconfirmedDrifts(pin: pinned, current: current, among: changed),
                         notes: notes)
        }
    }

    /// Re-pins the two backup opt-ins (`protect.backup_on_synced_storage`,
    /// `backup.pro_on_synced_storage`) to false when config.yaml no longer says true: moving to
    /// the safe value needs no Confirm, and a later true is then drift again.
    private static func repinningBackupOptOuts(
        _ pin: inout SharedConfigPin, current: SharedConfigPin
    ) -> Bool {
        let optIns: [(Key, WritableKeyPath<SharedConfigPin, Bool>)] = [
            (.protectBackupOnSyncedStorage, \.protectBackupOnSyncedStorage),
            (.proBackupOnSyncedStorage, \.proBackupOnSyncedStorage),
        ]
        var changed = false
        for (key, field) in optIns {
            guard !current[keyPath: field],
                  pin[keyPath: field] || pin.unconfirmed.contains(key.rawValue) else { continue }
            pin[keyPath: field] = false
            pin.unconfirmed.removeAll { $0 == key.rawValue }
            changed = true
        }
        return changed
    }

    /// `changed` plus the first-sight keys still awaiting a Confirm, in `Key.allCases` order.
    private static func unconfirmedDrifts(
        pin: SharedConfigPin, current: SharedConfigPin, among changed: [Drift]
    ) -> [Drift] {
        let waiting = pin.unconfirmed.compactMap(Key.init(rawValue:))
            .filter { key in !changed.contains { $0.key == key } }
            .map {
                Drift(key: $0, pinned: firstSightNote, current: $0.text(of: current),
                      currentToken: $0.token(of: current), pinnedIsNote: true)
            }
        return (changed + waiting).sorted { $0.key.position < $1.key.position }
    }

    /// Whether a workspace is pinned. Unlike `SharedWorkspace.isEffectivelyShared`, which
    /// coordination uses, `shared_workspace.enabled: false` does not opt out: the file is
    /// writable by every peer, so an opt-out beside hostile values would switch pinning off.
    static func appliesTo(sharedEnabled: Bool?, onSharedStorage: Bool, pinExists: Bool) -> Bool {
        sharedEnabled == true || onSharedStorage || pinExists
    }

    private enum SharedRead {
        case local, unreadable
        case readable(SharedConfigPin)

        var readable: SharedConfigPin? {
            if case .readable(let pin) = self { return pin }
            return nil
        }
    }

    /// `current(workspace:)` for a workspace that is pinned; `.local` for a local one, and
    /// `.unreadable` for a pinned or shared one whose config.yaml cannot be read.
    private static func sharedCurrent(
        profile: String, workspace: URL, appSupport: URL, syncProbe: CloudStorage.SyncProbe = .live
    ) -> SharedRead {
        let sharedConfig = (try? ConfigLoader.load(
            from: workspace.appendingPathComponent("config.yaml")))?.sharedWorkspace
        guard appliesTo(
            sharedEnabled: sharedConfig?.enabled,
            onSharedStorage: CloudStorage.isSharedStorage(workspace, syncProbe: syncProbe),
            pinExists: hasPin(profile: profile, appSupport: appSupport))
        else { return .local }
        return current(workspace: workspace).map(SharedRead.readable) ?? .unreadable
    }

    enum ConfirmError: Error, LocalizedError {
        case changedSinceShown

        var errorDescription: String? {
            "config.yaml changed since the row was shown; reload Config Doctor and check again."
        }
    }

    /// Re-pins the drifts a person was shown, each only while config.yaml still holds the value
    /// that was shown: a peer's second edit after the row loaded stays drifted. A pin that cannot
    /// be read is replaced only when every key still matches. A local workspace is left alone.
    static func confirm(
        profile: String, drifts: [Drift], appSupport: URL = AppSupport.directory()
    ) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return }
        let shared = sharedCurrent(profile: profile, workspace: workspace, appSupport: appSupport)
        // No value to compare with what the row showed, so nothing is confirmed.
        if case .unreadable = shared, !drifts.isEmpty { throw ConfirmError.changedSinceShown }
        guard let current = shared.readable else { return }
        var pin: SharedConfigPin
        var unreadable = false
        switch read(profile: profile, appSupport: appSupport) {
        case .absent: pin = firstPin(current: current, workspace: workspace)
        case .pin(let stored):
            pin = adoptingMissingKeys(stored, current: current, workspace: workspace) ?? stored
        case .unreadable: pin = firstPin(current: current, workspace: workspace); unreadable = true
        }
        var confirmed = 0
        for drift in drifts where drift.key.token(of: current) == drift.currentToken {
            drift.key.copy(from: current, into: &pin)
            pin.unconfirmed.removeAll { $0 == drift.key.rawValue }
            confirmed += 1
        }
        if unreadable, confirmed < Key.allCases.count { throw ConfirmError.changedSinceShown }
        // Nothing still matched what the row showed: say so rather than report a confirmation.
        if confirmed == 0, !drifts.isEmpty { throw ConfirmError.changedSinceShown }
        try save(pin, profile: profile, appSupport: appSupport)
        invalidateOverrides(for: workspace)
    }

    /// Re-pins `keys` to what config.yaml holds now, for a save on this Mac that changed them.
    /// Other keys stay as they are, drifted or not, and a pin that cannot be read stays so.
    static func confirm(
        profile: String, keys: Set<Key>, appSupport: URL = AppSupport.directory()
    ) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let current = sharedCurrent(
                profile: profile, workspace: workspace, appSupport: appSupport).readable
        else { return }
        var pin: SharedConfigPin
        switch read(profile: profile, appSupport: appSupport) {
        case .absent: pin = firstPin(current: current, workspace: workspace)
        case .pin(let stored):
            pin = adoptingMissingKeys(stored, current: current, workspace: workspace) ?? stored
        case .unreadable: return
        }
        for key in keys {
            key.copy(from: current, into: &pin)
            pin.unconfirmed.removeAll { $0 == key.rawValue }
        }
        try save(pin, profile: profile, appSupport: appSupport)
        invalidateOverrides(for: workspace)
    }

    // MARK: - Which saves confirm

    /// The folder keys a Config screen save changed against what the screen loaded. A save that
    /// leaves a folder as it was does not confirm it, whatever a peer wrote there.
    static func changedFolderKeys(
        before: (outputDir: String, archiveDir: String)?,
        after: (outputDir: String, archiveDir: String)
    ) -> Set<Key> {
        guard let before else { return [] }
        func differs(_ lhs: String, _ rhs: String) -> Bool {
            lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                != rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var keys: Set<Key> = []
        if differs(before.outputDir, after.outputDir) { keys.insert(.outputDir) }
        if differs(before.archiveDir, after.archiveDir) { keys.insert(.archiveDir) }
        return keys
    }

    /// `branding.logo_path` when a save changed it against what the screen loaded.
    static func changedBrandingKeys(before: String?, after: String) -> Set<Key> {
        guard let before else { return [] }
        let differs = before.trimmingCharacters(in: .whitespacesAndNewlines)
            != after.trimmingCharacters(in: .whitespacesAndNewlines)
        return differs ? [.brandingLogoPath] : []
    }

    /// The notification keys a save changed against what config.yaml held.
    static func changedNotifyKeys(
        previousURL: String, newURL: String, previousDetail: String?, newDetail: String,
        previousHeartbeat: Bool = false, newHeartbeat: Bool? = nil
    ) -> Set<Key> {
        var keys: Set<Key> = []
        if previousURL.trimmingCharacters(in: .whitespaces)
            != newURL.trimmingCharacters(in: .whitespaces) { keys.insert(.notifyURL) }
        func level(_ value: String?) -> String {
            let text = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return text.isEmpty ? "full" : text
        }
        if level(previousDetail) != level(newDetail) { keys.insert(.notifyDetail) }
        if let newHeartbeat, newHeartbeat != previousHeartbeat { keys.insert(.notifyHeartbeat) }
        return keys
    }

    /// The pinned keys a config.yaml text sets, for a write this Mac made (onboarding, scaffold).
    static func keysSet(inYAML text: String) -> Set<Key> {
        guard let root = try? ConfigLoader.rawMapping(fromYAML: text) else { return [] }
        return Set(Key.allCases.filter {
            ConfigLoader.rawValue(at: $0.rawValue.components(separatedBy: "."), in: root) != nil
        })
    }

    /// The profile whose workspace config.yaml `url` is, nil for any other file.
    static func profile(forConfigAt url: URL) -> String? {
        guard url.lastPathComponent == "config.yaml" else { return nil }
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path
                == ProfileService.workspacesRoot().standardizedFileURL.path else { return nil }
        return ProfileName.name(fromPathComponent: folder.lastPathComponent)
    }

    /// After this Mac wrote `url` (onboarding or `scaffold --out`): confirm exactly the keys
    /// that write set. Keys it left out stay as they are, so joining a peer's folder never
    /// accepts the peer's retention, webhook or Protect profile. Best effort; a failure is logged.
    static func confirmWrittenConfig(
        at url: URL, profile: String? = nil, appSupport: URL = AppSupport.directory()
    ) {
        guard let profile = profile ?? Self.profile(forConfigAt: url),
              let text = try? ConfigLoader.readText(at: url) else { return }
        let keys = keysSet(inYAML: text)
        guard !keys.isEmpty else { return }
        confirmBestEffort(profile: profile, keys: keys, appSupport: appSupport)
    }

    /// `confirm(profile:keys:)` for a write this Mac just made; a failure is logged, since the
    /// write itself succeeded and the Doctor row still offers the Confirm.
    /// Re-pins `key` to `written`, the value a save on this Mac just wrote, only while
    /// config.yaml still holds it (a peer's edit landing in between is not confirmed), and
    /// even when it equals the value before (it clears a peer's identical pending drift).
    /// For keys whose token is their text; never the webhook.
    static func confirmWritten(
        _ written: String, key: Key, profile: String, appSupport: URL = AppSupport.directory()
    ) {
        guard key != .notifyURL else { return }
        let drift = Drift(key: key, pinned: "", current: written)
        do {
            try confirm(profile: profile, drifts: [drift], appSupport: appSupport)
        } catch {
            let reason = error.localizedDescription
            AppLogger.collect.warning(
                "SharedConfigPin: did not confirm \(key.rawValue): \(reason, privacy: .private)")
        }
    }

    static func confirmBestEffort(
        profile: String, keys: Set<Key>, appSupport: URL = AppSupport.directory()
    ) {
        do {
            try confirm(profile: profile, keys: keys, appSupport: appSupport)
        } catch {
            let reason = error.localizedDescription
            AppLogger.collect.warning(
                "SharedConfigPin: could not confirm the written config: \(reason, privacy: .private)")
        }
    }

    // MARK: - Effective values

    /// `retention` with the drifted keys put back to a safe value: a changed mode archives,
    /// never deletes, a changed `enabled` keeps the pinned setting, and a changed
    /// `archive_dir` reads as the default `_archive` in the workspace.
    static func effectiveRetention(_ config: RetentionConfig?, check: Check) -> RetentionConfig? {
        guard var safe = config else { return config }
        if check.isDrifted(.retentionMode) { safe.mode = RetentionConfig.Mode.archive.rawValue }
        if check.isDrifted(.retentionEnabled) {
            safe.enabled = check.pinned?.retentionEnabled ?? false
        }
        if check.isDrifted(.retentionArchiveDir) { safe.archiveDir = nil }
        return safe
    }

    /// `notify` as this Mac may use it: nil when the webhook host differs from the pinned one
    /// (no send), `minimal` detail when the detail level changed, and the pinned heartbeat
    /// setting when that changed.
    static func effectiveNotify(
        _ notify: NotifyConfig?, profile: String, appSupport: URL = AppSupport.directory()
    ) -> NotifyConfig? {
        guard var safe = notify else { return nil }
        let result = check(profile: profile, appSupport: appSupport)
        if result.isDrifted(.notifyURL) { return nil }
        if result.isDrifted(.notifyDetail) { safe.detail = NotifyConfig.Detail.minimal.rawValue }
        if result.isDrifted(.notifyHeartbeat) {
            safe.heartbeat = result.pinned?.notifyHeartbeat ?? false
        }
        return safe
    }

    /// Whether this run may send to the authority it loaded, `typed` (`output.timestamp_authority`
    /// as the run's config holds it): always on a workspace that is not pinned; on a pinned one
    /// only when `typed` is the confirmed pinned value (same SHA-256), so neither a peer's edit
    /// nor one made after the run loaded its config is used.
    static func timestampAuthorityAllowed(
        _ typed: String, profile: String, appSupport: URL = AppSupport.directory()
    ) -> Bool {
        let result = check(profile: profile, appSupport: appSupport)
        guard let pin = result.pinned else { return result.isLocal }
        let value = typed.trimmingCharacters(in: .whitespaces)
        return !result.isDrifted(.timestampAuthority)
            && pin.timestampAuthorityHash == (value.isEmpty ? "" : sha256Hex(value))
    }

    /// False when `protect.profile` differs from the pinned one: Protect is not collected and
    /// the dashboard does not include it.
    static func protectAllowed(profile: String, appSupport: URL = AppSupport.directory()) -> Bool {
        !check(profile: profile, appSupport: appSupport).isDrifted(.protectProfile)
    }

    /// `protect.backup_on_synced_storage` as this Mac may use it: on only while config.yaml
    /// says true and that matches a confirmed pin. A change to false applies at once and is
    /// pinned (`check`); a change to true, or a true first seen, waits for a Confirm here.
    static func protectBackupOnSyncedStorage(
        _ configured: Bool, profile: String, appSupport: URL = AppSupport.directory()
    ) -> Bool {
        configured && !check(profile: profile, appSupport: appSupport)
            .isDrifted(.protectBackupOnSyncedStorage)
    }

    /// `backup.pro_on_synced_storage` as this Mac may use it, by the same rule. An absent key is
    /// `notChosen`, which is not a no; a true that waits for a Confirm is its own state.
    static func proBackupSetting(
        _ configured: Bool?, profile: String, appSupport: URL = AppSupport.directory()
    ) -> ProBackup.Setting {
        guard let configured else { return .notChosen }
        guard configured else { return .declined }
        return check(profile: profile, appSupport: appSupport).isDrifted(.proBackupOnSyncedStorage)
            ? .awaitingConfirmation : .allowed
    }

    /// Whether this Mac holds a pin for `profile`, which only a shared workspace ever gets: the
    /// workspace was shared once, whatever config.yaml says now.
    static func hasPin(profile: String, appSupport: URL = AppSupport.directory()) -> Bool {
        storeURL(workspace: profile, appSupport: appSupport)
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: - Folder overrides

    /// Which path keys read as their safe value: the folders and the opt-in that differ from
    /// this Mac's pin, or wait for a Confirm.
    struct PathOverrides: Sendable, Equatable {
        var outputDir = false
        var archiveDir = false
        var dataDir = false
        var historicalDir = false
        var absolutePaths = false
        var historyFile = false
        var logoPath = false
        var isEmpty: Bool { self == PathOverrides() }

        func union(_ other: PathOverrides) -> PathOverrides {
            var merged = self
            merged.outputDir = outputDir || other.outputDir
            merged.archiveDir = archiveDir || other.archiveDir
            merged.dataDir = dataDir || other.dataDir
            merged.historicalDir = historicalDir || other.historicalDir
            merged.absolutePaths = absolutePaths || other.absolutePaths
            merged.historyFile = historyFile || other.historyFile
            merged.logoPath = logoPath || other.logoPath
            return merged
        }

        init() {}

        init(_ check: Check) {
            outputDir = check.isDrifted(.outputDir)
            archiveDir = check.isDrifted(.archiveDir)
            dataDir = check.isDrifted(.dataDir)
            historicalDir = check.isDrifted(.historicalDir)
            absolutePaths = check.isDrifted(.allowAbsolutePaths)
            historyFile = check.isDrifted(.htmlHistoryFile)
            logoPath = check.isDrifted(.brandingLogoPath)
        }
    }

    /// config.yaml's content digest: a peer's in-place edit that keeps the length and restores
    /// the modification time (possible on SMB) still changes it.
    private static func contentDigest(of url: URL) -> String? {
        guard let data = try? ConfigLoader.readData(at: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The pin's change marker (a per-Mac file no peer writes): an atomic replace changes the
    /// inode, a plain write the time.
    private struct FileStamp: Equatable, Sendable {
        let modified: Date
        let size: Int
        let inode: Int

        init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.modified = modified
            size = (attributes[.size] as? Int) ?? 0
            inode = (attributes[.systemFileNumber] as? Int) ?? 0
        }
    }

    private struct CachedOverrides: Sendable {
        let profiles: [String]
        let config: String?
        let pins: [FileStamp?]
        let overrides: PathOverrides
    }

    /// By workspace. A lookup hashes config.yaml and stats the pin while neither changed;
    /// `WorkspacePaths` asks on every read, from about forty places.
    private static let overridesCache = OSAllocatedUnfairLock(
        initialState: [String: CachedOverrides]())

    /// Run at the start of a collect or generate: checks the pin and logs one `[warn]` per
    /// drifted key (once per scheduled run for the same value). The safe folders themselves
    /// apply on every read in every context (`pathOverrides`), not only after this call.
    @discardableResult
    static func checkpoint(
        profile: String,
        appSupport: URL = AppSupport.directory(),
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> Check {
        let result = check(profile: profile, appSupport: appSupport)
        guard let workspace = result.workspace else { return result }
        invalidateOverrides(for: workspace)
        for note in result.notes {
            AppLogger.collect.warning("\(note, privacy: .private)")
            onLine?(.init(timestamp: Date(), level: .warn, text: note))
        }
        let id = overrideID(workspace)
        let fresh = result.drifts.filter { drift in
            announcements?.seen.withLock {
                $0.insert("\(id)|\(drift.key.rawValue)|\(drift.currentToken)").inserted
            } ?? true
        }
        for drift in fresh {
            let text = "[warn] shared config changed \(drift.key.rawValue): "
                + "confirm on this Mac (Config Doctor)"
            AppLogger.collect.warning("\(text, privacy: .private)")
            onLine?(.init(timestamp: Date(), level: .warn, text: text))
        }
        return result
    }

    /// The overrides in force for `workspace`, for every caller (a scheduled run, the CLI, a
    /// button in the app). Empty for a local workspace, a folder that is not a profile's
    /// workspace and a clean pin. A workspace with no pin yet is judged as its first sight
    /// would be, without writing the pin.
    static func pathOverrides(workspace: URL) -> PathOverrides {
        let id = overrideID(workspace)
        let support = AppSupport.resolved(home: FileManager.default.homeDirectoryForCurrentUser)
        let digest = contentDigest(of: workspace.appendingPathComponent("config.yaml"))
        let pinStamps = { (names: [String]) in
            names.compactMap {
                storeURL(workspace: $0, appSupport: support).map(FileStamp.init(of:))
            }
        }
        if let cached = overridesCache.withLock({ $0[id] }), cached.config == digest,
           cached.pins == pinStamps(cached.profiles) {
            return cached.overrides
        }
        let candidates = profiles(forWorkspace: workspace)
        // A candidate with a pin is this Mac's profile for the folder; first-sight judgement
        // applies only when none has one (another folder name resolving here is not a profile).
        let pinned = candidates.filter { hasPin(profile: $0, appSupport: support) }
        let profiles = pinned.isEmpty ? candidates : pinned
        guard !profiles.isEmpty else { return PathOverrides() }
        let stamps = pinStamps(profiles)
        let overrides = profiles.reduce(PathOverrides()) { merged, profile in
            let check = check(profile: profile, appSupport: support, persist: false)
            return merged.union(PathOverrides(check))
        }
        overridesCache.withLock {
            $0[id] = CachedOverrides(
                profiles: profiles, config: digest, pins: stamps, overrides: overrides)
        }
        return overrides
    }

    /// The profiles whose workspace folder is `workspace`, found by resolving each folder under
    /// the workspaces root, so a profile folder that is a symlink to a folder of another name
    /// still finds its pin. Several that resolve to one folder all apply; the stricter wins.
    private static func profiles(forWorkspace workspace: URL) -> [String] {
        let id = overrideID(workspace)
        let matches = { (name: String) -> Bool in
            ProfileService.workspaceURL(for: name).map { overrideID($0) == id } ?? false
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: ProfileService.workspacesRoot().path)) ?? []
        return entries.compactMap(ProfileName.name(fromPathComponent:)).filter(matches).sorted()
    }

    private static func invalidateOverrides(for workspace: URL) {
        overridesCache.withLock { _ = $0.removeValue(forKey: overrideID(workspace)) }
    }

    /// The drifts one run has already reported, so its collect and generate say each once.
    final class RunAnnouncements: Sendable {
        fileprivate let seen = OSAllocatedUnfairLock(initialState: Set<String>())
    }

    @TaskLocal private static var announcements: RunAnnouncements?

    /// Runs one scheduled run: a checkpoint inside it reports each drifted key once. Outside
    /// such a run (a button press in the app, one CLI command) every checkpoint reports.
    static func announcingOnce<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        // Nested inside another run (a generate inside collect-then-generate): keep its record.
        try await $announcements.withValue(
            announcements ?? RunAnnouncements(), operation: body, isolation: isolation)
    }

    /// One sentence for an export a person started that landed in the workspace's default
    /// folder because the shared config.yaml changed a folder key this Mac has not confirmed;
    /// nil when `folder` is the one config.yaml names.
    static func outputFolderNote(profile: String, folder: URL) -> String? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        let overrides = pathOverrides(workspace: workspace)
        let key: String
        if overrides.outputDir {
            key = Key.outputDir.rawValue
        } else if overrides.absolutePaths,
                  folder.lastPathComponent == WorkspacePaths.generatedReportsDirName {
            key = Key.allowAbsolutePaths.rawValue
        } else {
            return nil
        }
        return "Saved in the workspace's \(WorkspacePaths.generatedReportsDirName) folder: "
            + "\(key) changed in the shared config.yaml, not confirmed on this Mac (Config Doctor)."
    }

    /// The safe value `WorkspacePaths` reads in place of config.yaml's, or nil for the file's.
    static func safePathValue(workspace: URL, section: String, key: String) -> Any? {
        let overrides = pathOverrides(workspace: workspace)
        switch (section, key) {
        case ("output", "output_dir") where overrides.outputDir: return ""
        case ("output", "archive_dir") where overrides.archiveDir: return ""
        case ("jamf_cli", "data_dir") where overrides.dataDir: return ""
        case ("charts", "historical_csv_dir") where overrides.historicalDir: return ""
        case ("output", "allow_absolute_paths") where overrides.absolutePaths: return false
        case ("html", "history_file") where overrides.historyFile: return ""
        case ("branding", "logo_path") where overrides.logoPath: return ""
        default: return nil
        }
    }

    private static func overrideID(_ workspace: URL) -> String {
        workspace.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension SharedConfigPin {
    /// Every field is optional on disk, so a pin written before a key was added still reads.
    /// A key it lacks compares as empty, which is a drift when config.yaml sets it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowAbsolutePaths = try c.decodeIfPresent(Bool.self, forKey: .allowAbsolutePaths) ?? false
        outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? ""
        archiveDir = try c.decodeIfPresent(String.self, forKey: .archiveDir) ?? ""
        dataDir = try c.decodeIfPresent(String.self, forKey: .dataDir) ?? ""
        retentionEnabled = try c.decodeIfPresent(Bool.self, forKey: .retentionEnabled) ?? false
        retentionMode = try c.decodeIfPresent(String.self, forKey: .retentionMode) ?? "archive"
        retentionArchiveDir = try c.decodeIfPresent(String.self, forKey: .retentionArchiveDir) ?? ""
        sharedEnabled = try c.decodeIfPresent(String.self, forKey: .sharedEnabled) ?? ""
        historicalDir = try c.decodeIfPresent(String.self, forKey: .historicalDir) ?? ""
        protectProfile = try c.decodeIfPresent(String.self, forKey: .protectProfile) ?? ""
        notifyDetail = try c.decodeIfPresent(String.self, forKey: .notifyDetail) ?? "full"
        unconfirmed = try c.decodeIfPresent([String].self, forKey: .unconfirmed) ?? []
        // A pin from before `pinnedKeys` held the keys whose fields it has.
        let held: [(Key, CodingKeys)] = [
            (.allowAbsolutePaths, .allowAbsolutePaths), (.outputDir, .outputDir),
            (.archiveDir, .archiveDir), (.dataDir, .dataDir), (.historicalDir, .historicalDir),
            (.retentionEnabled, .retentionEnabled), (.retentionMode, .retentionMode),
            (.retentionArchiveDir, .retentionArchiveDir), (.sharedEnabled, .sharedEnabled),
            (.protectProfile, .protectProfile), (.notifyDetail, .notifyDetail),
            (.notifyURL, .notifyURLHash), (.htmlHistoryFile, .htmlHistoryFile),
            (.brandingLogoPath, .brandingLogoPath),
        ]
        pinnedKeys = try c.decodeIfPresent([String].self, forKey: .pinnedKeys)
            ?? held.filter { c.contains($0.1) }.map(\.0.rawValue)
        notifyURLHost = try c.decodeIfPresent(String.self, forKey: .notifyURLHost) ?? ""
        notifyURLHash = try c.decodeIfPresent(String.self, forKey: .notifyURLHash) ?? ""
        htmlHistoryFile = try c.decodeIfPresent(String.self, forKey: .htmlHistoryFile) ?? ""
        brandingLogoPath = try c.decodeIfPresent(String.self, forKey: .brandingLogoPath) ?? ""
        notifyHeartbeat = try c.decodeIfPresent(Bool.self, forKey: .notifyHeartbeat) ?? false
        protectBackupOnSyncedStorage = try c.decodeIfPresent(
            Bool.self, forKey: .protectBackupOnSyncedStorage) ?? false
        proBackupOnSyncedStorage = try c.decodeIfPresent(
            Bool.self, forKey: .proBackupOnSyncedStorage) ?? false
        timestampAuthorityHost = try c.decodeIfPresent(
            String.self, forKey: .timestampAuthorityHost) ?? ""
        timestampAuthorityHash = try c.decodeIfPresent(
            String.self, forKey: .timestampAuthorityHash) ?? ""
    }
}
