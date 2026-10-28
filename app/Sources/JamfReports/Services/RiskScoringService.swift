import Foundation

/// Per-device risk scorer. Mirrors `FleetHealthDashboard._compute_device_risk()`
/// in `jamf_reports_cli_v3.5.py`.
///
/// Consumes a normalized `Input` type rather than `DeviceInventoryRecord`
/// directly so the scoring logic stays unit-testable and the adapter
/// (`Input.from(record:)`) can evolve as the inventory record gains or
/// renames fields.
struct RiskScoringService: Sendable {

    enum SecureBootLevel: String, Sendable, Equatable {
        case none, medium, full, unknown
    }

    struct Input: Sendable, Equatable {
        var fileVaultEncrypted: Bool
        var sipEnabled: Bool
        var gatekeeperEnabled: Bool
        var firewallEnabled: Bool
        var secureBootLevel: SecureBootLevel
        var mscpHighFailures: Int
        var mscpMediumFailures: Int
        var hasBaseline: Bool
        /// Stale under the workspace's stale rule (`StaleRule`), not a fixed day count.
        var isStale: Bool
        /// Why `isStale` holds, for the factor's detail line; nil when not stale.
        var staleDetail: String?
        /// Number of active CVE exploits present. `nil` = field absent.
        var activeCVEExploits: Int?
        var bootstrapEscrowed: Bool
        /// Whether the tenant's configured security agent (first
        /// `security_agents` config entry) reports connected on this device.
        /// `nil` = no agent configured, or no EA value for this device;
        /// do not penalize.
        var securityAgentConnected: Bool?

        static let safe = Input(
            fileVaultEncrypted: true,
            sipEnabled: true,
            gatekeeperEnabled: true,
            firewallEnabled: true,
            secureBootLevel: .full,
            mscpHighFailures: 0,
            mscpMediumFailures: 0,
            hasBaseline: true,
            isStale: false,
            staleDetail: nil,
            activeCVEExploits: 0,
            bootstrapEscrowed: true,
            securityAgentConnected: nil
        )
    }

    /// One device's status check against a configured `security_agents` entry.
    ///
    /// `connected_value` follows the config contract: a case-insensitive
    /// substring match against the device's EA value, and with no
    /// `connected_value` any value counts, as `SecurityAgentCoverage` counts it.
    /// A value that says the agent is absent or off ("Not Installed", "Disconnected")
    /// does not match, by the vocabulary `SecurityControlPolicy.reading` uses for the
    /// security controls, unless `connected_value` itself reads that way.
    /// An empty EA value means "no data" — the factor is not triggered.
    /// Every comparison against `connected_value` goes through here.
    struct SecurityAgentCheck: Sendable, Equatable {
        /// The device's raw EA value for the agent's configured column.
        let value: String
        /// The configured `connected_value`.
        let connectedValue: String

        /// nil when the value is empty; otherwise whether it matches.
        var isConnected: Bool? {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedExpected = connectedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            guard !trimmedExpected.isEmpty else { return true }
            guard trimmedValue.localizedCaseInsensitiveContains(trimmedExpected) else {
                return false
            }
            let negated = SecurityControlPolicy.reading(trimmedValue) == false
            return !negated || SecurityControlPolicy.reading(trimmedExpected) == false
        }
    }

    /// Compute risk for a single device's signals.
    static func score(
        input: Input,
        weights: RiskFactorWeights = .defaultWeights
    ) -> DeviceRisk {
        var triggered: [DeviceRisk.TriggeredFactor] = []
        var total = 0

        func add(_ factor: DeviceRisk.Factor, points: Int, detail: String? = nil) {
            guard points > 0 else { return }
            triggered.append(.init(factor: factor, points: points, detail: detail))
            total += points
        }

        if !input.fileVaultEncrypted {
            add(.noFileVault, points: weights.noFileVault)
        }
        switch input.secureBootLevel {
        case .none:    add(.secureBootNone, points: weights.secureBootNone)
        case .medium:  add(.secureBootMedium, points: weights.secureBootMedium)
        case .full, .unknown: break
        }
        if !input.sipEnabled {
            add(.sipDisabled, points: weights.sipDisabled)
        }
        if !input.gatekeeperEnabled {
            add(.gatekeeperDisabled, points: weights.gatekeeperDisabled)
        }
        if !input.firewallEnabled {
            add(.firewallDisabled, points: weights.firewallDisabled)
        }
        if input.mscpHighFailures > 0 {
            let raw = input.mscpHighFailures * weights.mscpHighPerFailure
            let capped = min(raw, weights.mscpHighCap)
            add(.mscpHighFailures, points: capped,
                detail: "\(input.mscpHighFailures) High failures")
        }
        if input.mscpMediumFailures > 0 {
            let raw = input.mscpMediumFailures * weights.mscpMediumPerFailure
            let capped = min(raw, weights.mscpMediumCap)
            add(.mscpMediumFailures, points: capped,
                detail: "\(input.mscpMediumFailures) Medium failures")
        }
        // v3.5 only penalizes "no baseline" for active devices.
        if !input.hasBaseline, !input.isStale {
            add(.noBaseline, points: weights.noBaseline)
        }
        if let exploits = input.activeCVEExploits, exploits > 0 {
            add(.activeCVE, points: weights.activeCVE,
                detail: "\(exploits) active exploit(s)")
        }
        if input.isStale {
            add(.staleOffline, points: weights.staleOffline, detail: input.staleDetail)
        }
        if input.securityAgentConnected == false {
            add(.securityAgentDisconnected, points: weights.securityAgentDisconnected)
        }
        if !input.bootstrapEscrowed {
            add(.bootstrapMissing, points: weights.bootstrapMissing)
        }

        let sorted = triggered.sorted { $0.points > $1.points }
        return DeviceRisk(
            score: total,
            level: DeviceRisk.Level.from(score: total),
            triggered: sorted
        )
    }

