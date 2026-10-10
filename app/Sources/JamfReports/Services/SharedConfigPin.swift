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
/// A local workspace is never pinned. "Shared" is `SharedWorkspace.isEffectivelyShared`.
struct SharedConfigPin: Codable, Sendable, Equatable {
    var allowAbsolutePaths: Bool
    var outputDir: String
    var archiveDir: String
    var dataDir: String
    var retentionEnabled: Bool
    var retentionMode: String
    /// Host only. The webhook URL itself is a credential and never leaves config.yaml.
    var notifyURLHost: String

    /// One pinned key, named as it is written in config.yaml.
    enum Key: String, CaseIterable, Sendable {
        case allowAbsolutePaths = "output.allow_absolute_paths"
        case outputDir = "output.output_dir"
        case archiveDir = "output.archive_dir"
        case dataDir = "jamf_cli.data_dir"
        case retentionEnabled = "retention.enabled"
        case retentionMode = "retention.mode"
        case notifyURL = "notify.url"

        fileprivate func text(of pin: SharedConfigPin) -> String {
            switch self {
            case .allowAbsolutePaths: String(pin.allowAbsolutePaths)
            case .outputDir: pin.outputDir
            case .archiveDir: pin.archiveDir
            case .dataDir: pin.dataDir
            case .retentionEnabled: String(pin.retentionEnabled)
            case .retentionMode: pin.retentionMode
            case .notifyURL: pin.notifyURLHost
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
            case .notifyURL: pin.notifyURLHost = source.notifyURLHost
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
            WorkspacePaths.expandTilde(
                ((raw(section, key) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let mode = ((raw("retention", "mode") as? String) ?? "").lowercased()
        let typedURL = ((raw("notify", "url") as? String) ?? "").trimmingCharacters(in: .whitespaces)
        return SharedConfigPin(
            allowAbsolutePaths: WorkspacePaths.optIn(raw("output", "allow_absolute_paths")) == true,
            outputDir: path("output", "output_dir"),
            archiveDir: path("output", "archive_dir"),
            dataDir: path("jamf_cli", "data_dir"),
            retentionEnabled: (raw("retention", "enabled") as? Bool) ?? false,
            retentionMode: RetentionConfig.Mode(rawValue: mode)?.rawValue ?? "archive",
            notifyURLHost: URL(string: typedURL)?.host?.lowercased() ?? ""
        )
    }

    // MARK: - Store

    /// `<AppSupport>/shared-config-pin-<profile>.json`, 0600.
    static func storeURL(profile: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent(
            "shared-config-pin-\(ProfileName.pathComponent(profile)).json")
    }

    static func load(profile: String, appSupport: URL) -> SharedConfigPin? {
        guard let data = try? Data(contentsOf: storeURL(profile: profile, appSupport: appSupport))
        else { return nil }
        do {
            return try JSONDecoder().decode(SharedConfigPin.self, from: data)
        } catch {
            AppLogger.collect.warning(
                "SharedConfigPin: pin for a profile could not be decoded, pinning again")
            return nil
        }
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

        func isDrifted(_ key: Key) -> Bool { drifts.contains { $0.key == key } }
    }

    /// Compares config.yaml with this Mac's pin. A shared workspace with no pin yet pins what it
    /// holds now (the values the operator set up with) and reports no drift.
    static func check(profile: String, appSupport: URL = AppSupport.directory()) -> Check {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return Check(workspace: nil, pinned: nil, drifts: [])
        }
        let sharedConfig = (try? ConfigLoader.load(
            from: workspace.appendingPathComponent("config.yaml")))?.sharedWorkspace
        guard SharedWorkspace.isEffectivelyShared(workspace: workspace, config: sharedConfig),
              let current = current(workspace: workspace) else {
            return Check(workspace: workspace, pinned: nil, drifts: [])
        }
        guard let pinned = load(profile: profile, appSupport: appSupport) else {
            do {
                try save(current, profile: profile, appSupport: appSupport)
            } catch {
                AppLogger.collect.warning(
                    "SharedConfigPin: could not record the pin: \(error.localizedDescription, privacy: .public)")
            }
            return Check(workspace: workspace, pinned: current, drifts: [])
        }
        return Check(workspace: workspace, pinned: pinned,
                     drifts: diff(pinned: pinned, current: current))
    }

    /// Re-pins `keys` (all of them when nil) to what config.yaml holds now. Other drifted keys
    /// stay drifted: a Config screen save that only writes the output folders must not
    /// confirm a peer's retention change.
    static func confirm(
        profile: String, keys: Set<Key>? = nil, appSupport: URL = AppSupport.directory()
    ) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let current = current(workspace: workspace) else { return }
        var pin = load(profile: profile, appSupport: appSupport) ?? current
        for key in keys ?? Set(Key.allCases) { key.copy(from: current, into: &pin) }
        try save(pin, profile: profile, appSupport: appSupport)
        removeOverrides(for: workspace)
    }

    // MARK: - Effective values

    /// `retention` with the drifted keys put back to a safe value: a changed mode archives,
    /// never deletes, and a changed `enabled` keeps the pinned setting.
    static func effectiveRetention(_ config: RetentionConfig?, check: Check) -> RetentionConfig? {
        guard var safe = config, let pinned = check.pinned else { return config }
        if check.isDrifted(.retentionMode) { safe.mode = RetentionConfig.Mode.archive.rawValue }
        if check.isDrifted(.retentionEnabled) { safe.enabled = pinned.retentionEnabled }
        return safe
    }

    /// False when the webhook host differs from the pinned one: no send.
    static func webhookAllowed(profile: String, appSupport: URL = AppSupport.directory()) -> Bool {
        !check(profile: profile, appSupport: appSupport).isDrifted(.notifyURL)
    }

    // MARK: - Headless runs

    /// Which path keys a headless run reads as their safe value.
    struct PathOverrides: Sendable, Equatable {
        var outputDir = false
        var archiveDir = false
        var dataDir = false
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
            absolutePaths: result.isDrifted(.allowAbsolutePaths))
        let id = overrideID(workspace)
        let fresh: [Drift] = state.withLock { state in
            if state.headless {
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
