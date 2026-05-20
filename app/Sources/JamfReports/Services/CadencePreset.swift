import Foundation

/// PR-22: server-load preset that bundles per-tier cadence defaults,
/// inter-call pacing, and hard exclusions.
///
/// The preset is per-profile (a single workspace can have one cloud
/// and one on-prem profile with different presets). Stored in
/// `config.yaml` as `collect_cadence.preset: on-prem | cloud | custom`.
///
/// Two non-custom presets exist so a fresh install does the right
/// thing without YAML editing — on-prem defaults are conservative to
/// avoid hammering self-hosted Jamf Pro instances; cloud defaults are
/// twice-daily Refresh to keep the Overview screen current on
/// jamfcloud tenants that can absorb the API calls.
///
/// **Cadence numbers are the public contract.** Pinned in
/// `CadencePresetTests`; changing them is a behavioral change worth a
/// CHANGELOG entry. See `docs/architecture/tiered-collection-adr.md` →
/// "Server-load presets" for the full rationale.
enum CadencePreset: String, Sendable, Hashable, CaseIterable, Codable {
    case onPrem = "on-prem"
    case cloud  = "cloud"
    case custom = "custom"

    /// Per-tier cadence in seconds, or nil for `.custom` (which requires
    /// every report to have an explicit `per_report` entry).
    func defaultCadence(for tier: CollectionTier) -> Int? {
        switch (self, tier) {
        case (.onPrem, .refresh):    return 86_400      // daily
        case (.onPrem, .inventory):  return 604_800     // weekly
        case (.onPrem, .scan):       return 604_800     // weekly

        case (.cloud, .refresh):     return 43_200      // twice daily (12 h)
        case (.cloud, .inventory):   return 172_800     // every 2 days
        case (.cloud, .scan):        return 604_800     // weekly

        case (.custom, _):           return nil
        }
    }

    /// Sleep between successive jamf-cli calls during a collect run.
    /// On-prem benefits from breathing room (Tomcat thread pool, etc.);
    /// cloud endpoints handle back-to-back calls fine.
    var paceSeconds: Int {
        switch self {
        case .onPrem: return 15
        case .cloud:  return 0
        case .custom: return 0
        }
    }

    /// Report kinds the preset refuses to fetch regardless of tier
    /// assignment. Implements the "kill-switch" pattern from the
    /// reference `collect.zsh` for memory-fragile on-prem servers.
    /// Users wanting these on cloud can switch to .custom and set
    /// the per_report cadence explicitly.
    var hardExcludedKinds: Set<String> {
        switch self {
        case .onPrem:
            // Per-device update plan enumeration crashes on-prem Jamf
            // Pro with memory exhaustion (~doc'd in collect.zsh comments,
            // 2026-04 incident at the reference deployment).
            return ["update-status", "update-device-failures"]
        case .cloud, .custom:
            return []
        }
    }

    // MARK: - Display (PR-23 T-21)

    /// Operator-facing name for the Settings → Performance radio picker.
    var displayName: String {
        switch self {
        case .onPrem: return "On-prem"
        case .cloud:  return "Cloud"
        case .custom: return "Custom"
        }
    }

    /// One-line rationale shown under each radio option.
    var displaySubtitle: String {
        switch self {
        case .onPrem:
            return "Conservative cadence for self-hosted Jamf Pro. Paces calls and skips the server-killer reports."
        case .cloud:
            return "Faster cadence for jamfcloud tenants that absorb API calls without pacing."
        case .custom:
            return "Set every report's tier and cadence by hand in the editor below."
        }
    }

    /// Per-tier cadence summary for the preset-picker preview.
    ///
    /// `.custom` has no preset-wide cadences — each report is configured
    /// individually — so it returns a pointer to the per-report editor
    /// rather than a tier list.
    var cadenceSummary: String {
        switch self {
        case .custom:
            return "Per-report — configure each report individually."
        case .onPrem, .cloud:
            return CollectionTier.allCases.map { tier in
                let seconds = defaultCadence(for: tier) ?? 0
                return "\(tier.displayName): \(Self.humanCadence(seconds: seconds))"
            }.joined(separator: " · ")
        }
    }

    /// Render a cadence interval in seconds as an operator-friendly phrase.
    /// The exact preset values get bespoke phrasing; anything else falls
    /// back to a generic "Every N days/hours".
    static func humanCadence(seconds: Int) -> String {
        switch seconds {
        case 43_200:  return "Twice daily"
        case 86_400:  return "Daily"
        case 172_800: return "Every 2 days"
        case 604_800: return "Weekly"
        default:
            if seconds > 0, seconds % 86_400 == 0 { return "Every \(seconds / 86_400) days" }
            if seconds > 0, seconds % 3_600 == 0 { return "Every \(seconds / 3_600) h" }
            return "\(seconds) s"
        }
    }
}
