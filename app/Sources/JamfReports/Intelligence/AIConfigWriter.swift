import Foundation

/// Scoped write-back for the `ai:` config.yaml block, used by the Settings
/// panel toggles. Deliberately NOT routed through `ConfigService.save`/
/// `managedTopLevelKeys` — that surface round-trips a fixed key list for the
/// full Config tab editor, and adding `ai` there would put this block under
/// that save contract. `ConfigService.saveBlock` rewrites only the `ai:`
/// top-level block; every other key (managed or not) is preserved verbatim.
enum AIConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    /// Sets the three keys Settings models on `root`'s `ai:` block and keeps any other key
    /// typed in it, but drops the retired `lock_on_device` and `external:`, which nothing
    /// reads any more.
    static func apply(_ config: AIConfig, to root: inout YAMLCodec.YAMLMapping) {
        var ai = root.value(for: "ai")?.mapping ?? .init(entries: [])
        ai.entries.removeAll { $0.key == "lock_on_device" || $0.key == "external" }
        ai.set("enabled", value: .scalar(.bool(config.isEnabled)))
        ai.set("tier", value: .scalar(.string(config.resolvedTier.rawValue)))
        ai.set(
            "reasoning_level",
            value: .scalar(.string(config.resolvedReasoningLevel.rawValue)))
        root.set("ai", value: .mapping(ai))
    }

    @discardableResult
    static func save(
        _ config: AIConfig, profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        return try ConfigService.saveBlock(key: "ai", profile: profile) {
            apply(config, to: &$0)
        }
    }
}
