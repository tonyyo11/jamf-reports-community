import Foundation

/// Three-tier model that drives per-report collection cadence.
///
/// Tiers are named after **what they keep fresh**, not abstract cadences.
/// Each report belongs to exactly one tier; see `tier(forReport:)`.
///
/// - `refresh`: cheap summary-level reports that feed the Overview KPIs
///   and Trends summary. Fixed cadence: 43 200 s (12 h / twice daily).
///   Safe to schedule frequently — small payloads, no per-device
///   enumeration.
/// - `inventory`: list-type endpoints that feed the Deep Dive screens
///   (Policies, Profiles, Apps, Mobile, EA metadata, per-device posture
///   without the expensive --scan-failures fan-out). Fixed cadence:
///   172 800 s (every 2 days).
/// - `scan`: the two `--scan-failures` per-device fan-out queries only
///   (`patch-device-failures`, `update-device-failures`). These drive
///   the Patch Failures and Update Failures sheets and are the only
///   commands that enumerate every failing device in detail. Fixed
///   cadence: 604 800 s (weekly).
///
/// Drives both `ReportEngine.collect`'s per-report cadence filter and the
/// `RefreshCoordinator` staleness model.
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

    // MARK: - RefreshCoordinator support

    /// Fixed collection cadence in seconds for this tier. Also serves as the
    /// denominator for `RefreshPolicy`'s backoff math (`interval × 2^failures`).
    var intervalSeconds: Int {
        switch self {
        case .refresh:   return 43_200
        case .inventory: return 172_800
        case .scan:      return 604_800
        }
    }

    /// Snapshot directory name `RefreshCoordinator` probes for staleness.
    /// Must be a kind `ReportEngine.collect` actually writes so the mtime
    /// probe finds real files. Each is the cheapest always-present
    /// indicator for its tier.
    var stalenessProbeKind: String {
        switch self {
        case .refresh:   return "overview"
        case .inventory: return "computers"
        case .scan:      return "update-device-failures"
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
        // Single cheap server call; WorkspaceStore+Refresh already probes "audit" for
        // staleness, so keeping it fresh is required at the refresh cadence.
        "audit":                          .refresh,
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

        // Inventory (continued) — per-device posture without --scan-failures fan-out
        "update-status":                  .inventory,
        "device-compliance":              .inventory,
        "ea-results":                     .inventory,
        "profile-status":                 .inventory,

        // Scan — the two --scan-failures per-device fan-outs only.
        // These enumerate every failing device in detail and are the only
        // commands that trigger jamf-cli's expensive per-device API calls.
        // Daily automation runs refresh+inventory; scan runs weekly only.
        "patch-device-failures":          .scan,
        "update-device-failures":         .scan,
    ]
}
