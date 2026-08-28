import Foundation

/// One thing a period report can report on.
struct PeriodMetric: Sendable, Equatable, Identifiable {

    enum Unit: Sendable, Equatable {
        case count          // signed integer change
        case percent        // change in percentage points
        case distribution   // no single figure; values and counts

        /// Maps onto the fleet reports' formatting units. nil for
        /// `.distribution`, which has no scalar to format.
        var rollupUnit: FleetRollup.Unit? {
            switch self {
            case .count:        .count
            case .percent:      .percent
            case .distribution: nil
            }
        }
    }

    enum Source: Sendable, Equatable {
        case fleet
        /// `match` is the value that counts as a hit, present only when the
        /// operator has configured this attribute.
        case extensionAttribute(name: String, match: String?)
    }

    let id: String
    let label: String
    let unit: Unit
    let source: Source
}

/// Builds a profile's metric list from what its workspace holds. Discovered,
/// never declared — this project carries no org-specific values.
enum PeriodMetricCatalog {

    /// Fleet metrics with at least one observation in the supplied summaries.
    /// `totalDevices` is non-optional in the schema, so it is always offered.
    static func fleetMetrics(in summaries: [DailySummary]) -> [PeriodMetric] {
        var out: [PeriodMetric] = [
            PeriodMetric(id: "totalDevices", label: "Managed devices", unit: .count, source: .fleet)
        ]
        func addPercent(_ id: String, _ label: String, _ value: (DailySummary) -> Double?) {
            guard summaries.contains(where: { value($0) != nil }) else { return }
            out.append(PeriodMetric(id: id, label: label, unit: .percent, source: .fleet))
        }
        addPercent("fileVaultPct", "FileVault encrypted", \.fileVaultPct)
        addPercent("compliancePct", "Compliance rate", \.compliancePct)
        addPercent("osCurrentPct", "On current macOS", \.osCurrentPct)
        addPercent("patchPct", "Patch compliance", \.patchPct)
        addPercent("sipPct", "SIP enabled", \.sipPct)
        addPercent("firewallPct", "Firewall enabled", \.firewallPct)
        addPercent("gatekeeperPct", "Gatekeeper enabled", \.gatekeeperPct)
        addPercent("secureBootPct", "Secure Boot", \.secureBootPct)
        addPercent("bootstrapPct", "Bootstrap token escrowed", \.bootstrapPct)
        addPercent("xprotectPct", "XProtect current", \.xprotectPct)
        addPercent("cvePct", "CVE posture", \.cvePct)
        addPercent("mscpScorePct", "Compliance benchmark score", \.mscpScorePct)
        addPercent("securityScore", "Security score", \.securityScore)
        addPercent("crowdstrikePct", "EDR agent connected", \.crowdstrikePct)
        if summaries.contains(where: { $0.staleCount != nil }) {
            out.append(PeriodMetric(id: "staleCount", label: "Stale devices",
                                    unit: .count, source: .fleet))
        }
        return out
    }

    /// Every EA present in the supplied rows, tagged configured or not.
    static func eaMetrics(
        rows: [EAResultRow],
        customEAs: [CustomEAConfig],
        securityAgents: [SecurityAgentConfig]
    ) -> [PeriodMetric] {
        eaMetrics(names: Set(rows.compactMap(\.eaName)).sorted(),
                  customEAs: customEAs, securityAgents: securityAgents)
    }

    /// Name-only overload. A caller that has already grouped a snapshot by EA
    /// name holds the names and nothing else; making it rebuild `EAResultRow`
    /// values would mean force-decoding JSON in a production path.
    static func eaMetrics(
        names: [String],
        customEAs: [CustomEAConfig],
        securityAgents: [SecurityAgentConfig]
    ) -> [PeriodMetric] {
        names.map { name in
            let match = configuredMatch(for: name, customEAs: customEAs, securityAgents: securityAgents)
            return PeriodMetric(
                id: "ea:\(name)",
                label: name,
                unit: match == nil ? .distribution : .count,
                source: .extensionAttribute(name: name, match: match)
            )
        }
    }

    static func build(
        summaries: [DailySummary], eaRows: [EAResultRow], config: ReportConfig?
    ) -> [PeriodMetric] {
        fleetMetrics(in: summaries) + eaMetrics(
            rows: eaRows,
            customEAs: config?.customEas ?? [],
            securityAgents: config?.securityAgents ?? [])
    }

    /// Case-insensitive column match, mirroring how `security_agents` and
    /// `custom_eas` are matched elsewhere in the app.
    private static func configuredMatch(
        for name: String, customEAs: [CustomEAConfig], securityAgents: [SecurityAgentConfig]
    ) -> String? {
        let key = name.lowercased()
        if let agent = securityAgents.first(where: { $0.column.lowercased() == key }) {
            return agent.connectedValue
        }
        if let ea = customEAs.first(where: { $0.column.lowercased() == key }),
           let trueValue = ea.trueValue, !trueValue.isEmpty {
            return trueValue
        }
        return nil
    }
}
