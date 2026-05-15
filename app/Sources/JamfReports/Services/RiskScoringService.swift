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
        /// `nil` = Nessus not deployed in this tenant; do not penalize.
        var nessusConnected: Bool?

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
            nessusConnected: nil
        )
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
        if input.nessusConnected == false {
            add(.nessusDisconnected, points: weights.nessusDisconnected)
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
}

// MARK: - DeviceInventoryRecord adapter

extension RiskScoringService.Input {
    /// Adapter from the inventory record's string-typed status columns to the
    /// normalized signals the scorer consumes. Returns a "best effort" view —
    /// fields absent from the record (mSCP failures, active CVE counts) are
    /// treated as zero so the device is not unfairly penalized. Wire those in
    /// once the inventory snapshot starts carrying them.
    static func from(record: DeviceInventoryRecord) -> Self {
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
            nessusConnected: nil
        )
    }

    private static func looksAffirmative(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return true }    // missing data ≠ failing
        if text.contains("enabled") || text.contains("escrowed") ||
            text.contains("encrypted") || text == "yes" || text == "true" {
            return true
        }
        return !looksNegative(text)
    }

    private static func looksNegative(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("disabled") || text.contains("not enabled") ||
            text.contains("not escrowed") || text.contains("unencrypted") ||
            text == "no" || text == "false" || text == "0" {
            return true
        }
        return false
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
