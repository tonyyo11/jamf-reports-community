import Foundation

// MARK: - Security score

/// Weighted fleet-wide security score lifted from jamf_reports_cli_v3.5.py
/// `FleetHealthDashboard._calculate_metrics()`. Weights are configurable;
/// metrics whose source column is missing are skipped and weights renormalized
/// so the score remains comparable across tenants with different agent stacks.
struct SecurityScore: Sendable, Equatable {
    /// 0–100 weighted average over the metrics in `available`.
    let value: Double
    /// Letter grade derived from `value` per `Grade.from(value:)`.
    let grade: Grade
    /// Metrics whose source data was present and contributed to `value`.
    let available: [Metric]
    /// Metrics that had no source data this run and were skipped.
    let missing: [Metric]
    /// Weights actually applied (after dropping `missing`).
    let appliedWeights: [Metric: Double]

    enum Metric: String, CaseIterable, Sendable, Hashable {
        case fileVault, sip, firewall, crowdstrike, mscp,
             xprotect, cve, secureBoot

        var displayLabel: String {
            switch self {
            case .fileVault:  return "FileVault Encryption"
            case .sip:        return "System Integrity Protection"
            case .firewall:   return "Firewall Enabled"
            case .crowdstrike: return "CrowdStrike Connected"
            case .mscp:       return "mSCP Compliance"
            case .xprotect:   return "XProtect Current"
            case .cve:        return "CVE Clean"
            case .secureBoot: return "Secure Boot (Full)"
            }
        }
    }

    enum Grade: String, Sendable, Equatable {
        case aPlus = "A+", a = "A", b = "B", c = "C", d = "D", f = "F"

        /// Letter-grade banding lifted from v3.5 executive-summary rendering.
        /// `nil` value (no data) returns `.f` so callers can show "Insufficient
        /// data" rather than silently passing.
        static func from(value: Double?) -> Grade {
            guard let value, value.isFinite else { return .f }
            switch value {
            case 95...:    return .aPlus
            case 90..<95:  return .a
            case 80..<90:  return .b
            case 70..<80:  return .c
            case 60..<70:  return .d
            default:       return .f
            }
        }

        var colorHex: UInt32 {
            switch self {
            case .aPlus, .a: return 0x30D158
            case .b:         return 0x0A84FF
            case .c:         return 0xE8B614
            case .d:         return 0xFF9F0A
            case .f:         return 0xFF453A
            }
        }
    }
}

/// Per-user override of the SecurityScoreWeights, persisted via @AppStorage.
/// Stored as a single comma-separated string of integers in the order
/// `fileVault,sip,firewall,crowdstrike,mscp,xprotect,cve,secureBoot` for
/// stability. Missing or malformed values fall back to the v3.5 defaults so
/// a corrupted preference can never break the score.
struct ScoringConfig: Sendable, Equatable {
    var weights: SecurityScoreWeights

    static let storageKey = "securityScoreWeights"

    init(weights: SecurityScoreWeights = .defaultWeights) {
        self.weights = weights
    }

    static func parse(_ raw: String) -> ScoringConfig {
        let parts = raw
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 8 else { return ScoringConfig() }
        // Any nil component falls back to the v3.5 default for that slot —
        // a user who hand-corrupts the preference still gets a coherent score.
        let d = SecurityScoreWeights.defaultWeights
        return ScoringConfig(weights: SecurityScoreWeights(
            fileVault: parts[0] ?? d.fileVault,
            sip: parts[1] ?? d.sip,
            firewall: parts[2] ?? d.firewall,
            crowdstrike: parts[3] ?? d.crowdstrike,
            mscp: parts[4] ?? d.mscp,
            xprotect: parts[5] ?? d.xprotect,
            cve: parts[6] ?? d.cve,
            secureBoot: parts[7] ?? d.secureBoot
        ))
    }

    func serialize() -> String {
        let w = weights
        return [w.fileVault, w.sip, w.firewall, w.crowdstrike,
                w.mscp, w.xprotect, w.cve, w.secureBoot]
            .map { String(format: "%g", $0) }
            .joined(separator: ",")
    }
}

/// Configurable per-metric weights. Defaults lifted verbatim from
/// `jamf_reports_cli_v3.5.py:2961`. Weights sum to 100 by default; the
/// calculator renormalizes whatever subset is `available` this run.
struct SecurityScoreWeights: Sendable, Equatable {
    var fileVault: Double
    var sip: Double
    var firewall: Double
    var crowdstrike: Double
    var mscp: Double
    var xprotect: Double
    var cve: Double
    var secureBoot: Double

    static let defaultWeights = SecurityScoreWeights(
        fileVault: 15,
        sip: 15,
        firewall: 15,
        crowdstrike: 10,
        mscp: 20,
        xprotect: 5,
        cve: 15,
        secureBoot: 5
    )

    func weight(for metric: SecurityScore.Metric) -> Double {
        switch metric {
        case .fileVault:  return fileVault
        case .sip:        return sip
        case .firewall:   return firewall
        case .crowdstrike: return crowdstrike
        case .mscp:       return mscp
        case .xprotect:   return xprotect
        case .cve:        return cve
        case .secureBoot: return secureBoot
        }
    }
}

// MARK: - Per-device risk

/// Output of `RiskScoringService.score(device:)`. Bands lifted from v3.5
/// `FleetHealthDashboard._compute_device_risk()` (Critical ≥20, High ≥15,
/// Medium ≥10, Low >0, Clean = 0).
struct DeviceRisk: Sendable, Equatable {
    let score: Int
    let level: Level
    /// Triggered factors in priority order (highest-point first). Used by the
    /// Priority Action List to render a Remediation column without re-running
    /// the calculator.
    let triggered: [TriggeredFactor]

