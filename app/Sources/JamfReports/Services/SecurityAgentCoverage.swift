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
        /// case-insensitive match the Devices screen's risk check uses. With no
        /// `connected_value`, any value counts, as Config Doctor tells the operator.
        let installed: Int
        /// Macs with any value for the agent's extension attribute.
        let reporting: Int
    }

    /// One result per agent with a column, in config order. A row with a
    /// computer id or serial counts once per id, however many rows it has. A
    /// row with neither counts as its own Mac: jamf-cli's rows carry only the
    /// computer name, and keying by name counted Macs that share one as one.
    static func compute(rows: [EAResultRow], agents: [SecurityAgentConfig]) -> [Result] {
        agents.compactMap { agent -> Result? in
            let column = agent.column.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !column.isEmpty else { return nil }
            var reporting: Set<String> = []
            var installed: Set<String> = []
            for (index, row) in rows.enumerated() {
                guard let eaName = row.eaName,
                      eaName.caseInsensitiveCompare(column) == .orderedSame else { continue }
                let value = (row.value?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let mac = macKey(row, index: index)
                reporting.insert(mac)
                let check = RiskScoringService.SecurityAgentCheck(
                    value: value, connectedValue: agent.connectedValue)
                if check.isConnected == true { installed.insert(mac) }
            }
            return Result(name: agent.name, column: column,
                          installed: installed.count, reporting: reporting.count)
        }
    }

    /// The row's computer id or serial, keyed the way the mSCP service keys it,
    /// or the row itself when it has neither.
    private static func macKey(_ row: EAResultRow, index: Int) -> String {
        let hasID = [row.computerId, row.serial].contains { !($0 ?? "").isEmpty }
        guard hasID, let id = MSCPComplianceService.primaryIdentifier(for: row) else {
            return "row #\(index)"
        }
        return id.lowercased()
    }

    /// Percent of `fleet` with the agent connected, one decimal like every
    /// tile. nil for an empty fleet — unknown is not 0%. At most 100: the count
    /// comes from ea-results and the fleet from the security report, collected on
    /// different cadences, so a fleet that shrank in between can count more Macs
    /// connected than it has.
    static func percent(installed: Int, fleet: Int) -> Double? {
        guard fleet > 0 else { return nil }
        return (Double(min(installed, fleet)) / Double(fleet) * 1000).rounded() / 10
    }
}
