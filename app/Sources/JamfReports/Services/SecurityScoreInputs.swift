import Foundation

/// What the Security Score's factors measure, from snapshots the app already collects, and the
/// one function that measures them. The daily summary writer, the Security Posture screen and
/// the workbook each score through `measures(for:fleet:sources:config:now:)`, so one fleet has
/// one score on every surface. Nothing here fetches.
///
/// - FileVault, SIP, Firewall, Gatekeeper: the security report's counts under the workspace
///   policy (`SecurityFleetCounts.scoreMeasure(for:)`).
/// - Secure Boot, bootstrap token, XProtect and macOS currency: the `computers` snapshot, the
///   last two against the cached macOS SOFA feed (`SOFAScoreFeed`).
/// - Patch compliance: `patch-status`, device-weighted (`PatchStatusService`).
/// - Checked in: `device-compliance` rows under `thresholds.stale_device_days`, the summary's
///   stale rule.
/// - mSCP: a `compliance.baselines` entry's pass share from `ea-results`. The four-control proxy
///   is never used: it is FileVault, SIP, Firewall and Gatekeeper again.
/// - Agents: each named `security_agents` entry's coverage from `ea-results`, over the whole
///   fleet (a Mac with no value counts as not connected), the summary's EDR figure.
enum SecurityScoreInputs {
    /// The snapshots the factors read beyond the security report. A nil part was not loaded,
    /// or did not decode, and every factor that needs it has no data.
    struct Sources: Sendable {
        var computers: [ComputerScoreFacts]?
        var sofa: SOFAScoreFeed?
        var patchRows: [PatchStatusRow]?
        var complianceRows: [DeviceComplianceRow]?
        var eaRows: [EAResultRow]?

        static let none = Sources()
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

    /// The newest snapshots in `dataDir` that `factors` need. Unlike the summary writer it
    /// applies no cache-age gate, as with every report sheet
    /// (`ReportEngine.loadLatestSnapshotData`). Off the main actor.
    nonisolated static func load(
        dataDir: URL, factors: [SecurityScoreFactor]
    ) -> Sources {
        let kinds = Set(factors.map(\.kind))
        func newest(_ kind: String) -> Data? {
            try? ReportEngine.loadLatestSnapshotData(kind: kind, dataDir: dataDir)
        }
        var sources = Sources()
        if !kinds.isDisjoint(with: [.secureBoot, .bootstrapToken, .osCurrent, .xprotectCurrent]) {
            sources.computers = newest("computers").flatMap(ComputerScoreFacts.decodeSnapshot)
        }
        if !kinds.isDisjoint(with: [.osCurrent, .xprotectCurrent]) {
            sources.sofa = SOFAScoreFeed.load(dataDir: dataDir)
        }
        if kinds.contains(.patchCompliance) {
            sources.patchRows = newest("patch-status").flatMap {
                try? JSONDecoder().decode([PatchStatusRow].self, from: $0)
            }
        }
        if kinds.contains(.checkedIn) {
            sources.complianceRows = newest("device-compliance").flatMap {
                try? JSONDecoder().decode([DeviceComplianceRow].self, from: $0)
            }
        }
        if !kinds.isDisjoint(with: [.mscp, .agent]) {
            sources.eaRows = newest("ea-results").flatMap { EAResultRow.decodeSnapshot($0).rows }
        }
        return sources
    }

    /// What each factor measured, keyed by `SecurityScoreFactor.key`; a factor without data is
    /// absent. `fleet` is nil when the security report was not collected.
    static func measures(
        for factors: [SecurityScoreFactor], fleet: SecurityFleetCounts?, sources: Sources,
        config: ReportConfig?, now: Date = Date()
    ) -> [String: SecurityScoreMeasure] {
        var measured: [String: SecurityScoreMeasure] = [:]
        for factor in factors {
            if let measure = measure(
                factor, fleet: fleet, sources: sources, config: config, now: now) {
                measured[factor.key] = measure
            }
        }
        return measured
    }

    private static func measure(
        _ factor: SecurityScoreFactor, fleet: SecurityFleetCounts?, sources: Sources,
        config: ReportConfig?, now: Date
    ) -> SecurityScoreMeasure? {
        let grace = factor.resolvedGraceDays
        switch factor.kind {
        case .fileVault, .sip, .firewall, .gatekeeper:
            return factor.kind.control.flatMap { fleet?.scoreMeasure(for: $0) }
        case .secureBoot:
            return judged(sources.computers) { $0.secureBootFull }
        case .bootstrapToken:
            return judged(sources.computers) { $0.bootstrapEscrowed }
        case .osCurrent:
            guard let feed = sources.sofa else { return nil }
            return judged(sources.computers) {
                $0.osVersion.flatMap { feed.isCurrent($0, graceDays: grace, now: now) }
            }
        case .xprotectCurrent:
            guard let feed = sources.sofa, feed.xprotectVersion != nil else { return nil }
            return judged(sources.computers) { facts in
                facts.xprotectVersion.flatMap {
                    feed.isXProtectCurrent($0, graceDays: grace, now: now)
                }
            }
        case .patchCompliance:
            return sources.patchRows.flatMap(PatchStatusService.fleetComplianceCounts).map {
                SecurityScoreMeasure(passing: $0.onLatest, evaluated: $0.devices)
            }
        case .checkedIn:
            let staleDays = config?.thresholds?.resolvedStaleDays ?? 30
            return judged(sources.complianceRows) { row in
                row.resolvedDaysSinceContact == nil && row.stale == nil
                    ? nil : !row.isStale(atDays: staleDays)
            }
        case .mscp:
            return mscpMeasure(factor, rows: sources.eaRows, config: config)
        case .agent:
            return agentMeasure(factor, rows: sources.eaRows, config: config, fleet: fleet)
        }
    }

