import Foundation

/// The key paths the app's screens write to config.yaml, read off the code that writes them:
/// `ConfigService.apply` for the Config screen's blocks, and the `apply` of each scoped
/// writer (`ChartsConfigWriter`, `HTMLReportConfigWriter`, `NotifyConfigWriter`,
/// `AIConfigWriter`, `SecurityPolicyConfigWriter`). A key added to an editor joins the set
/// with no second list to update. A path leaves out list indices (`custom_eas`, `name`), as
/// `ConfigSchema` does.
enum ConfigEditedKeys {
    static let paths: Set<[String]> = derive()

    private static func derive() -> Set<[String]> {
        var document = YAMLCodec.emptyDocument()
        ConfigService.apply(state: probeState, to: &document)
        var root = document.root.mapping ?? .init(entries: [])
        ChartsConfigWriter.apply(.defaults, to: &root)
        HTMLReportConfigWriter.apply(withWorkbook: true, to: &root)
        NotifyConfigWriter.apply(
            enabled: false, provider: "teams", url: "", detail: "full", to: &root)
        AIConfigWriter.apply(AIConfig(), to: &root)
        root.set("security_policy", value: .mapping(securityPolicyProbe))
        var found: Set<[String]> = []
        collect(root, under: [], into: &found)
        return found
    }

    /// The block with every setting the Scoring tab writes, on an empty block: each control's
    /// level, FileVault's hardware level, and a factor list using every entry key.
    private static var securityPolicyProbe: YAMLCodec.YAMLMapping {
        var block = YAMLCodec.YAMLMapping(entries: [])
        for control in SecurityControl.allCases {
            SecurityPolicyConfigWriter.apply(.level(.fail, for: control), to: &block)
        }
        SecurityPolicyConfigWriter.apply(.hardwareLevel(.fail), to: &block)
        SecurityPolicyConfigWriter.apply(.scoreFactors([
            SecurityScoreFactor(.osCurrent, weight: 1, graceDays: 30),
            SecurityScoreFactor(.agent, weight: 1, target: "x"),
            SecurityScoreFactor(.mscp, weight: 1, target: "x"),
        ]), to: &block)
        SecurityPolicyConfigWriter.apply(.edrAgent("x"), to: &block)
        return block
    }

    /// A state that sets every key the Config screen can write: the columns it writes only
    /// when set, and one entry of each custom EA type with all of that type's values.
    private static var probeState: ConfigState {
        var state = ConfigState.defaultState
        // Written only when set, since the default is blank (the Overview's generic title).
        state.baselineLabel = "x"
        for key in ConfigState.optionalColumnKeys { state.columns[key] = "x" }
        state.securityAgents = [
            ConfigSecurityAgent(name: "x", column: "x", connectedValue: "x"),
        ]
        state.customEAs = CustomEAConfig.EAType.allCases.map(\.rawValue).map { type in
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
