import Foundation

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
/// Drives both `ReportEngine.collect`'s per-report cadence filter and the
/// `RefreshCoordinator` staleness model (PR-23 T-16). See
/// `docs/architecture/tiered-collection-adr.md` for the full design.
enum CollectionTier: String, Sendable, Hashable, CaseIterable, Codable {
    case refresh
    case inventory
    case scan

    /// Capitalized label for the Schedules-form tier picker (PR-23 T-17)
    /// and any other UI surface. The raw value stays lowercase for plist
    /// `--tiers` CSV serialization.
    var displayName: String {
        switch self {
        case .refresh:   return "Refresh"
        case .inventory: return "Inventory"
        case .scan:      return "Scan"
        }
    }

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
        // SOFA OS currency feeds — cheap network fetch, no jamf-cli required.
        "sofa":                           .refresh,
        // Merged patch release dates — lightweight post-patch-status step.
        "patch-release-dates":            .refresh,

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
        "smart-computer-groups":              .inventory,
        "groups":                             .inventory,
        "sites":                              .inventory,
        "buildings":                          .inventory,
        "departments":                        .inventory,
        "advanced-mobile-device-searches":    .inventory,
        "classic-computer-groups":            .inventory,
        "classic-mobile-device-groups":       .inventory,
        "categories":                         .inventory,
        "classic-ios-profiles":               .inventory,
        "device-enrollment-instances":        .inventory,
        "mobile-device-inventory-details":    .inventory,

        // Scan — per-device / server-expensive
        "patch-device-failures":          .scan,
        "update-status":                  .scan,
        "update-device-failures":         .scan,
        "device-compliance":              .scan,
        "ea-results":                     .scan,
        "profile-status":                 .scan,
    ]
}
