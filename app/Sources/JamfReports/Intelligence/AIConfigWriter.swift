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
        root.set("ai", value: encode(config))
        document.root = .mapping(root)

        let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: ["ai"])
        let tempURL = workspace.appendingPathComponent(".config.yaml.\(UUID().uuidString).tmp")
        try encoded.write(to: tempURL, atomically: true, encoding: .utf8)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: Data())
        }
        _ = try manager.replaceItemAt(url, withItemAt: tempURL)
    }

    private static func encode(_ config: AIConfig) -> YAMLCodec.YAMLValue {
        var entries: [YAMLCodec.YAMLEntry] = [
            .init(key: "enabled", value: .scalar(.bool(config.isEnabled))),
            .init(key: "tier", value: .scalar(.string(config.resolvedTier.rawValue))),
            .init(key: "reasoning_level", value: .scalar(.string(config.resolvedReasoningLevel.rawValue))),
        ]
        if let external = config.external {
            entries.append(.init(key: "external", value: encodeExternal(external)))
        }
        return .mapping(.init(entries: entries))
    }

    private static func encodeExternal(_ external: AIExternalConfig) -> YAMLCodec.YAMLValue {
        .mapping(.init(entries: [
            .init(key: "provider", value: .scalar(.string(external.provider ?? ""))),
            .init(key: "endpoint", value: .scalar(.string(external.endpoint ?? ""))),
            .init(key: "keychain_key", value: .scalar(.string(external.keychainKey ?? ""))),
        ]))
    }
}
