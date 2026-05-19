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
}
