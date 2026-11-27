import Foundation

/// `jamf_cli.collect_skip`: the sources an organization turned off, from the Data Sources
/// switches or typed by hand. Every collect path, the health strip and Data Sources read it
/// through `SharedConfigPin.collectSkip`, which narrows it here.
extension ReportEngine {

    /// The Mac sources the daily summary and most screens are built from: `security` and
    /// `inventory-summary` give the Mac count, `device-compliance` the stale count, `computers`
    /// the inventory. Core unless the fleet's Mac side is skipped (no computers).
    static let macCoreKinds: Set<String> = [
        "security", "inventory-summary", "device-compliance", "computers",
    ]

    /// Every source the app collects, for every product.
    static let allSourceKinds: Set<String> = Set(knownCollectKinds)
        .union(schoolCommandMatrix(profile: "").map(\.kind))
        .union(protectCommandMatrix(profile: "").map(\.kind))
        .union([schoolDeviceDetailKind, securityRiskKind])

    /// Whether `kind` can never be turned off here, the one answer for the writer, the planner,
    /// the screen and Config Doctor. `overview` (the fleet count, the site-scope check) and
    /// Jamf School's device list always; the Mac core unless the Mac side is skipped;
    /// `mobile-devices-list` only on a mobile-only fleet, whose summary is built from it;
    /// `protect-computers` only in a Protect-only environment.
    static func isCoreKind(
        _ kind: String, protectOnly: Bool = false, fleet: FleetState = .unknown
    ) -> Bool {
        switch kind {
        case "overview", SchoolFleetService.devicesKind: return true
        case "mobile-devices-list": return fleet.isMobileOnly && !fleet.skipped.contains(.mobile)
        case "protect-computers": return protectOnly
        default: return macCoreKinds.contains(kind) && !fleet.skipped.contains(.mac)
        }
    }

    /// The sources that can be turned off here. An opt-in source is off until turned on, so it
    /// has no collect_skip switch.
    static func optionalKinds(
        protectOnly: Bool = false, fleet: FleetState = .unknown
    ) -> Set<String> {
        allSourceKinds.filter { !isCoreKind($0, protectOnly: protectOnly, fleet: fleet) }
            .subtracting(serverHealthOptInKinds)
    }

    /// `collect_opt_in` as the opt-in sources it names (same normalizing as `collect_skip`).
    static func listedOptInKinds(_ raw: [String]?) -> Set<String> {
        Set((raw ?? []).map(normalizedKind)).intersection(serverHealthOptInKinds)
    }

    /// `collect_skip` as the list it names: trimmed, lowercased, underscores read as hyphens,
    /// narrowed to `optionalKinds`, so a typo can never stop core inventory. No dependents.
    static func listedSkipKinds(
        _ raw: [String]?, protectOnly: Bool = false, fleet: FleetState = .unknown
    ) -> Set<String> {
        Set((raw ?? []).map(normalizedKind))
            .intersection(optionalKinds(protectOnly: protectOnly, fleet: fleet))
    }

    static func normalizedKind(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    /// The kinds a list turns off: `listedSkipKinds` plus the sources that need `patch-status`.
    static func collectSkipKinds(
        _ raw: [String]?, protectOnly: Bool = false, fleet: FleetState = .unknown
    ) -> Set<String> {
        var kinds = listedSkipKinds(raw, protectOnly: protectOnly, fleet: fleet)
        // The release-date walk reads the patch-status snapshot and has nothing to walk without
        // it, and the failures scan starts with the same patch-title request.
        if kinds.contains("patch-status") { kinds.formUnion(patchStatusDependents) }
        return kinds
    }

    /// The sources that go quiet with `patch-status`.
    static let patchStatusDependents: Set<String> = [patchReleaseDatesKind, "patch-device-failures"]
}