    enum Level: String, Sendable, Equatable, Comparable {
        case clean, low, medium, high, critical

        var displayLabel: String {
            switch self {
            case .clean:    return "Clean"
            case .low:      return "Low"
            case .medium:   return "Medium"
            case .high:     return "High"
            case .critical: return "Critical"
            }
        }

        var colorHex: UInt32 {
            switch self {
            case .clean:    return 0x30D158
            case .low:      return 0x8E8E93
            case .medium:   return 0xE8B614
            case .high:     return 0xFF9F0A
            case .critical: return 0xFF453A
            }
        }

        private var sortKey: Int {
            switch self {
            case .clean: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            case .critical: return 4
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.sortKey < rhs.sortKey
        }

        static func from(score: Int) -> Level {
            switch score {
            case ..<1:    return .clean
            case 1..<10:  return .low
            case 10..<15: return .medium
            case 15..<20: return .high
            default:      return .critical
            }
        }
    }

    struct TriggeredFactor: Sendable, Equatable, Hashable {
        let factor: Factor
        let points: Int
        /// Optional context (e.g., observed High-severity failure count).
        let detail: String?
    }

    /// The 14 risk factors from v3.5. Each carries a default point value and a
    /// remediation string; both are configurable via `RiskFactorWeights`.
    enum Factor: String, CaseIterable, Sendable, Hashable {
        case noFileVault
        case secureBootNone
        case sipDisabled
        case gatekeeperDisabled
        case firewallDisabled
        case bootDriveFull
        case mscpHighFailures
        case mscpMediumFailures
        case noBaseline
        case activeCVE
        case secureBootMedium
        case staleOffline
        case nessusDisconnected
        case bootstrapMissing

        var displayLabel: String {
            switch self {
            case .noFileVault:        return "No FileVault Encryption"
            case .secureBootNone:     return "Secure Boot: No Security"
            case .sipDisabled:        return "SIP Disabled"
            case .gatekeeperDisabled: return "Gatekeeper Disabled"
            case .firewallDisabled:   return "Firewall Disabled"
            case .bootDriveFull:      return "Boot Drive >95% Full"
            case .mscpHighFailures:   return "mSCP High Failures"
            case .mscpMediumFailures: return "mSCP Medium Failures"
            case .noBaseline:         return "No mSCP Baseline (Active)"
            case .activeCVE:          return "Active CVE With Exploits"
            case .secureBootMedium:   return "Secure Boot: Medium Security"
            case .staleOffline:       return "Stale Device (Offline)"
            case .nessusDisconnected: return "Nessus Disconnected"
            case .bootstrapMissing:   return "Bootstrap Token Missing"
            }
        }

        var remediation: String {
            switch self {
            case .noFileVault:        return "Enable FileVault 2 via configuration profile."
            case .secureBootNone:     return "Set Secure Boot to Full Security in Startup Utility."
            case .sipDisabled:        return "Re-enable SIP from Recovery (csrutil enable)."
            case .gatekeeperDisabled: return "Re-enable Gatekeeper via profile or `spctl --master-enable`."
            case .firewallDisabled:   return "Deploy firewall configuration profile."
            case .bootDriveFull:      return "User outreach — free disk space immediately."
            case .mscpHighFailures:   return "Investigate failing High-severity mSCP rules."
            case .mscpMediumFailures: return "Schedule remediation of Medium-severity mSCP rules."
            case .noBaseline:         return "Assign mSCP baseline via PreStage or scope."
            case .activeCVE:          return "Apply pending macOS updates to clear active exploit."
            case .secureBootMedium:   return "Upgrade Secure Boot to Full Security."
            case .staleOffline:       return "User outreach — locate device, force check-in."
            case .nessusDisconnected: return "Re-link Nessus agent via standard policy."
            case .bootstrapMissing:   return "Re-enroll device (profiles renew enrollment)."
            }
        }
    }
}

/// Configurable factor weights and severity caps. Defaults lifted from
/// `FleetHealthDashboard._compute_device_risk()` in v3.5.
struct RiskFactorWeights: Sendable, Equatable {
    var noFileVault: Int
    var secureBootNone: Int
    var sipDisabled: Int
    var gatekeeperDisabled: Int
    var firewallDisabled: Int
    var bootDriveFull: Int
    var mscpHighPerFailure: Int
    var mscpHighCap: Int
    var mscpMediumPerFailure: Int
    var mscpMediumCap: Int
    var noBaseline: Int
    var activeCVE: Int
    var secureBootMedium: Int
    var staleOffline: Int
    var nessusDisconnected: Int
    var bootstrapMissing: Int
    /// Boot drive fullness threshold (percent). Defaults to 95%.
    var bootDriveFullThresholdPct: Int

    static let defaultWeights = RiskFactorWeights(
        noFileVault: 15,
        secureBootNone: 12,
        sipDisabled: 8,
        gatekeeperDisabled: 6,
        firewallDisabled: 6,
        bootDriveFull: 8,
        mscpHighPerFailure: 7,
        mscpHighCap: 21,
        mscpMediumPerFailure: 4,
        mscpMediumCap: 8,
        noBaseline: 8,
        activeCVE: 10,
        secureBootMedium: 5,
        staleOffline: 5,
        nessusDisconnected: 5,
        bootstrapMissing: 4,
        bootDriveFullThresholdPct: 95
    )
}
