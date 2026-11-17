import Foundation

/// `jamf_cli.collect_skip`: the sources an organization turned off, from the Data Sources
/// switches or typed by hand. Every collect path, the health strip and Data Sources read it
/// through `SharedConfigPin.collectSkip`, which narrows it here.
extension ReportEngine {

    /// The Jamf Pro sources the daily summary and most screens are built from: `security` and
    /// `inventory-summary` give the Mac count, `mobile-devices-list` the count of a fleet with
    /// no Macs, `device-compliance` the stale count, `computers` the inventory, `overview` the
    /// site-scope check and the background refresh's freshness probe.
    static let coreProKinds: Set<String> = [
        "overview", "security", "inventory-summary", "device-compliance", "computers",
        "mobile-devices-list",
    ]

    /// Jamf School's summary input.
    static let coreSchoolKinds: Set<String> = [SchoolFleetService.devicesKind]

    /// The one source a Protect-only environment's summary reads.
    static let coreProtectOnlyKinds: Set<String> = ["protect-computers"]

    /// Every source the app collects, for every product.
    static let allSourceKinds: Set<String> = Set(knownCollectKinds)
        .union(schoolCommandMatrix(profile: "").map(\.kind))
        .union(protectCommandMatrix(profile: "").map(\.kind))
        .union([schoolDeviceDetailKind, securityRiskKind])

    /// The sources that can be turned off. Protect is optional beside an MDM; in a Protect-only
    /// environment its computer list is the summary's input.
    static func optionalKinds(protectOnly: Bool = false) -> Set<String> {
        allSourceKinds.subtracting(coreProKinds).subtracting(coreSchoolKinds)
            .subtracting(protectOnly ? coreProtectOnlyKinds : [])
    }

    /// Whether `kind` can never be turned off in this environment.
    static func isCoreKind(_ kind: String, protectOnly: Bool = false) -> Bool {
        allSourceKinds.contains(kind) && !optionalKinds(protectOnly: protectOnly).contains(kind)
    }

    /// `collect_skip` as the list it names: trimmed, lowercased, underscores read as hyphens,
    /// narrowed to `optionalKinds`, so a typo can never stop core inventory. No dependents.
    static func listedSkipKinds(_ raw: [String]?, protectOnly: Bool = false) -> Set<String> {
        Set((raw ?? []).map(normalizedKind)).intersection(optionalKinds(protectOnly: protectOnly))
    }

    static func normalizedKind(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    /// The kinds a list turns off: `listedSkipKinds` plus the sources that need `patch-status`.
    static func collectSkipKinds(_ raw: [String]?, protectOnly: Bool = false) -> Set<String> {
        var kinds = listedSkipKinds(raw, protectOnly: protectOnly)
        // The release-date walk reads the patch-status snapshot and has nothing to walk without
        // it, and the failures scan starts with the same patch-title request.
        if kinds.contains("patch-status") { kinds.formUnion(patchStatusDependents) }
        return kinds
    }

    /// The sources that go quiet with `patch-status`.
    static let patchStatusDependents: Set<String> = [patchReleaseDatesKind, "patch-device-failures"]
}
