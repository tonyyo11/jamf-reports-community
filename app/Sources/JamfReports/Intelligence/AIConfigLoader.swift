import Foundation

/// Best-effort, read-only access to a profile's `ai:` config block for the
/// SwiftUI layer. Never throws: a missing workspace/file or a corrupt config
/// degrades to `AIConfig()` (disabled) rather than surfacing a config error in
/// the AI card — ConfigView/AuditView already own that failure mode.
///
/// `AIConfig` intentionally does NOT round-trip through `ConfigService`/
/// `ConfigState` (the GUI Config tab's managed-key editor): that surface has a
/// fixed key list and adding `ai` there would put this block under the full
/// Config-tab save contract. Reads go straight through `ConfigLoader`, mirroring
/// how `CLIBridge.loadConfig` handles the same file.
enum AIConfigLoader {
    static func load(profile: String) -> AIConfig {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return AIConfig() }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return AIConfig() }
        return (try? ConfigLoader.load(from: url))?.ai ?? AIConfig()
    }
}
