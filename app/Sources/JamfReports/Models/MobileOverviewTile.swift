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

    static let unreported = L("Not reported")
    static let dash = "—"
}

extension MobileSummary {
    /// The jailbroken, unmanaged and update-error devices as one number. A part no device or
    /// scan reports contributes nothing, so the number never counts an unknown as a device.
    var needsAttentionCount: Int { (jailbroken ?? 0) + unmanaged + (updateErrors ?? 0) }

    /// The section's lines in display order: Devices, the OS current and passcode shares, then
    /// Needs attention, which is left out when it is 0. `formFactors` is the same summary's
    /// `mobileFormFactorCounts`.
    func overviewTiles(format: PercentFormat, formFactors: [String: Int]?) -> [MobileOverviewTile] {
        var tiles = [
            Self.devicesTile(formFactors, managed: managed),
            Self.shareTile(
                L("OS current"), osCurrent, of: "devices with a listed version", format: format),
            Self.shareTile(L("Passcode compliant"), passcode, of: "devices reporting",
                           format: format),
        ]
        if let attention = needsAttentionTile { tiles.append(attention) }
        return tiles
    }

    private var needsAttentionTile: MobileOverviewTile? {
        guard needsAttentionCount > 0 else { return nil }
        let parts = [(unmanaged, "unmanaged"), (jailbroken ?? 0, "jailbroken"),
                     (updateErrors ?? 0, L("update errors"))]
        return MobileOverviewTile(
            label: L("Needs attention"), value: "\(needsAttentionCount)",
            caption: parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", "),
            opensAudit: true)
    }

    /// Every mobile device by type ("12 iPads, 3 iPhones"), from the summary's form-factor map.
    /// A summary written before the map existed shows the managed count instead; a type with
    /// no devices is left out, never "0 iPads".
    private static func devicesTile(_ forms: [String: Int]?, managed: Int) -> MobileOverviewTile {
        let parts: [String] = [
            ("iPad", { $0 == 1 ? L("\($0) iPad") : L("\($0) iPads") }),
            ("iPhone", { $0 == 1 ? L("\($0) iPhone") : L("\($0) iPhones") }),
            ("Apple TV", { $0 == 1 ? L("\($0) Apple TV") : L("\($0) Apple TVs") }),
            ("Other", { $0 == 1 ? L("\($0) other device") : L("\($0) other devices") }),
        ].compactMap { (key: String, text: (Int) -> String) in
            (forms?[key]).flatMap { $0 > 0 ? text($0) : nil }
        }
        guard let forms, !parts.isEmpty else {
            return MobileOverviewTile(
                label: L("Devices"), value: "\(managed)", caption: L("managed mobile devices"))
        }
        return MobileOverviewTile(
            label: L("Devices"), value: "\(forms.values.reduce(0, +))",
            caption: parts.joined(separator: ", "))
    }

    private static func shareTile(
        _ label: String, _ share: Share?, of population: String, format: PercentFormat
    ) -> MobileOverviewTile {
        // A pair with no devices behind it has no share (`Share.pct`), whatever `met` says.
        guard let share, let pct = share.pct else {
            return MobileOverviewTile(
                label: label, value: MobileOverviewTile.dash,
                caption: MobileOverviewTile.unreported)
        }
        return MobileOverviewTile(
            label: label, value: format.text(pct),
            caption: L("\(share.met) of \(share.of) \(population)"))
    }
}
