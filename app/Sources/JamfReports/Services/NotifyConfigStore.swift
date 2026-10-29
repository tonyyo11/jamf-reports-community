import Foundation

/// Best-effort, read-only access to a profile's `notify:` config block for the
/// SwiftUI layer. Never throws: a missing workspace/file or a corrupt config
/// degrades to `NotifyConfig()` (disabled) rather than surfacing a config error
/// in the Automation screen — ConfigView/AuditView already own that failure mode.
///
/// `NotifyConfig` intentionally does NOT round-trip through `ConfigService`/
/// `ConfigState` (the GUI Config tab's managed-key editor): that surface has a
/// fixed key list and adding `notify` there would put this block under the full
/// Config-tab save contract. Reads go straight through `ConfigLoader`, mirroring
/// how `AIConfigLoader` and `CLIBridge.loadConfig` handle the same file.
enum NotifyConfigLoader {
    static func load(profile: String) -> NotifyConfig {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return NotifyConfig() }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return NotifyConfig() }
        return (try? ConfigLoader.load(from: url))?.notify ?? NotifyConfig()
    }

    /// Only the `notify:` block of the config.yaml at `url`, for a config.yaml the full decode
    /// rejects (a mistyped threshold must not silence the failure card or the overdue digest it
    /// would have raised). Nil when the file, the block or the block's values cannot be read.
    static func scoped(at url: URL) -> NotifyConfig? {
        guard let text = try? ConfigLoader.readText(at: url),
              let root = try? ConfigLoader.rawMapping(fromYAML: text),
              let block = ConfigLoader.rawValue(at: ["notify"], in: root) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: block)
        else { return nil }
        return try? JSONDecoder().decode(NotifyConfig.self, from: data)
    }
}

/// Scoped write-back for the `notify:` config.yaml block, used by the Automation
/// screen's Notifications panel. Deliberately NOT routed through
/// `ConfigService.save`/`managedTopLevelKeys` — that surface round-trips a fixed
/// key list for the full Config tab editor, and adding `notify` there would put
/// this block under that save contract. `ConfigService.saveBlock` rewrites only
/// the `notify:` top-level block; every other key (managed or not) is preserved
/// verbatim.
enum NotifyConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): ProfileName.invalidMessage(profile)
            }
        }
    }

    /// Sets the keys this panel models on `root`'s `notify:` block and keeps any other
    /// key typed in it. The URL is trimmed. A nil `heartbeat` leaves that key as typed; false
    /// is written only where the file already sets the key.
    static func apply(
        enabled: Bool, provider: String, url: String, detail: String, heartbeat: Bool? = nil,
        to root: inout YAMLCodec.YAMLMapping
    ) {
        var notify = root.value(for: "notify")?.mapping ?? .init(entries: [])
        notify.set("enabled", value: .scalar(.bool(enabled)))
        notify.set("provider", value: .scalar(.string(provider)))
        notify.set("url", value: .scalar(.string(url.trimmingCharacters(in: .whitespaces))))
        notify.set("detail", value: .scalar(.string(detail)))
        if let heartbeat, heartbeat || notify.value(for: "heartbeat") != nil {
            notify.set("heartbeat", value: .scalar(.bool(heartbeat)))
        }
        root.set("notify", value: .mapping(notify))
    }

    /// Persist the `notify:` fields. No validation beyond the trim in `apply` —
    /// `NotifyConfig.isUsable` gates every send path, so an empty or non-https URL simply
    /// produces a disabled block.
    @discardableResult
    static func save(
        enabled: Bool, provider: String, url: String, detail: String, heartbeat: Bool? = nil,
        profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        let previous = NotifyConfigLoader.load(profile: profile)
        let saved = try ConfigService.saveBlock(key: "notify", profile: profile) {
            apply(
                enabled: enabled, provider: provider, url: url, detail: detail,
                heartbeat: heartbeat, to: &$0)
        }
        // A webhook or detail level typed on this Mac is the one this Mac keeps using; a save
        // that leaves a value as it was does not confirm a peer's.
        let changed = SharedConfigPin.changedNotifyKeys(
            previousURL: previous.resolvedURL, newURL: url,
            previousDetail: previous.detail, newDetail: detail,
            previousHeartbeat: previous.sendsHeartbeat, newHeartbeat: heartbeat)
        do {
            if !changed.isEmpty { try SharedConfigPin.confirm(profile: profile, keys: changed) }
        } catch {
            let reason = error.localizedDescription
            AppLogger.webhook.warning(
                "SharedConfigPin: could not confirm after save: \(reason, privacy: .private)")
        }
        return saved
    }

    /// Pure predicate behind the inline "URL must start with https://" caption:
    /// true when the panel should warn (enabled + a non-empty URL that is not an
    /// https:// URL). Extracted so the caption condition is unit-testable.
    static func showsInsecureURLWarning(enabled: Bool, url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard enabled, !trimmed.isEmpty else { return false }
        return !trimmed.lowercased().hasPrefix("https://")
    }

    /// True when notifications are on with no URL: no card, the heartbeat included, is sent.
    static func showsMissingURLWarning(enabled: Bool, url: String) -> Bool {
        enabled && url.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
