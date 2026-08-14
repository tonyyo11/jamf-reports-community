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
        /// 0–100. `nil` = field absent (will not trigger boot-drive factor).
        var bootDrivePctUsed: Double?
        var mscpHighFailures: Int
        var mscpMediumFailures: Int
        var hasBaseline: Bool
        var daysSinceCheckIn: Int?
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
            bootDrivePctUsed: 40,
            mscpHighFailures: 0,
            mscpMediumFailures: 0,
            hasBaseline: true,
            daysSinceCheckIn: 1,
            activeCVEExploits: 0,
            bootstrapEscrowed: true,
            securityAgentConnected: nil
        )
    }

    /// One device's status check against a configured `security_agents` entry.
    ///
    /// `connected_value` follows the config contract: a case-insensitive
    /// substring match against the device's EA value. An empty EA value means
    /// "no data" — the factor is not triggered.
    struct SecurityAgentCheck: Sendable, Equatable {
        /// The device's raw EA value for the agent's configured column.
        let value: String
        /// The configured `connected_value`.
        let connectedValue: String

        /// nil when there is no usable signal (empty value or empty
        /// connected_value); otherwise whether the value matches.
        var isConnected: Bool? {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedExpected = connectedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty, !trimmedExpected.isEmpty else { return nil }
            return trimmedValue.localizedCaseInsensitiveContains(trimmedExpected)
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
        if let used = input.bootDrivePctUsed,
           used >= Double(weights.bootDriveFullThresholdPct) {
            add(.bootDriveFull, points: weights.bootDriveFull,
                detail: "\(Int(used.rounded()))% used")
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
        // v3.5 only penalizes "no baseline" for active devices (≤30d check-in).
        let isActive = (input.daysSinceCheckIn ?? Int.max) <= 30
        if !input.hasBaseline, isActive {
            add(.noBaseline, points: weights.noBaseline)
        }
        if let exploits = input.activeCVEExploits, exploits > 0 {
            add(.activeCVE, points: weights.activeCVE,
                detail: "\(exploits) active exploit(s)")
        }
        if let days = input.daysSinceCheckIn, days > 30 {
            add(.staleOffline, points: weights.staleOffline,
                detail: "\(days) days since check-in")
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
        guard let url = FileManager.newestJSONFile(in: resultsDir),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([EAResultRow].self, from: data) else {
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
    static func from(
        record: DeviceInventoryRecord,
        agentCheck: RiskScoringService.SecurityAgentCheck? = nil
    ) -> Self {
        Self(
            fileVaultEncrypted: looksAffirmative(record.fileVault) &&
                                !looksNegative(record.fileVault),
            sipEnabled: looksAffirmative(record.sip),
            gatekeeperEnabled: looksAffirmative(record.gatekeeper),
            firewallEnabled: looksAffirmative(record.firewall),
            secureBootLevel: .unknown,
            bootDrivePctUsed: parseDiskUsagePct(record.diskUsage),
            mscpHighFailures: 0,
            mscpMediumFailures: record.failedRules,
            hasBaseline: true,
            daysSinceCheckIn: record.daysSinceContact,
            activeCVEExploits: nil,
            bootstrapEscrowed: looksAffirmative(record.bootstrapToken) &&
                               !looksNegative(record.bootstrapToken),
            securityAgentConnected: agentCheck?.isConnected
        )
    }

    /// Same normalization as `valueLooksGood`/`statusLooksBad` (Models.swift), so
    /// `NOT_ENCRYPTED` and `Not Encrypted` are one value on both paths.
    private static func normalizedStatus(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func looksAffirmative(_ raw: String) -> Bool {
        let text = normalizedStatus(raw)
        if text.isEmpty { return true }    // missing data ≠ failing
        // A negative is authoritative and must win. Testing the positive
        // substrings first scored every disabled control as passing, because
        // "not enabled" contains "enabled" and "not encrypted" contains
        // "encrypted" — so an unprotected Mac scored Clean and dropped out of
        // the Priority filter. Anything not provably negative stays affirmative,
        // which is what the previous `!looksNegative` tail already did.
        return !looksNegative(text)
    }

    private static func looksNegative(_ raw: String) -> Bool {
        let text = normalizedStatus(raw)
        guard !text.isEmpty else { return false }
        // "not " covers not enabled / not encrypted / not escrowed in one test,
        // matching valueLooksGood (Models.swift) rather than drifting from it.
        if text.contains("not ") || text.contains("disabled") ||
            text.contains("unencrypted") {
            return true
        }
        return ["no", "false", "0", "off"].contains(text)
    }

    private static func parseDiskUsagePct(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Accept "94%", "94", "94.5%", "0.94", etc. Prefer the leading
        // numeric token and infer 0–1 vs. 0–100 from magnitude.
        // S-05: `scanDouble(_:)` is deprecated since macOS 10.15; use
        // the no-arg variant that returns Double?.
        let scanner = Scanner(string: trimmed)
        guard let value = scanner.scanDouble() else { return nil }
        if value > 0, value <= 1 { return value * 100 }   // 0.94 → 94
        return value
    }
}
