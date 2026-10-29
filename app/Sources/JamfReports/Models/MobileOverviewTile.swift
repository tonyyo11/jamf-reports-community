import Foundation

/// One line of the Overview's Mobile Devices section (mobile spec 3.1, decision M-D1: four
/// lines and nothing more). A figure no device reports shows a dash and says so, never 0 or 0%.
struct MobileOverviewTile: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    /// What the figure counts, so a share never reads as a share of the whole fleet.
    let caption: String
    /// True for the Needs attention line, which opens the Health Audit.
    var opensAudit = false

    var id: String { label }

    static let unreported = "Not reported"
    static let dash = "—"
}

extension MobileSummary {
    /// The jailbroken, unmanaged and update-error devices as one number. A part no device or
    /// scan reports contributes nothing, so the number never counts an unknown as a device.
    var needsAttentionCount: Int { (jailbroken ?? 0) + unmanaged + (updateErrors ?? 0) }

    /// The section's lines in display order: Devices, the OS current and passcode shares, then
    /// Needs attention, which is left out when it is 0.
    ///
    /// Devices is the managed mobile device count. It stands in for the spec's iPad, iPhone and
    /// Apple TV counts until the summary carries a form-factor map (environment spec P9).
    var overviewTiles: [MobileOverviewTile] {
        var tiles = [
            MobileOverviewTile(
                label: "Devices", value: "\(managed)", caption: "managed mobile devices"),
            Self.shareTile("OS current", osCurrent, of: "devices with a listed version"),
            Self.shareTile("Passcode compliant", passcode, of: "devices reporting"),
        ]
        if let attention = needsAttentionTile { tiles.append(attention) }
        return tiles
    }

    private var needsAttentionTile: MobileOverviewTile? {
        guard needsAttentionCount > 0 else { return nil }
        let parts = [(unmanaged, "unmanaged"), (jailbroken ?? 0, "jailbroken"),
                     (updateErrors ?? 0, "update errors")]
        return MobileOverviewTile(
            label: "Needs attention", value: "\(needsAttentionCount)",
            caption: parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", "),
            opensAudit: true)
    }

    private static func shareTile(
        _ label: String, _ share: Share?, of population: String
    ) -> MobileOverviewTile {
        // A pair with no devices behind it has no share (`Share.pct`), whatever `met` says.
        guard let share, let pct = share.pct else {
            return MobileOverviewTile(
                label: label, value: MobileOverviewTile.dash,
                caption: MobileOverviewTile.unreported)
        }
        return MobileOverviewTile(
            label: label, value: String(format: "%.1f%%", pct),
            caption: "\(share.met) of \(share.of) \(population)")
    }
}
