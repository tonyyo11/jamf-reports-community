import Foundation

/// Coverage of each agent listed under `security_agents`, read from the
/// `ea-results` snapshot.
///
/// On a jamf-cli workspace an agent's `column` names an extension attribute,
/// and ea-results is the only place its per-Mac values land: collect asks
/// `pro computers list` for no EXTENSION_ATTRIBUTES section. One definition
/// serves the Overview's Security Agents card and the EDR figure the daily
/// summary records, so the two cannot disagree.
enum SecurityAgentCoverage {
    struct Result: Sendable, Equatable {
        let name: String
        let column: String
        /// Macs whose value contains the agent's `connected_value` — the same
        /// case-insensitive match the Devices screen's risk check uses.
        let installed: Int
        /// Macs with any value for the agent's extension attribute.
        let reporting: Int
    }

    /// One result per agent with a column, in config order. A Mac counts
    /// once however many rows it has, keyed the way the mSCP service keys it.
    static func compute(rows: [EAResultRow], agents: [SecurityAgentConfig]) -> [Result] {
        agents.compactMap { agent -> Result? in
            let column = agent.column.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !column.isEmpty else { return nil }
            var reporting: Set<String> = []
            var installed: Set<String> = []
            for row in rows {
                guard let eaName = row.eaName,
                      eaName.caseInsensitiveCompare(column) == .orderedSame,
                      let id = MSCPComplianceService.primaryIdentifier(for: row)?.lowercased()
                else { continue }
                let value = (row.value?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                reporting.insert(id)
                let check = RiskScoringService.SecurityAgentCheck(
                    value: value, connectedValue: agent.connectedValue)
                if check.isConnected == true { installed.insert(id) }
            }
            return Result(name: agent.name, column: column,
                          installed: installed.count, reporting: reporting.count)
        }
    }

    /// Percent of `fleet` with the agent connected, one decimal like every
    /// tile. nil for an empty fleet — unknown is not 0%.
    static func percent(installed: Int, fleet: Int) -> Double? {
        guard fleet > 0 else { return nil }
        return (Double(installed) / Double(fleet) * 1000).rounded() / 10
    }
}
