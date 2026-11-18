import Foundation

/// `jamf_cli.collect_skip`: the on-prem stall guard. An operator lists the
/// per-device-heavy reports their Jamf Pro server cannot answer without stalling,
/// and `collect` never runs them.
extension ReportEngine {

    /// The only kinds `collect_skip` can remove: the four per-device-heavy queries
    /// known to stall on-prem Jamf Pro, jamf-cli's `dashboard`, which sweeps the
    /// whole inventory again for a page only the HTML report uses, and `sofa`, the
    /// one fetch from a third-party host, for a network that must not reach it, and
    /// `security-risk`, the Jamf Security Cloud device list, for an organization that keeps it out, and `school-device-detail`, the Jamf School
    /// per-device scan, and `patch-status`, for a server that cannot list its patch titles in
    /// time (a 5,900-Mac fleet, 2.12.0-rc1).
    /// Anything else in the list is ignored, so a typo or an over-eager list can never
    /// stop core inventory from being collected.
    static let skippableKinds: Set<String> = [
        "patch-status",
        "patch-device-failures",
        "profile-status",
        "update-status",
        "update-device-failures",
        dashboardKind,
        sofaKind,
        securityRiskKind,
        schoolDeviceDetailKind,
    ]

    /// `collect_skip` as kind names: trimmed, lowercased, underscores read as hyphens
    /// (`update_status` is `update-status`), and narrowed to `skippableKinds`.
    static func collectSkipKinds(_ raw: [String]?) -> Set<String> {
        let names = (raw ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
        }
        var kinds = Set(names).intersection(skippableKinds)
        // The release-date walk reads the patch-status snapshot and has nothing to walk without
        // it, and the failures scan starts with the same patch-title request.
        if kinds.contains("patch-status") {
            kinds.formUnion([patchReleaseDatesKind, "patch-device-failures"])
        }
        return kinds
    }
}
