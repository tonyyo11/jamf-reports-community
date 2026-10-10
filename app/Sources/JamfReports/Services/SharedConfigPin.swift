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
/// A local workspace is never pinned. Pinning applies when `shared_workspace.enabled` is true, the
/// folder is on a sync provider or `/Volumes`, or a pin already exists; an opt-out written into
/// the shared file never turns an existing pin off, since a peer could write it.
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
    /// `host` or `host:port` of the webhook URL. The URL itself is a credential and never
    /// leaves config.yaml; `notifyURLHash` is its SHA-256, so a changed path or token drifts too.
    var notifyURLHost: String
    var notifyURLHash: String = ""

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
            case .notifyURL:
                pin.notifyURLHash.isEmpty
                    ? pin.notifyURLHost
                    : "\(pin.notifyURLHost) (URL fingerprint \(pin.notifyURLHash.prefix(8)))"
            }
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
            case .notifyURL:
                pin.notifyURLHost = source.notifyURLHost
                pin.notifyURLHash = source.notifyURLHash
            }
        }
    }

    struct Drift: Sendable, Equatable {
        let key: Key
        let pinned: String
        let current: String
    }

    /// Each key whose value differs, in `Key.allCases` order.
    static func diff(pinned: SharedConfigPin, current: SharedConfigPin) -> [Drift] {
        Key.allCases.compactMap { key in
            let was = key.text(of: pinned)
            let now = key.text(of: current)
            return was == now ? nil : Drift(key: key, pinned: was, current: now)
        }
    }

    static let firstSightNote = "(first seen, not confirmed)"

    /// The pin for a workspace seen for the first time. What is already in the shared file may
    /// have been written by a peer, so a folder outside the workspace and a `delete` retention
    /// are pinned as unconfirmed: headless runs use the safe value for them until one Confirm.
    /// The webhook host and the other keys are trust-on-first-use.
    static func firstPin(current: SharedConfigPin, workspace: URL) -> SharedConfigPin {
        var pin = current
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        func outside(_ value: String) -> Bool {
            guard value.hasPrefix("/") else { return false }
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            return path != root && !path.hasPrefix(root + "/")
        }
        let folders: [(Key, String)] = [
            (.outputDir, current.outputDir), (.archiveDir, current.archiveDir),
            (.dataDir, current.dataDir), (.historicalDir, current.historicalDir),
            (.retentionArchiveDir, current.retentionArchiveDir),
        ]
        var keys = folders.filter { outside($0.1) }.map(\.0)
        if current.retentionMode == RetentionConfig.Mode.delete.rawValue { keys.append(.retentionMode) }
        pin.unconfirmed = keys.map(\.rawValue)
        return pin
    }

    // MARK: - Reading config.yaml

    /// The pinned values as config.yaml holds them now, read the way `WorkspacePaths`,
    /// `RetentionConfig` and `NotifyConfig` read them. Nil when the file is missing or unreadable.
    static func current(workspace: URL) -> SharedConfigPin? {
        let url = workspace.appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
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
            protectProfile: ((raw("protect", "profile") as? String) ?? "")
                .trimmingCharacters(in: .whitespaces),
            notifyDetail: notifyDetail,
            notifyURLHost: webhookHost(typedURL),
            notifyURLHash: typedURL.isEmpty ? "" : SharedConfigPin.sha256Hex(typedURL)
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

    /// `<AppSupport>/shared-config-pin-<profile>.json`, 0600.
    static func storeURL(profile: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent(
            "shared-config-pin-\(ProfileName.pathComponent(profile)).json")
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
        let url = storeURL(profile: profile, appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let pin = try? JSONDecoder().decode(SharedConfigPin.self, from: data)
        else { return .unreadable }
        return .pin(pin)
    }

    static func load(profile: String, appSupport: URL) -> SharedConfigPin? {
        read(profile: profile, appSupport: appSupport).pin
    }

    static func save(_ pin: SharedConfigPin, profile: String, appSupport: URL) throws {
        let url = storeURL(profile: profile, appSupport: appSupport)
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

        func isDrifted(_ key: Key) -> Bool { drifts.contains { $0.key == key } }
    }

    /// Compares config.yaml with this Mac's pin. A shared workspace with no pin yet pins what it
    /// holds now (the values the operator set up with) and reports no drift.
    static func check(profile: String, appSupport: URL = AppSupport.directory()) -> Check {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return Check(workspace: nil, pinned: nil, drifts: [])
        }
        guard let current = sharedCurrent(
            profile: profile, workspace: workspace, appSupport: appSupport) else {
            return Check(workspace: workspace, pinned: nil, drifts: [])
        }
        switch read(profile: profile, appSupport: appSupport) {
        case .absent:
            var notes: [String] = []
            let first = firstPin(current: current, workspace: workspace)
            do {
                try save(first, profile: profile, appSupport: appSupport)
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
                Drift(key: $0, pinned: "(pin unreadable)", current: $0.text(of: current))
            }
            return Check(workspace: workspace, pinned: nil, drifts: drifts)
        case .pin(let pinned):
            let changed = diff(pinned: pinned, current: current)
            return Check(workspace: workspace, pinned: pinned,
                         drifts: unconfirmedDrifts(pin: pinned, current: current, among: changed))
        }
    }

    /// `changed` plus the first-sight keys still awaiting a Confirm, in `Key.allCases` order.
    private static func unconfirmedDrifts(
        pin: SharedConfigPin, current: SharedConfigPin, among changed: [Drift]
    ) -> [Drift] {
        let waiting = pin.unconfirmed.compactMap(Key.init(rawValue:))
            .filter { key in !changed.contains { $0.key == key } }
            .map { Drift(key: $0, pinned: firstSightNote, current: $0.text(of: current)) }
        return (changed + waiting).sorted {
            Key.allCases.firstIndex(of: $0.key)! < Key.allCases.firstIndex(of: $1.key)!
        }
    }

    /// Whether a workspace is pinned. Unlike `SharedWorkspace.isEffectivelyShared`, which
    /// coordination uses, `shared_workspace.enabled: false` does not opt out: the file is
    /// writable by every peer, so an opt-out beside hostile values would switch pinning off.
    static func appliesTo(sharedEnabled: Bool?, onSyncProvider: Bool, pinExists: Bool) -> Bool {
        sharedEnabled == true || onSyncProvider || pinExists
    }

    /// `current(workspace:)` for a workspace that is pinned; nil for a local one.
    private static func sharedCurrent(
        profile: String, workspace: URL, appSupport: URL
    ) -> SharedConfigPin? {
        let sharedConfig = (try? ConfigLoader.load(
            from: workspace.appendingPathComponent("config.yaml")))?.sharedWorkspace
        guard appliesTo(
            sharedEnabled: sharedConfig?.enabled,
            onSyncProvider: CloudStorage.provider(for: workspace) != nil,
            pinExists: FileManager.default.fileExists(
                atPath: storeURL(profile: profile, appSupport: appSupport).path))
        else { return nil }
        return current(workspace: workspace)
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
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let current = sharedCurrent(
                profile: profile, workspace: workspace, appSupport: appSupport)
        else { return }
        var pin: SharedConfigPin
        var unreadable = false
        switch read(profile: profile, appSupport: appSupport) {
        case .absent: pin = firstPin(current: current, workspace: workspace)
        case .pin(let stored): pin = stored
        case .unreadable: pin = firstPin(current: current, workspace: workspace); unreadable = true
        }
        var confirmed = 0
        for drift in drifts where drift.key.text(of: current) == drift.current {
            drift.key.copy(from: current, into: &pin)
            pin.unconfirmed.removeAll { $0 == drift.key.rawValue }
            confirmed += 1
        }
        if unreadable, confirmed < Key.allCases.count { throw ConfirmError.changedSinceShown }
        try save(pin, profile: profile, appSupport: appSupport)
        removeOverrides(for: workspace)
    }

    /// Re-pins `keys` to what config.yaml holds now, for a save on this Mac that changed them.
    /// Other keys stay as they are, drifted or not, and a pin that cannot be read stays so.
    static func confirm(
        profile: String, keys: Set<Key>, appSupport: URL = AppSupport.directory()
    ) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let current = sharedCurrent(
                profile: profile, workspace: workspace, appSupport: appSupport)
        else { return }
        var pin: SharedConfigPin
        switch read(profile: profile, appSupport: appSupport) {
        case .absent: pin = firstPin(current: current, workspace: workspace)
        case .pin(let stored): pin = stored
        case .unreadable: return
        }
        for key in keys {
            key.copy(from: current, into: &pin)
            pin.unconfirmed.removeAll { $0 == key.rawValue }
        }
        try save(pin, profile: profile, appSupport: appSupport)
        removeOverrides(for: workspace)
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

    /// The notification keys a save changed against what config.yaml held.
    static func changedNotifyKeys(
        previousURL: String, newURL: String, previousDetail: String?, newDetail: String
    ) -> Set<Key> {
        var keys: Set<Key> = []
        if previousURL.trimmingCharacters(in: .whitespaces)
            != newURL.trimmingCharacters(in: .whitespaces) { keys.insert(.notifyURL) }
        func level(_ value: String?) -> String {
            let text = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return text.isEmpty ? "full" : text
        }
        if level(previousDetail) != level(newDetail) { keys.insert(.notifyDetail) }
        return keys
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
    /// (no send), and `minimal` detail when the detail level changed.
    static func effectiveNotify(
        _ notify: NotifyConfig?, profile: String, appSupport: URL = AppSupport.directory()
    ) -> NotifyConfig? {
        guard var safe = notify else { return nil }
        let result = check(profile: profile, appSupport: appSupport)
        if result.isDrifted(.notifyURL) { return nil }
        if result.isDrifted(.notifyDetail) { safe.detail = NotifyConfig.Detail.minimal.rawValue }
        return safe
    }

    /// False when `protect.profile` differs from the pinned one: Protect is not collected and
    /// the dashboard does not include it.
    static func protectAllowed(profile: String, appSupport: URL = AppSupport.directory()) -> Bool {
        !check(profile: profile, appSupport: appSupport).isDrifted(.protectProfile)
    }

    // MARK: - Headless runs

    /// Which path keys a headless run reads as their safe value.
    struct PathOverrides: Sendable, Equatable {
        var outputDir = false
        var archiveDir = false
        var dataDir = false
        var historicalDir = false
        var absolutePaths = false
        var isEmpty: Bool { self == PathOverrides() }
    }

    private struct State {
        var headless = false
        var overrides: [String: PathOverrides] = [:]
        var warned: Set<String> = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// `--tick`, `--scheduled-run` and the `jamf-reports` CLI call this first: their runs
    /// then resolve a drifted folder to its safe value. The GUI does not, so its screens keep
    /// showing what config.yaml says and Config Doctor carries the drift.
    static func markHeadless(_ headless: Bool = true) {
        state.withLock {
            $0.headless = headless
            if !headless { $0.overrides = [:] }
        }
    }

    @TaskLocal private static var inUnattendedScope = false

    /// Runs an automatic collect (catch-up, self-remediation, the background refresh): nobody
    /// is at the keyboard, so inside `body` a checkpoint installs the safe path values as a
    /// headless run does, and they are removed again afterwards so the person's own
    /// actions keep reading config.yaml as typed.
    static func unattended<T: Sendable>(
        profile: String, _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        defer {
            if let workspace = ProfileService.workspaceURL(for: profile),
               !state.withLock({ $0.headless }) {
                removeOverrides(for: workspace)
            }
        }
        return try await $inUnattendedScope.withValue(true) { try await body() }
    }

    /// Run at the start of a collect or generate: checks the pin, logs one `[warn]` per drifted
    /// key (once per process for the same value), and in a headless run installs the safe
    /// path values for `WorkspacePaths`.
    @discardableResult
    static func checkpoint(
        profile: String,
        appSupport: URL = AppSupport.directory(),
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> Check {
        let result = check(profile: profile, appSupport: appSupport)
        guard let workspace = result.workspace else { return result }
        let overrides = PathOverrides(
            outputDir: result.isDrifted(.outputDir),
            archiveDir: result.isDrifted(.archiveDir),
            dataDir: result.isDrifted(.dataDir),
            historicalDir: result.isDrifted(.historicalDir),
            absolutePaths: result.isDrifted(.allowAbsolutePaths))
        for note in result.notes {
            AppLogger.collect.warning("\(note, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .warn, text: note))
        }
        let id = overrideID(workspace)
        let unattendedRun = inUnattendedScope
        let fresh: [Drift] = state.withLock { state in
            if state.headless || unattendedRun {
                state.overrides[id] = overrides.isEmpty ? nil : overrides
            }
            return result.drifts.filter {
                state.warned.insert("\(id)|\($0.key.rawValue)|\($0.current)").inserted
            }
        }
        for drift in fresh {
            let text = "[warn] shared config changed \(drift.key.rawValue): "
                + "confirm on this Mac (Config Doctor)"
            AppLogger.collect.warning("\(text, privacy: .public)")
            onLine?(.init(timestamp: Date(), level: .warn, text: text))
        }
        return result
    }

    /// The safe value `WorkspacePaths` reads in place of config.yaml's, or nil for the file's.
    static func safePathValue(workspace: URL, section: String, key: String) -> Any? {
        guard let overrides = state.withLock({ $0.overrides[overrideID(workspace)] }) else {
            return nil
        }
        switch (section, key) {
        case ("output", "output_dir") where overrides.outputDir: return ""
        case ("output", "archive_dir") where overrides.archiveDir: return ""
        case ("jamf_cli", "data_dir") where overrides.dataDir: return ""
        case ("charts", "historical_csv_dir") where overrides.historicalDir: return ""
        case ("output", "allow_absolute_paths") where overrides.absolutePaths: return false
        default: return nil
        }
    }

    private static func removeOverrides(for workspace: URL) {
        state.withLock { _ = $0.overrides.removeValue(forKey: overrideID(workspace)) }
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
        notifyURLHost = try c.decodeIfPresent(String.self, forKey: .notifyURLHost) ?? ""
        notifyURLHash = try c.decodeIfPresent(String.self, forKey: .notifyURLHash) ?? ""
    }
}
