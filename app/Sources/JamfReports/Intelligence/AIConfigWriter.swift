import Foundation

/// Scoped write-back for the `ai:` config.yaml block, used by the Settings
/// panel toggles. Deliberately NOT routed through `ConfigService.save`/
/// `managedTopLevelKeys` — that surface round-trips a fixed key list for the
/// full Config tab editor, and adding `ai` there would put this block under
/// that save contract. `YAMLCodec.encode(replacingTopLevelKeys: ["ai"])`
/// rewrites only the `ai:` top-level block; every other key (managed or not)
/// is preserved verbatim, same atomic-write discipline as `ConfigService.save`.
enum AIConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    static func save(_ config: AIConfig, profile: String) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            throw WriteError.invalidProfile(profile)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let url = workspace.appendingPathComponent("config.yaml")

        var document: YAMLCodec.YAMLDocument
        if manager.fileExists(atPath: url.path) {
            document = try YAMLCodec.decode(String(contentsOf: url, encoding: .utf8))
        } else {
            document = YAMLCodec.emptyDocument()
        }

        guard case .mapping(var root) = document.root else { return }
        // Sets the three keys Settings models and keeps any other key typed in the block, but
        // drops the retired `lock_on_device` and `external:`, which nothing reads any more.
        var ai = root.value(for: "ai")?.mapping ?? .init(entries: [])
        ai.entries.removeAll { $0.key == "lock_on_device" || $0.key == "external" }
        ai.set("enabled", value: .scalar(.bool(config.isEnabled)))
        ai.set("tier", value: .scalar(.string(config.resolvedTier.rawValue)))
        ai.set(
            "reasoning_level",
            value: .scalar(.string(config.resolvedReasoningLevel.rawValue)))
        root.set("ai", value: .mapping(ai))
        document.root = .mapping(root)

        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: ["ai"])
        let tempURL = workspace.appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: Data())
        }
        _ = try manager.replaceItemAt(url, withItemAt: tempURL)
    }
}
