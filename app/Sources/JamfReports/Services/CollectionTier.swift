import Foundation

/// Three-tier scheduling model for background jamf-cli collections.
///
/// The goal is to be a good neighbor on the user's Mac. Running every jamf-cli
/// command every 15 minutes would hammer the Jamf server and keep the local
/// machine busy. Tiers exist so cheap/frequent reads stay hot while expensive
/// full-inventory scans happen only when the data is actually stale.
///
/// Note: the Engine layer has a type also named `CollectionTier` that represents
/// a *template dependency hint* (core/platform/protect/full). This type is named
/// `ScheduleTier` to avoid ambiguity — it represents *scheduling cadence*, not
/// data completeness.
///
/// Command sets are expressed as argv fragments passed to `jamf-cli -p <profile>`.
/// They must correspond to methods already implemented in `CLIBridge`; none are
/// invented here.
enum ScheduleTier: String, Sendable, Hashable, CaseIterable {

    /// Cheap read commands. Runs every 15 minutes.
    ///
    /// Only fetches summary-level data so the network round-trip is small.
    /// `pro inventory list` gives total/managed counts; `pro report security`
    /// with `--summary-only` gives the top-level security posture summary.
    case hot

    /// Medium-cost audit and patch commands. Runs every 4 hours.
    ///
    /// Omits `--scan-failures` on patch-status and update-status — those
    /// fetch per-device details from the Jamf API and are moved to `.cold`.
    case warm

    /// Full inventory dumps and failure-detail scans. Runs every 24 hours.
    ///
    /// `--scan-failures` fetches per-device records from
    /// `/v2/patch-policies/{id}/logs/{deviceId}/details` and the update-plans
    /// endpoint — expensive on large fleets. Protect and School resources also
    /// land here because they require separate auth contexts.
    case cold

    // MARK: - Interval

    /// Intended cadence in seconds. Used by `RefreshPolicy` as the staleness
    /// threshold and by `TieredLaunchAgentWriter` as `StartInterval`.
    var intervalSeconds: Int {
        switch self {
        case .hot:  return 15 * 60          // 900 s
        case .warm: return 4 * 60 * 60      // 14 400 s
        case .cold: return 24 * 60 * 60     // 86 400 s
        }
    }

    // MARK: - Staleness probe

    /// The snapshot directory name that `RefreshCoordinator` uses to determine
    /// whether this tier's data is stale. Must correspond to a directory that
    /// `ReportEngine.collect` actually writes so the probe finds real files.
    var stalenessProbeKind: String {
        switch self {
        case .hot:  return "overview"                // always written; cheapest indicator
        case .warm: return "policy-status"           // written in every collect
        case .cold: return "patch-device-failures"
        }
    }

    // MARK: - Display

    /// Human-readable interval string for UI and log output.
    var displayInterval: String {
        switch self {
        case .hot:  return "15 min"
        case .warm: return "4 h"
        case .cold: return "24 h"
        }
    }
}
