import Foundation

extension DemoData {
    /// The compliance baseline every demo compliance surface names; the top
    /// failing rules carry the same name.
    static let complianceBaseline = "NIST 800-53r5 Mod"

    /// The demo workspace's config.yaml, as the Config screen and every label
    /// read from config (the EDR agent's name, the compliance benchmark, the stale
    /// threshold) see it. Demo mode never reads or writes a real config.yaml, so
    /// this is the only config a demo shows.
    static let configState: ConfigState = {
        var state = ConfigState.defaultState
        for mapping in columnMappings {
            state.columns[mapping.key] = mapping.value
        }
        state.securityAgents = securityAgents.map { agent in
            ConfigSecurityAgent(
                name: agent.name, column: agent.column,
                connectedValue: agentConnectedValues[agent.name] ?? "Installed")
        }
        state.customEAs = customEAs.map { ea in
            ConfigCustomEA(
                name: ea.name, column: ea.column, type: ea.type.rawValue,
                trueValue: ea.trueValue ?? "",
                warningThreshold: ea.warn.map(String.init) ?? "",
                criticalThreshold: ea.crit.map(String.init) ?? "",
                currentVersions: ea.currentVersions ?? [],
                warningDays: ea.warningDays.map(String.init) ?? "")
        }
        state.complianceEnabled = true
        state.baselineLabel = complianceBaseline
        state.failuresCountColumn = "mSCP - Failed Rules Count"
        state.failuresListColumn = "mSCP - Failed Rules List"
        state.platformEnabled = true
        state.complianceBenchmarks = [complianceBaseline]
        state.orgName = org.name
        return state
    }()

    private static let agentConnectedValues = [
        "CrowdStrike Falcon": "Running",
        "1Password": "Installed",
        "Splunk Forwarder": "Running",
        "Beyond Identity": "Enrolled",
        "Tailscale": "Connected",
    ]
}
