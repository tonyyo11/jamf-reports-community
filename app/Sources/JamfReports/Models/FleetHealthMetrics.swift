import Foundation

// MARK: - Security score

/// The weighted fleet-wide security score: the sum of weight x share over the sum of weights,
/// across the listed factors that have data (`SecurityScoreCalculator`). A factor with no data
/// drops out and the rest are rescaled, so tenants with different agent stacks still get a
/// comparable score.
struct SecurityScore: Sendable, Equatable {
    /// 0-100, one decimal.
    let value: Double
    /// Letter grade derived from `value` per `Grade.from(value:)`.
    let grade: Grade
    /// The factors that had data, in list order, with what each measured.
    let parts: [Part]
    /// Listed factors with no data this run; their weight is left out.
    let missing: [SecurityScoreFactor]

    struct Part: Sendable, Equatable {
        let factor: SecurityScoreFactor
        let measure: SecurityScoreMeasure
        /// 0-100.
        let share: Double
    }

    static let empty = SecurityScore(value: 0, grade: .f, parts: [], missing: [])

    /// Factors that contributed to `value`.
    var available: [SecurityScoreFactor] { parts.map(\.factor) }

    /// The summary's `securityScoreBasis`; nil when nothing was scored.
    var basis: String? { parts.isEmpty ? nil : SecurityScoreFactor.basis(available) }

    /// What `part` adds to `value`, in points out of 100.
    func points(of part: Part) -> Double {
        let total = parts.reduce(0) { $0 + $1.factor.weight }
        guard total > 0 else { return 0 }
        return part.share * part.factor.weight / total
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
            case .clean:    return L("Clean")
            case .low:      return L("Low")
            case .medium:   return L("Medium")
            case .high:     return L("High")
            case .critical: return L("Critical")
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

    /// The risk factors from v3.5 (less the boot-drive one, which jamf-cli data cannot supply). Each carries a default point value and a
    /// remediation string; both are configurable via `RiskFactorWeights`.
    enum Factor: String, CaseIterable, Sendable, Hashable {
        case noFileVault
        case secureBootNone
        case sipDisabled
        case gatekeeperDisabled
        case firewallDisabled
        case mscpHighFailures
        case mscpMediumFailures
        case noBaseline
        case activeCVE
        case secureBootMedium
        case staleOffline
        /// A configured `security_agents` entry's EA reports the agent as not
        /// connected. v3.5 hardcoded this to Nessus; the agent (and its EA
        /// column + connected value) is now whatever config.yaml defines.
        /// The raw value keeps the legacy name for v3.5-parity traceability.
        case securityAgentDisconnected = "nessusDisconnected"
        case bootstrapMissing

        var displayLabel: String {
            switch self {
            case .noFileVault:        return L("No FileVault Encryption")
            case .secureBootNone:     return L("Secure Boot: No Security")
            case .sipDisabled:        return L("SIP Disabled")
            case .gatekeeperDisabled: return L("Gatekeeper Disabled")
            case .firewallDisabled:   return L("Firewall Disabled")
            case .mscpHighFailures:   return L("mSCP High Failures")
            case .mscpMediumFailures: return L("mSCP Medium Failures")
            case .noBaseline:         return L("No mSCP Baseline (Active)")
            case .activeCVE:          return L("Active CVE With Exploits")
            case .secureBootMedium:   return L("Secure Boot: Medium Security")
            case .staleOffline:       return L("Stale Device (Offline)")
            case .securityAgentDisconnected: return L("Security Agent Disconnected")
            case .bootstrapMissing:   return L("Bootstrap Token Missing")
            }
        }

        /// Tenant-specific label: the configured security agent's name (e.g.
        /// "Nessus Agent Disconnected") for `.securityAgentDisconnected`; the
        /// static label for everything else.
        func displayLabel(agentName: String?) -> String {
            if case .securityAgentDisconnected = self, let name = agentName, !name.isEmpty {
                return L("\(name) Disconnected")
            }
            return displayLabel
        }

        var remediation: String {
            switch self {
            case .noFileVault:        return L("Enable FileVault 2 via configuration profile.")
            case .secureBootNone:     return L("Set Secure Boot to Full Security in Startup Utility.")
            case .sipDisabled:        return L("Re-enable SIP from Recovery (csrutil enable).")
            case .gatekeeperDisabled: return L("Re-enable Gatekeeper via profile or `spctl --master-enable`.")
            case .firewallDisabled:   return L("Deploy firewall configuration profile.")
            case .mscpHighFailures:   return L("Investigate failing High-severity mSCP rules.")
            case .mscpMediumFailures: return L("Schedule remediation of Medium-severity mSCP rules.")
            case .noBaseline:         return L("Assign mSCP baseline via PreStage or scope.")
            case .activeCVE:          return L("Apply pending macOS updates to clear active exploit.")
            case .secureBootMedium:   return L("Upgrade Secure Boot to Full Security.")
            case .staleOffline:       return L("User outreach — locate device, force check-in.")
            case .securityAgentDisconnected: return L("Re-link the security agent via its deployment policy.")
            case .bootstrapMissing:   return L("Re-enroll device (profiles renew enrollment).")
            }
        }

        /// Tenant-specific remediation for `.securityAgentDisconnected`; the
        /// static remediation for everything else.
        func remediation(agentName: String?) -> String {
            if case .securityAgentDisconnected = self, let name = agentName, !name.isEmpty {
                return L("Re-link \(name) via its deployment policy.")
            }
            return remediation
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
    var mscpHighPerFailure: Int
    var mscpHighCap: Int
    var mscpMediumPerFailure: Int
    var mscpMediumCap: Int
    var noBaseline: Int
    var activeCVE: Int
    var secureBootMedium: Int
    var staleOffline: Int
    /// Points when the configured security agent reports disconnected
    /// (v3.5's "Nessus disconnected" factor, now config-driven).
    var securityAgentDisconnected: Int
    var bootstrapMissing: Int

    static let defaultWeights = RiskFactorWeights(
        noFileVault: 15,
        secureBootNone: 12,
        sipDisabled: 8,
        gatekeeperDisabled: 6,
        firewallDisabled: 6,
        mscpHighPerFailure: 7,
        mscpHighCap: 21,
        mscpMediumPerFailure: 4,
        mscpMediumCap: 8,
        noBaseline: 8,
        activeCVE: 10,
        secureBootMedium: 5,
        staleOffline: 5,
        securityAgentDisconnected: 5,
        bootstrapMissing: 4
    )
}
