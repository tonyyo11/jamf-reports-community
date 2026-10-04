import Foundation

/// The inputs of the weighted Security Score beyond the security report's FileVault, SIP and
/// Firewall counts, and the one function that joins all of them. The daily summary writer, the
/// Security Posture screen and the workbook's Executive Summary each score through
/// `input(fleet:extras:)`, so one fleet has one score on every surface.
///
/// Sources, all already collected (nothing here fetches):
/// - **EDR agent** (`.edrAgent`): the first named `security_agents` entry's coverage from
///   `ea-results`, over the whole fleet (a Mac with no value counts as not connected). It is
///   the figure the summary records as `crowdstrikePct` and the Overview's EDR card shows.
/// - **mSCP** (`.mscp`): the primary `compliance.baselines` entry's pass share, Macs with a
///   zero failure count over the Macs with a valid count (Macs with no row are out of the
///   share). It is the real-data `compliancePct` and `mscpScorePct`. The four-control proxy
///   is never used: it is FileVault, SIP, Firewall and Gatekeeper again, which the score
///   already counts, so feeding it would weigh those controls twice.
/// - **XProtect, CVE, Secure Boot**: no snapshot, summary writer or report in the app
///   measures them (`DailySummary` has the fields; no collect fills them), so they stay out
///   and their weights drop from the denominator, as the calculator does for any input
///   without data.
enum SecurityScoreInputs {
    struct Extras: Sendable, Equatable {
        /// Macs the first named security agent reports connected. Nil when no Mac reports its
        /// extension attribute at all (unknown, not zero).
        var edrConnected: Int?
        /// Primary baseline: Macs with zero failures, and Macs with a valid count.
        var mscpPass: Int?
        var mscpEvaluated: Int?

        static let none = Extras()
    }

    /// The extras from pieces a caller has already computed.
    static func extras(
        edr: SecurityAgentCoverage.Result?, mscp: MSCPComplianceService.BaselineResult?
    ) -> Extras {
        var extras = Extras()
        if let edr, edr.reporting > 0 { extras.edrConnected = edr.installed }
        if let mscp, mscp.devicesWithData > 0 {
            extras.mscpPass = mscp.passCount
            extras.mscpEvaluated = mscp.devicesWithData
        }
        return extras
    }

    /// The agent the score counts as the EDR agent, the one the EDR card, the trend and
    /// `crowdstrikePct` follow: `security_policy.edr_agent` when it names a `security_agents`
    /// entry (case-insensitive, trimmed), else the first entry with a name.
    static func edrAgent(in config: ReportConfig?) -> SecurityAgentConfig? {
        let agents = config?.securityAgents ?? []
        let chosen = config?.resolvedSecurityPolicy.edrAgent
        return edrAgentIndex(among: agents.map(\.name), chosen: chosen).map { agents[$0] }
    }

    static func edrAgent(
        among agents: [SecurityAgentConfig], chosen: String?
    ) -> SecurityAgentConfig? {
        edrAgentIndex(among: agents.map(\.name), chosen: chosen).map { agents[$0] }
    }

    /// Index of the EDR agent among `names` (blank names never count): the one `chosen`
    /// names, else the first. The one rule behind the score, the summary, the Overview and
    /// the Scoring tab's picker.
    static func edrAgentIndex(among names: [String], chosen: String?) -> Int? {
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty,
           let match = trimmed.firstIndex(where: {
               !$0.isEmpty && $0.caseInsensitiveCompare(chosen) == .orderedSame
           }) {
            return match
        }
        return trimmed.firstIndex { !$0.isEmpty }
    }

    /// Every `security_agents` entry with a name, in config order.
    static func namedAgents(in config: ReportConfig?) -> [SecurityAgentConfig] {
        (config?.securityAgents ?? []).filter { !agentKey($0.name).isEmpty }
    }

    /// An agent's name as the summary keys it and the Overview and Trends look it up.
    static func agentKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The extras for decoded `ea-results` rows under `config`.
    static func extras(eaRows: [EAResultRow]?, config: ReportConfig?) -> Extras {
        guard let eaRows, let config else { return .none }
        let coverage = edrAgent(in: config).flatMap {
            SecurityAgentCoverage.compute(rows: eaRows, agents: [$0]).first
        }
        let baselines = config.compliance?.resolvedBaselines ?? []
        let primary = baselines.isEmpty
            ? nil : MSCPComplianceService.evaluate(rows: eaRows, baselines: baselines).first
        return extras(edr: coverage, mscp: primary)
    }

    /// The extras from the newest `ea-results` snapshot in `dataDir`: what the Security Posture
    /// screen and the workbook read. Unlike the summary writer they apply no cache-age gate,
    /// as with every report sheet (`ReportEngine.loadLatestSnapshotData`). Off the main actor.
    nonisolated static func load(dataDir: URL, config: ReportConfig?) -> Extras {
        guard let config,
              edrAgent(in: config) != nil || !(config.compliance?.resolvedBaselines ?? []).isEmpty,
              let data = try? ReportEngine.loadLatestSnapshotData(
                  kind: "ea-results", dataDir: dataDir)
        else { return .none }
        return extras(eaRows: EAResultRow.decodeSnapshot(data).rows, config: config)
    }

    /// The score's input: the security report's three controls, then the extras. A metric the
    /// extras leave out is missing, and the calculator drops its weight.
    static func input(
        fleet: SecurityFleetCounts, extras: Extras
    ) -> SecurityScoreCalculator.Input {
        let base = fleet.scoreInput()
        guard fleet.totalDevices > 0 else { return base }
        var compliant = base.compliantCounts
        var totals = base.metricTotals
        if let edr = extras.edrConnected {
            compliant[.edrAgent] = min(edr, fleet.totalDevices)
        }
        if let pass = extras.mscpPass, let evaluated = extras.mscpEvaluated {
            compliant[.mscp] = pass
            totals[.mscp] = evaluated
        }
        return .init(
            totalDevices: base.totalDevices, compliantCounts: compliant, metricTotals: totals)
    }

    /// The summary's `securityScoreBasis`: the metrics that contributed, in score order, by
    /// raw value. Two scores compare only when this is equal.
    static func basis(of score: SecurityScore) -> String? {
        score.available.isEmpty ? nil : score.available.map(\.rawValue).joined(separator: ",")
    }

    /// The metrics a recorded basis names, in the order recorded; unknown words are dropped.
    static func metrics(inBasis basis: String) -> [SecurityScore.Metric] {
        basis.split(separator: ",").compactMap { SecurityScore.Metric(rawValue: String($0)) }
    }
}
