import SwiftUI

/// What the Computers screen derives from its inputs, built once per input change instead of
/// once per redraw (a redraw used to filter and sort the whole inventory several times).
extension DevicesView {
    /// The inputs the figures and risk ratings depend on. `dataRevision` stands for the
    /// loaded snapshot and the security-agent lookup, which the view replaces as values.
    struct DataKey: Hashable {
        var dataRevision: Int
        var demoMode: Bool
        var staleDays: Int
        var agentConnectedValue: String?
        /// `thresholds.cert_warning_days`, which the Management filter's profile window follows.
        var warningDays: Int
        /// Hours since the epoch. Staleness, the contact gap and so the risk rating are measured
        /// against now (`StaleRule` counts elapsed 24-hour periods), so a list built hours ago
        /// is rebuilt on the next redraw instead of disagreeing with the live per-row stale mark.
        var hourBucket: Int
    }

    /// Every input of the filtered, sorted list.
    struct ListKey: Hashable {
        var data: DataKey
        var query: String
        var osFilter: String?
        var filter: DeviceFilter
        var sortOrder: [KeyPathComparator<DeviceSortRow>]
        /// The "Since last collect" list in force, and a number bumped with each result, so a
        /// new result rebuilds the rows without hashing the set.
        var change: ChangeFilter? = nil
        var changeRevision = 0
    }

    /// The table's rows with the lookups the panels read beside them.
    struct DerivedList {
        var rows: [DeviceSortRow]
        var devices: [DeviceInventoryRecord]
        var indexByID: [String: Int]

        static let empty = DerivedList(rows: [])

