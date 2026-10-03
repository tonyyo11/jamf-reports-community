import Foundation

/// The key paths the app's screens write to config.yaml, read off the code that writes them:
/// `ConfigService.apply` for the Config screen's blocks, and each scoped writer's `apply`
/// (charts, notify, ai). A key added to an editor joins the set with no second list to
/// update. A path leaves out list indices (`custom_eas`, `name`), as `ConfigSchema` does.
enum ConfigEditedKeys {
    static let paths: Set<[String]> = derive()

    private static func derive() -> Set<[String]> {
        var document = YAMLCodec.emptyDocument()
        ConfigService.apply(state: probeState, to: &document)
        var root = document.root.mapping ?? .init(entries: [])
        ChartsConfigWriter.apply(.defaults, to: &root)
        NotifyConfigWriter.apply(
            enabled: false, provider: "teams", url: "", detail: "full", to: &root)
        AIConfigWriter.apply(AIConfig(), to: &root)
        var found: Set<[String]> = []
        collect(root, under: [], into: &found)
        return found
    }

    /// A state that sets every key the Config screen can write: the columns it writes only
    /// when set, and one entry of each custom EA type with all of that type's values.
    private static var probeState: ConfigState {
        var state = ConfigState.defaultState
        for key in ConfigState.optionalColumnKeys { state.columns[key] = "x" }
        state.securityAgents = [
            ConfigSecurityAgent(name: "x", column: "x", connectedValue: "x"),
        ]
        state.customEAs = ["boolean", "percentage", "version", "date", "text"].map { type in
            ConfigCustomEA(
                name: "x", column: "x", type: type, trueValue: "x", warningThreshold: "1",
                criticalThreshold: "2", currentVersions: ["x"], warningDays: "3")
        }
        state.complianceBenchmarks = ["x"]
        return state
    }

    private static func collect(
        _ mapping: YAMLCodec.YAMLMapping, under prefix: [String], into found: inout Set<[String]>
    ) {
        for entry in mapping.entries {
            let path = prefix + [entry.key]
            switch entry.value {
            case .mapping(let child) where !child.entries.isEmpty:
                collect(child, under: path, into: &found)
            case .sequence(let items) where items.contains { $0.mapping != nil }:
                for case .mapping(let item) in items { collect(item, under: path, into: &found) }
            default:
                found.insert(path)
            }
        }
    }
}
