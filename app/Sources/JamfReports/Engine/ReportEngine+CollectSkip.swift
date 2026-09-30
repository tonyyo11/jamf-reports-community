import Foundation

/// `jamf_cli.collect_skip`: the on-prem stall guard. An operator lists the
/// per-device-heavy reports their Jamf Pro server cannot answer without stalling,
/// and `collect` never runs them.
extension ReportEngine {

    /// The only kinds `collect_skip` can remove: the four per-device-heavy queries
    /// known to stall on-prem Jamf Pro, and jamf-cli's `dashboard`, which sweeps the
    /// whole inventory again for a page only the HTML report uses. Anything else in
    /// the list is ignored, so a typo or an over-eager list can never stop core
    /// inventory from being collected.
    static let skippableKinds: Set<String> = [
        "patch-device-failures",
        "profile-status",
        "update-status",
        "update-device-failures",
        dashboardKind,
    ]

    /// `collect_skip` as kind names: trimmed, lowercased, underscores read as hyphens
    /// (`update_status` is `update-status`), and narrowed to `skippableKinds`.
    static func collectSkipKinds(_ raw: [String]?) -> Set<String> {
        let names = (raw ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
        }
        return Set(names).intersection(skippableKinds)
    }
}
