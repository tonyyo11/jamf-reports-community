import Foundation

/// A Devices table row with the sort keys the inventory record cannot give on its own: the
/// security gap count and the risk score depend on the workspace's policy and security agent.
/// Built once per filter pass so the comparator never calls the risk scorer.
struct DeviceSortRow: Identifiable, Sendable {
    let device: DeviceInventoryRecord
    /// Days since the Mac last made contact, as the Last Check-in column writes them. A Mac
    /// with no day count is the oldest, so ascending reads most recent first.
    let contactDays: Int
    let patchFailures: Int
    /// Zero unless the sort order asks for it (see `sorted`).
    let securityGaps: Int
    /// `RiskScoringService`'s score, which fixes the band (`DeviceRisk.Level.from(score:)`
    /// never goes down as the score goes up), so one key orders both. Zero unless asked for.
    let riskScore: Int

    var id: String { device.id }

    static func contactSortKey(_ days: Int?) -> Int {
        days.map { max($0, 0) } ?? Int.max
    }

    /// The rows for `devices` in `order`, ties broken by device name so a repeated click
    /// cannot reshuffle equal rows. The gap count and risk score are computed only when the
    /// primary sort column reads them.
    static func sorted(
        _ devices: [DeviceInventoryRecord],
        using order: [KeyPathComparator<DeviceSortRow>],
        securityGaps: (DeviceInventoryRecord) -> Int,
        riskScore: (DeviceInventoryRecord) -> Int
    ) -> [DeviceSortRow] {
        let primary = order.first?.keyPath
        let needsGaps = primary == \DeviceSortRow.securityGaps
        let needsRisk = primary == \DeviceSortRow.riskScore
        let rows = devices.map { device in
            DeviceSortRow(
                device: device,
                contactDays: contactSortKey(device.daysSinceContact),
                patchFailures: device.patchFailureCount,
                securityGaps: needsGaps ? securityGaps(device) : 0,
                riskScore: needsRisk ? riskScore(device) : 0)
        }
        return rows.sorted(using: order + [KeyPathComparator(\DeviceSortRow.device.displayName)])
    }
}
