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
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    /// Sets the four keys this panel models on `root`'s `notify:` block and keeps any other
    /// key typed in it. The URL is trimmed.
    static func apply(
        enabled: Bool, provider: String, url: String, detail: String,
        to root: inout YAMLCodec.YAMLMapping
    ) {
        var notify = root.value(for: "notify")?.mapping ?? .init(entries: [])
        notify.set("enabled", value: .scalar(.bool(enabled)))
        notify.set("provider", value: .scalar(.string(provider)))
        notify.set("url", value: .scalar(.string(url.trimmingCharacters(in: .whitespaces))))
        notify.set("detail", value: .scalar(.string(detail)))
        root.set("notify", value: .mapping(notify))
    }

    /// Persist the four `notify:` fields. No validation beyond the trim in `apply` —
    /// `NotifyConfig.isUsable` gates every send path, so an empty or non-https URL simply
    /// produces a disabled block.
    @discardableResult
    static func save(
        enabled: Bool, provider: String, url: String, detail: String, profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        let saved = try ConfigService.saveBlock(key: "notify", profile: profile) {
            apply(enabled: enabled, provider: provider, url: url, detail: detail, to: &$0)
        }
        // The webhook typed on this Mac is the one this Mac should keep using.
        do {
            try SharedConfigPin.confirm(profile: profile, keys: [.notifyURL])
        } catch {
            AppLogger.webhook.warning(
                "SharedConfigPin: could not confirm after save: \(error.localizedDescription, privacy: .public)")
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
}
