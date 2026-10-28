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
    }

    /// Every input of the filtered, sorted list.
    struct ListKey: Hashable {
        var data: DataKey
        var query: String
        var osFilter: String?
        var filter: DeviceFilter
        var sortOrder: [KeyPathComparator<DeviceSortRow>]
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

        init(snapshot: DeviceInventorySnapshot, rule: StaleRule) {
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

    /// The rows for `devices` under the screen's filters and sort order. `risk` is the screen's
    /// own rating, so the Priority filter, the Risk sort and the Risk pill cannot disagree.
    nonisolated static func buildRows(
        devices: [DeviceInventoryRecord], query: String, osFilter: String?, filter: DeviceFilter,
        sortOrder: [KeyPathComparator<DeviceSortRow>], policy: SecurityControlPolicy,
        staleRule: StaleRule, contactGapDays: Int,
        searchableText: (DeviceInventoryRecord) -> String,
        risk: (DeviceInventoryRecord) -> DeviceRisk
    ) -> [DeviceSortRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : query.lowercased()
        let matching = devices.filter { device in
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
            case .patch:
                return device.patchFailureCount > 0
            case .security:
                return device.securityGapCount(policy: policy) > 0
            case .priorityAction:
                // The Critical or High band of the same score the Risk pill shows.
                return risk(device).level >= .high
            }
        }
        return DeviceSortRow.sorted(
            matching, using: sortOrder,
            securityGaps: { $0.securityGapCount(policy: policy) },
            riskScore: { risk($0).score })
    }
}
