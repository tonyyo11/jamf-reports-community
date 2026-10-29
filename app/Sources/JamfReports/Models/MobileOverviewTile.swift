import Foundation

/// One figure of the Overview's Mobile Devices section (mobile spec 3.1), worded from a
/// `MobileSummary`. A figure no device reports shows a dash and says so, never 0 or 0%.
struct MobileOverviewTile: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    /// What the figure counts, so a share never reads as a share of the whole fleet.
    let caption: String

    var id: String { label }

    static let unreported = "Not reported"
    static let dash = "—"
}

extension MobileSummary {
    /// The section's tiles in display order: managed, supervised, passcode and OS current
    /// shares, then stale and jailbroken counts.
    var overviewTiles: [MobileOverviewTile] {
        [
            MobileOverviewTile(
                label: "Managed", value: "\(managed)", caption: "\(unmanaged) unmanaged"),
            Self.shareTile("Supervised", supervised, of: "managed devices"),
            Self.shareTile("Passcode compliant", passcode, of: "devices reporting"),
            Self.shareTile("OS current", osCurrent, of: "devices with a listed version"),
            Self.countTile("Stale", stale, caption: "no recent inventory update"),
            Self.countTile("Jailbroken", jailbroken, caption: "jailbreak detected"),
        ]
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

    private static func countTile(
        _ label: String, _ count: Int?, caption: String
    ) -> MobileOverviewTile {
        guard let count else {
            return MobileOverviewTile(
                label: label, value: MobileOverviewTile.dash,
                caption: MobileOverviewTile.unreported)
        }
        return MobileOverviewTile(label: label, value: "\(count)", caption: caption)
    }
}
