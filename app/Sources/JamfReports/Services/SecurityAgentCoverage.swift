import Foundation

/// Coverage of each agent listed under `security_agents`, read from the
/// `ea-results` snapshot.
///
/// On a jamf-cli workspace an agent's `column` names an extension attribute,
/// and ea-results is the only place its per-Mac values land: collect asks
/// `pro computers list` for no EXTENSION_ATTRIBUTES section. It serves the
/// Overview's Security Agents card and the EDR figure the daily summary
/// records; the card divides by the Macs reporting, the summary by the fleet.
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

    /// One result per agent with a column, in config order. A Mac counts
    /// once however many rows it has, keyed the way the mSCP service keys it.
    /// `countsRowsWithoutID` counts a row with no computer id or serial as its
    /// own Mac rather than keying it by computer name, which merges Macs that
    /// share a name. The daily summary leaves it off so its recorded trend keeps
    /// one definition.
    static func compute(
        rows: [EAResultRow], agents: [SecurityAgentConfig], countsRowsWithoutID: Bool = false
    ) -> [Result] {
        agents.compactMap { agent -> Result? in
            let column = agent.column.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !column.isEmpty else { return nil }
            var reporting: Set<String> = []
            var installed: Set<String> = []
            for (index, row) in rows.enumerated() {
                guard let eaName = row.eaName,
                      eaName.caseInsensitiveCompare(column) == .orderedSame,
                      let id = macKey(row, index: index, countsRowsWithoutID: countsRowsWithoutID)
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

    /// The row's computer id or serial when it has one; otherwise the row itself
    /// when counting rows, or the computer name the mSCP service falls back to.
    private static func macKey(
        _ row: EAResultRow, index: Int, countsRowsWithoutID: Bool
    ) -> String? {
        let hasID = [row.computerId, row.serial].contains { !($0 ?? "").isEmpty }
        if countsRowsWithoutID, !hasID { return "row #\(index)" }
        return MSCPComplianceService.primaryIdentifier(for: row)?.lowercased()
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
