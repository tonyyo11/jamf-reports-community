import Foundation

/// Adopts proposed Extension Attributes into a profile's `config.yaml` `custom_eas`.
///
/// Adoption is strictly ADDITIVE: it loads the existing config, appends new EAs,
/// and saves through `ConfigService.save` — which only rewrites managed top-level
/// keys and re-reads everything else, so unrelated config is preserved verbatim.
/// Proposals whose column already exists in `custom_eas` are skipped.
enum ConfigEAAdopter {

    /// Append `proposals` to a profile's `custom_eas`, skipping duplicate columns.
    ///
    /// - Parameters:
    ///   - proposals: EA candidates the user selected to adopt.
    ///   - profile: Profile slug whose `config.yaml` is updated.
    ///   - workspaceRoot: Optional workspace root override (for tests).
    /// - Returns: The number of EAs actually appended (excludes skipped duplicates).
    /// - Throws: `ConfigService` load/save errors.
    @discardableResult
    static func adoptEAs(
        _ proposals: [ScaffoldService.ProposedEA],
        profile: String,
        workspaceRoot: URL? = nil
    ) throws -> Int {
        try adopt(
            eaProposals: proposals, agentProposals: [],
            profile: profile, workspaceRoot: workspaceRoot
        ).eas
    }

    /// Append selected proposals to `custom_eas` and/or `security_agents` in one
    /// load/save. Duplicate columns (already present in the respective section)
    /// are skipped. A security agent's connected value comes from
    /// `connectedValues[proposal.id]`, falling back to the proposal's sample
    /// value. Additive — unrelated config is preserved.
    ///
    /// - Returns: counts of EAs and security agents actually appended.
    @discardableResult
    static func adopt(
        eaProposals: [ScaffoldService.ProposedEA],
        agentProposals: [ScaffoldService.ProposedEA],
        connectedValues: [String: String] = [:],
        profile: String,
        workspaceRoot: URL? = nil
    ) throws -> (eas: Int, agents: Int) {
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: workspaceRoot)
        var state = loaded.state

        var eaColumns = Set(state.customEAs.map { $0.column.lowercased() })
        var eaAdded = 0
        for proposal in eaProposals {
            let key = proposal.column.lowercased()
            guard !eaColumns.contains(key) else { continue }
            eaColumns.insert(key)
            state.customEAs.append(customEA(from: proposal))
            eaAdded += 1
        }

        var agentColumns = Set(state.securityAgents.map { $0.column.lowercased() })
        var agentAdded = 0
        for proposal in agentProposals {
            let key = proposal.column.lowercased()
            guard !agentColumns.contains(key) else { continue }
            agentColumns.insert(key)
            let connected = connectedValues[proposal.id] ?? proposal.sampleValue
            state.securityAgents.append(ConfigSecurityAgent(
                name: proposal.name, column: proposal.column, connectedValue: connected))
            agentAdded += 1
        }

        guard eaAdded > 0 || agentAdded > 0 else { return (0, 0) }

        _ = try ConfigService.save(
            profile: profile,
            state: state,
            existingDocument: loaded.document,
            workspaceRoot: workspaceRoot
        )
        return (eaAdded, agentAdded)
    }

    /// Map a `ProposedEA` to the flat `ConfigCustomEA` editing model.
    ///
    /// For boolean EAs the sample value becomes a sensible default `true_value`.
    /// Threshold/version/date fields default empty — the user tunes them later
    /// in the Config screen.
    static func customEA(from proposal: ScaffoldService.ProposedEA) -> ConfigCustomEA {
        ConfigCustomEA(
            name: proposal.name,
            column: proposal.column,
            type: proposal.type,
            trueValue: proposal.type == "boolean" ? proposal.sampleValue : "",
            warningThreshold: "",
            criticalThreshold: "",
            currentVersions: [],
            warningDays: ""
        )
    }
}
