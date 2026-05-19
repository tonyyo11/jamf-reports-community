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

// MARK: - PR-22 CollectionTier (per-report cadence)

/// Three-tier model that drives per-report collection cadence (PR-22+).
///
/// Tiers are named after **what they keep fresh**, not abstract cadences.
/// Each report belongs to exactly one tier; see `tier(forReport:)`.
///
/// - `refresh`: cheap summary-level reports that feed the Overview KPIs
///   and Trends summary. Default cadence: daily (on-prem) / twice daily
///   (cloud). Safe to schedule frequently — small payloads, no per-device
///   enumeration.
/// - `inventory`: list-type endpoints that feed the Deep Dive screens
///   (Policies, Profiles, Apps, Mobile, EA metadata). Default cadence:
///   weekly (on-prem) / every 2 days (cloud). Moderate cost.
/// - `scan`: full per-device or otherwise server-expensive reports
///   (ea-results --all, *-scan-failures, profile-status, update-status).
///   Default cadence: weekly (both presets). The on-prem preset hard-
///   excludes update-status entirely (server-killer on memory-constrained
///   instances).
///
/// Coexists with the legacy `ScheduleTier` (above) during the PR-22 →
/// PR-23 transition. PR-23 deletes `ScheduleTier` and retargets
/// `RefreshCoordinator` at this tier system. See
/// `docs/architecture/tiered-collection-adr.md` for the full design.
enum CollectionTier: String, Sendable, Hashable, CaseIterable, Codable {
    case refresh
    case inventory
    case scan

    /// Return the tier for a jamf-cli report kind, or nil for unknown names.
    ///
    /// Callers must treat nil as "this report isn't part of the new tier
    /// model" rather than defaulting to a tier — the cadence resolver
    /// (T-7) and the tier-set filter (T-9) need to distinguish unknown
    /// from unmapped.
    ///
    /// Case-sensitive: jamf-cli kinds are lowercase-hyphen by convention
    /// (`patch-device-failures`, never `PatchDeviceFailures`). Mismatched
    /// case returns nil rather than coercing, so a typo in a config
    /// override produces a clear error rather than a silent miss.
    static func tier(forReport kind: String) -> CollectionTier? {
        Self.tierMap[kind]
    }

    /// Every kind in the tier map. Test seam for the inverse contract
    /// (every tier-mapped kind is a real collect kind), and not intended
    /// for production callers — they should use `tier(forReport:)`.
    static var mappedKinds: [String] {
        Array(tierMap.keys)
    }

    // MARK: - RefreshCoordinator support (PR-23 T-16)

    /// On-prem default cadence in seconds — the canonical reference for
    /// `RefreshPolicy`'s backoff math (`interval × 2^failures`).
    ///
    /// On-prem is chosen deliberately: it's the conservative preset, so a
    /// backoff interval derived from it never under-waits on a struggling
    /// self-hosted server. The actual staleness check is preset-aware
    /// (`RefreshCoordinator.isDataStale` reads the live config) — this
    /// value is only the fixed denominator for backoff exponentiation,
    /// which must not shift under the operator mid-session.
    var intervalSeconds: Int {
        CadencePreset.onPrem.defaultCadence(for: self) ?? 86_400
    }

    /// Snapshot directory name `RefreshCoordinator` probes for staleness.
    /// Must be a kind `ReportEngine.collect` actually writes so the mtime
    /// probe finds real files. Each is the cheapest always-present
    /// indicator for its tier.
    var stalenessProbeKind: String {
        switch self {
        case .refresh:   return "overview"
        case .inventory: return "computers"
        case .scan:      return "ea-results"
        }
    }

    // MARK: - Tier assignments

    /// Frozen tier assignments. New jamf-cli commands added to
    /// `ReportEngine.knownCollectKinds` must be added here AND have
    /// their tier deliberately chosen — `CollectionTierLookupTests`
    /// enforces that every known kind is mapped, so a forgotten entry
    /// fails the suite with an explicit list.
    private static let tierMap: [String: CollectionTier] = [
        // Refresh — Overview KPIs + Trends summary
        "overview":                       .refresh,
        "security":                       .refresh,
        "inventory-summary":              .refresh,
        "patch-status":                   .refresh,
        "policy-status":                  .refresh,

        // Inventory — Deep Dive screens
        "app-status":                     .inventory,
        "software-installs":              .inventory,
        "classic-macos-profiles":         .inventory,
        "computer-extension-attributes":  .inventory,
        "mobile-devices-list":            .inventory,
        "compliance-devices":             .inventory,
        "compliance-rules":               .inventory,
        "ddm-status":                     .inventory,
        "blueprint-status":               .inventory,
        "computers":                      .inventory,
        "policies":                       .inventory,
        "scripts":                        .inventory,
        "packages":                       .inventory,
        "smart-computer-groups":          .inventory,
        "sites":                          .inventory,
        "buildings":                      .inventory,
        "departments":                    .inventory,

        // Scan — per-device / server-expensive
        "patch-device-failures":          .scan,
        "update-status":                  .scan,
        "update-device-failures":         .scan,
        "device-compliance":              .scan,
        "ea-results":                     .scan,
        "profile-status":                 .scan,
    ]
}