    /// The one rating of a Mac. The Devices list pill, the detail panel, the Priority filter,
    /// the CSV export and the inventory sort all read this, so no screen rates a Mac by a
    /// rule of its own. Staleness is one of its factors (`staleOffline`), judged by the
    /// workspace's `staleRule`.
    static func risk(
        for record: DeviceInventoryRecord,
        agentCheck: SecurityAgentCheck? = nil,
        policy: SecurityControlPolicy,
        staleRule: StaleRule
    ) -> DeviceRisk {
        score(input: .from(
            record: record, agentCheck: agentCheck, policy: policy, staleRule: staleRule))
    }

    // MARK: - Security-agent EA lookup

    /// Per-device value lookup for `eaColumn` from the cached ea-results
    /// snapshot. Keys are lowercased device identifiers — serial, computer ID,
    /// computer name, and the alternate-shape `device` field — so callers can
    /// probe with whichever identifiers their inventory record carries.
    ///
    /// Empty when no agent column is configured, no ea-results snapshot
    /// exists, or the snapshot has no rows for that column. The risk factor is
    /// then never triggered (absence of data is not a finding).
    static func agentStatusLookup(profile: String, eaColumn: String) -> [String: String] {
        let column = eaColumn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !column.isEmpty,
              let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            return [:]
        }
        let resultsDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        // decodeSnapshot, like every other ea-results reader: an envelope or a
        // truncated snapshot still yields its rows.
        guard let url = FileManager.newestJSONFile(in: resultsDir),
              let data = BoundedFile.readLogged(url),
              let rows = EAResultRow.decodeSnapshot(data).rows else {
            return [:]
        }

        var lookup: [String: String] = [:]
        for row in rows {
            guard let name = row.eaName, name.caseInsensitiveCompare(column) == .orderedSame,
                  let value = row.value?.stringValue, !value.isEmpty else {
                continue
            }
            for key in [row.serial, row.computerId, row.computerName, row.device] {
                if let key, !key.isEmpty {
                    lookup[key.lowercased()] = value
                }
            }
        }
        return lookup
    }
}

// MARK: - DeviceInventoryRecord adapter

extension RiskScoringService.Input {
    /// Adapter from the inventory record's string-typed status columns to the
    /// normalized signals the scorer consumes. Returns a "best effort" view —
    /// fields absent from the record (mSCP failures, active CVE counts) are
    /// treated as zero so the device is not unfairly penalized. Wire those in
    /// once the inventory snapshot starts carrying them.
    ///
    /// `agentCheck` is the device's status against the tenant's configured
    /// security agent (see `RiskScoringService.SecurityAgentCheck`). Pass nil
    /// when no agent is configured or the device has no EA value — the factor
    /// is then skipped, never penalized.
    ///
    /// A control scores only when the workspace's policy calls it a failure: a
    /// warning, an ignored control or an unmeasured value is not a risk point.
    static func from(
        record: DeviceInventoryRecord,
        agentCheck: RiskScoringService.SecurityAgentCheck? = nil,
        policy: SecurityControlPolicy,
        staleRule: StaleRule
    ) -> Self {
        func passes(_ control: SecurityControl, _ value: String) -> Bool {
            policy.verdict(for: control, value: value, hardwareEncrypted: record.hardwareEncrypted)
                != .fail
        }
        return Self(
            fileVaultEncrypted: passes(.fileVault, record.fileVault),
            sipEnabled: passes(.sip, record.sip),
            gatekeeperEnabled: passes(.gatekeeper, record.gatekeeper),
            firewallEnabled: passes(.firewall, record.firewall),
            secureBootLevel: .unknown,
            mscpHighFailures: 0,
            mscpMediumFailures: 0,
            hasBaseline: true,
            isStale: record.isStale(staleRule),
            staleDetail: staleDetail(record, staleRule),
            activeCVEExploits: nil,
            bootstrapEscrowed: SecurityControlPolicy.reading(record.bootstrapToken) != false,
            securityAgentConnected: agentCheck?.isConnected
        )
    }

    private static func staleDetail(_ record: DeviceInventoryRecord, _ rule: StaleRule) -> String? {
        guard record.isStale(rule) else { return nil }
        switch record.staleAge(rule) {
        case .days(let days)?: return "\(days) days since \(rule.basisPhrase)"
        case .never?: return "No \(rule.basisPhrase) on record"
        case nil: return nil
        }
    }
}