        init(rows: [DeviceSortRow]) {
            self.rows = rows
            devices = rows.map(\.device)
            indexByID = Dictionary(
                devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func device(withID id: String?) -> DeviceInventoryRecord? {
            guard let id, let index = indexByID[id] else { return nil }
            return devices[index]
        }
    }

    /// The snapshot-wide figures the summary tiles and the macOS card show. Each is the
    /// snapshot's own calculation, run once per data change.
    struct Figures {
        var staleCount: Int
        var patchIssueCount: Int
        var fileVaultPercent: Double?
        var binaryMissingCount: Int
        var securityGapCount: Int
        var fileVaultOffHardwareEncryptedCount: Int
        var osDistribution: [DeviceOSSummary]
        /// The Management filter's one calculation, so a redraw never recounts it per row.
        var management: ManagementHealth

        init(
            snapshot: DeviceInventorySnapshot, rule: StaleRule,
            warningDays: Int, now: Date
        ) {
            management = ManagementHealth(
                records: snapshot.devices, rule: rule, warningDays: warningDays, now: now)
            staleCount = snapshot.staleCount(rule)
            patchIssueCount = snapshot.patchIssueCount
            fileVaultPercent = snapshot.fileVaultPercent
            binaryMissingCount = snapshot.binaryMissingCount
            securityGapCount = snapshot.securityGapCount
            fileVaultOffHardwareEncryptedCount = snapshot.fileVaultOffHardwareEncryptedCount
            osDistribution = snapshot.osDistribution
        }
    }

    /// Holds the last list, figures, risk ratings and search text, and rebuilds each only when
    /// its key changes. `listBuilds` and `figureBuilds` are the seam tests count through.
    @MainActor
    final class ListCache {
        private(set) var listBuilds = 0
        private(set) var figureBuilds = 0
        private var dataKey: DataKey?
        private var listKey: ListKey?
        private var list = DerivedList.empty
        private var figures: Figures?
        private var risks: [String: DeviceRisk] = [:]
        private var searchText: [String: String] = [:]

        /// Drops what depended on the previous data when the data key moved.
        private func sync(_ key: DataKey) {
            guard dataKey != key else { return }
            dataKey = key
            figures = nil
            risks = [:]
            searchText = [:]
            listKey = nil
        }

        func figures(for key: DataKey, build: () -> Figures) -> Figures {
            sync(key)
            if let figures { return figures }
            figureBuilds += 1
            let built = build()
            figures = built
            return built
        }

        /// The one rating of a Mac (`RiskScoringService.risk`), kept until the data changes.
        func risk(
            of device: DeviceInventoryRecord, key: DataKey, compute: () -> DeviceRisk
        ) -> DeviceRisk {
            sync(key)
            if let cached = risks[device.id] { return cached }
            let rated = compute()
            risks[device.id] = rated
            return rated
        }

        func searchableText(of device: DeviceInventoryRecord, key: DataKey) -> String {
            sync(key)
            if let cached = searchText[device.id] { return cached }
            let text = device.searchableText
            searchText[device.id] = text
            return text
        }

        func list(for key: ListKey, build: () -> [DeviceSortRow]) -> DerivedList {
            sync(key.data)
            if listKey == key { return list }
            listBuilds += 1
            list = DerivedList(rows: build())
            listKey = key
            return list
        }
    }

    /// True when the workspace's policy reads the Mac's `control` value as off; a value Jamf
    /// did not collect reads neither on nor off and is not a match.
    nonisolated static func controlIsOff(
        _ device: DeviceInventoryRecord, _ control: SecurityControl, policy: SecurityControlPolicy
    ) -> Bool {
        let raw: String = switch control {
        case .fileVault: device.fileVault
        case .sip: device.sip
        case .firewall: device.firewall
        case .gatekeeper: device.gatekeeper
        }
        return policy.reading(raw, for: control) == false
    }

    /// What a change list keeps: only the matched Macs once its Macs are known; nothing while
    /// it compares, for a list of removed Macs, or when a snapshot is gone or unreadable.
    nonisolated static func changeKeep(
        _ result: ChangeFilterResult?, match: ChangeMatch?
    ) -> (DeviceInventoryRecord) -> Bool {
        guard case .macs = result?.outcome, let match else { return { _ in false } }
        return { match.contains($0) }
    }

    /// The rows for `devices` under the screen's filters and sort order. `risk` is the screen's
    /// own rating, so the Priority filter, the Risk sort and the Risk pill cannot disagree.
    nonisolated static func buildRows(
        devices: [DeviceInventoryRecord], query: String, osFilter: String?, filter: DeviceFilter,
        sortOrder: [KeyPathComparator<DeviceSortRow>], policy: SecurityControlPolicy,
        staleRule: StaleRule, contactGapDays: Int,
        needsManagementAttention: (DeviceInventoryRecord) -> Bool = { _ in false },
        changeKeep: ((DeviceInventoryRecord) -> Bool)? = nil,
        searchableText: (DeviceInventoryRecord) -> String,
        risk: (DeviceInventoryRecord) -> DeviceRisk
    ) -> [DeviceSortRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : query.lowercased()
        let matching = devices.filter { device in
            if let changeKeep, !changeKeep(device) { return false }
            if let needle, !searchableText(device).contains(needle) { return false }
            if let osFilter, device.osVersion != osFilter { return false }
            switch filter {
            case .all:
                return true
            case .stale:
                return device.isStale(staleRule)
            case .contactGap:
                return device.contactGap(rule: staleRule, gapDays: contactGapDays) != nil
            case .binaryMissing:
                return device.isBinaryMissing
            case .management:
                return needsManagementAttention(device)
            case .patch:
                return device.patchFailureCount > 0
            case .security:
                return device.securityGapCount(policy: policy) > 0
            case .priorityAction:
                // The Critical or High band of the same score the Risk pill shows.
                return risk(device).level >= .high
            case .fileVaultOff, .sipOff, .firewallOff, .gatekeeperOff:
                guard let control = filter.offControl else { return false }
                return controlIsOff(device, control, policy: policy)
            }
        }
        return DeviceSortRow.sorted(
            matching, using: sortOrder,
            securityGaps: { $0.securityGapCount(policy: policy) },
            riskScore: { risk($0).score })
    }
}