    /// Macs `passes` judged true over Macs it judged; nil `passes` leaves a Mac out.
    private static func judged<Row>(
        _ rows: [Row]?, _ passes: (Row) -> Bool?
    ) -> SecurityScoreMeasure? {
        guard let rows else { return nil }
        let verdicts = rows.compactMap(passes)
        return SecurityScoreMeasure(
            passing: verdicts.filter { $0 }.count, evaluated: verdicts.count)
    }

    /// The named baseline, or the first one.
    private static func mscpMeasure(
        _ factor: SecurityScoreFactor, rows: [EAResultRow]?, config: ReportConfig?
    ) -> SecurityScoreMeasure? {
        let baselines = config?.compliance?.resolvedBaselines ?? []
        let baseline = factor.target.map { name in
            baselines.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } ?? baselines.first
        guard let rows, let baseline,
              let result = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline]).first,
              result.devicesWithData > 0
        else { return nil }
        return SecurityScoreMeasure(passing: result.passCount, evaluated: result.devicesWithData)
    }

    /// Over the whole fleet, so a Mac with no value counts as not connected; no data when no
    /// Mac reports the agent's extension attribute at all.
    private static func agentMeasure(
        _ factor: SecurityScoreFactor, rows: [EAResultRow]?, config: ReportConfig?,
        fleet: SecurityFleetCounts?
    ) -> SecurityScoreMeasure? {
        let agents = namedAgents(in: config)
        guard let rows, let name = factor.target,
              let agent = agents.first(where: {
                  agentKey($0.name).caseInsensitiveCompare(name) == .orderedSame
              }),
              let coverage = SecurityAgentCoverage.compute(rows: rows, agents: [agent]).first,
              coverage.reporting > 0
        else { return nil }
        let fleetSize = fleet.map(\.totalDevices).flatMap { $0 > 0 ? $0 : nil }
            ?? coverage.reporting
        return SecurityScoreMeasure(
            passing: min(coverage.installed, fleetSize), evaluated: fleetSize)
    }
}

/// The fields of one `computers` row the score reads. Never throws: a field of an unexpected
/// type reads as absent, so one odd record cannot lose the snapshot.
struct ComputerScoreFacts: Decodable, Sendable, Equatable {
    /// `security.secureBootLevel` is full security; nil when not supported or not reported.
    let secureBootFull: Bool?
    /// `security.bootstrapTokenEscrowedStatus` (or the older Bool key) says escrowed; nil when
    /// not supported or not reported.
    let bootstrapEscrowed: Bool?
    let xprotectVersion: Int?
    let osVersion: String?

    init(secureBootFull: Bool?, bootstrapEscrowed: Bool?, xprotectVersion: Int?,
         osVersion: String?) {
        self.secureBootFull = secureBootFull
        self.bootstrapEscrowed = bootstrapEscrowed
        self.xprotectVersion = xprotectVersion
        self.osVersion = osVersion
    }

    private enum Sections: String, CodingKey { case security, operatingSystem }
    private enum SecurityKeys: String, CodingKey {
        case secureBootLevel, bootstrapTokenEscrowedStatus, bootstrapTokenEscrowed
        case xprotectVersion
    }
    private enum OSKeys: String, CodingKey { case version }

    init(from decoder: Decoder) throws {
        let row = try? decoder.container(keyedBy: Sections.self)
        let security = try? row?.nestedContainer(keyedBy: SecurityKeys.self, forKey: .security)
        let os = try? row?.nestedContainer(keyedBy: OSKeys.self, forKey: .operatingSystem)
        func text(_ key: SecurityKeys) -> String? {
            (try? security?.decodeIfPresent(String.self, forKey: key))?
                .trimmingCharacters(in: .whitespaces).uppercased()
        }
        secureBootFull = Self.secureBoot(text(.secureBootLevel))
        bootstrapEscrowed = Self.escrow(text(.bootstrapTokenEscrowedStatus))
            ?? (try? security?.decodeIfPresent(Bool.self, forKey: .bootstrapTokenEscrowed))
        xprotectVersion = text(.xprotectVersion).flatMap { Int($0) }
        osVersion = (try? os?.decodeIfPresent(String.self, forKey: .version))?
            .trimmingCharacters(in: .whitespaces)
    }

    static func secureBoot(_ level: String?) -> Bool? {
        switch level {
        case "FULL_SECURITY": true
        case "MEDIUM_SECURITY", "NO_SECURITY", "REDUCED_SECURITY", "PERMISSIVE_SECURITY": false
        default: nil
        }
    }

    static func escrow(_ status: String?) -> Bool? {
        switch status {
        case "ESCROWED": true
        case "NOT_ESCROWED": false
        default: nil
        }
    }

    /// A `computers` snapshot: a bare array, or a `results` envelope.
    static func decodeSnapshot(_ data: Data) -> [ComputerScoreFacts]? {
        if let rows = try? JSONDecoder().decode([ComputerScoreFacts].self, from: data) {
            return rows
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.results
    }

    private struct Envelope: Decodable { let results: [ComputerScoreFacts] }
}
