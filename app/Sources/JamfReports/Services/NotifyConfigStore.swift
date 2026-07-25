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
/// this block under that save contract. `YAMLCodec.encode(replacingTopLevelKeys:
/// ["notify"])` rewrites only the `notify:` top-level block; every other key
/// (managed or not) is preserved verbatim, same atomic-write discipline as
/// `ConfigService.save` and `AIConfigWriter`.
enum NotifyConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)
        case invalidDocumentRoot

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            case .invalidDocumentRoot:
                "config.yaml's YAML root is not a mapping — cannot save the notify block."
            }
        }
    }

    /// Persist the four `notify:` fields. The URL is trimmed; no further
    /// validation is applied here — `NotifyConfig.isUsable` gates every send
    /// path, so an empty or non-https URL simply produces a disabled block.
    static func save(
        enabled: Bool, provider: String, url: String, detail: String, profile: String
    ) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            throw WriteError.invalidProfile(profile)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let configURL = workspace.appendingPathComponent("config.yaml")

        var document: YAMLCodec.YAMLDocument
        if manager.fileExists(atPath: configURL.path) {
            document = try YAMLCodec.decode(String(contentsOf: configURL, encoding: .utf8))
        } else {
            document = YAMLCodec.emptyDocument()
        }

        guard case .mapping(var root) = document.root else {
            throw WriteError.invalidDocumentRoot
        }
        root.set("notify", value: encode(
            enabled: enabled,
            provider: provider,
            url: url.trimmingCharacters(in: .whitespaces),
            detail: detail
        ))
        document.root = .mapping(root)

        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: ["notify"])
        let tempURL = workspace.appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: configURL.path) {
            manager.createFile(atPath: configURL.path, contents: Data())
        }
        _ = try manager.replaceItemAt(configURL, withItemAt: tempURL)
    }

    private static func encode(
        enabled: Bool, provider: String, url: String, detail: String
    ) -> YAMLCodec.YAMLValue {
        .mapping(.init(entries: [
            .init(key: "enabled", value: .scalar(.bool(enabled))),
            .init(key: "provider", value: .scalar(.string(provider))),
            .init(key: "url", value: .scalar(.string(url))),
            .init(key: "detail", value: .scalar(.string(detail))),
        ]))
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
