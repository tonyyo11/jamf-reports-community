import Foundation

/// A device the fleet views can deep-link to.
struct DeviceRef: Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
}

/// Reads the latest `ddm-device-status` snapshot (written by the per-device
/// scan phase in `ReportEngine+DeviceScan`) and aggregates it for the DDM
/// screen, the Devices panel and the workbook. Pure over the snapshot.
struct DDMDeviceStatusService: Sendable {

    static let kind = "ddm-device-status"

    struct IdentifierSummary: Sendable, Equatable, Identifiable {
        var id: String { identifier }
        let identifier: String
        let active: Int
        let inactive: Int
        let invalid: Int
        /// Same identifier both active and inactive on ONE device.
        let mixed: Int
        let devices: [DeviceRef]
        var issues: Int { inactive + invalid + mixed }
    }

    struct Snapshot: Sendable, Equatable {
        let records: [DDMDeviceStatusRecord]
        let isDetected: Bool
        let readFailed: Bool
        let snapshotDate: Date?
        let sourceDates: [String: Date]

        static let empty = Snapshot(records: [], isDetected: false, readFailed: false,
                                    snapshotDate: nil, sourceDates: [:])
        static let unreadable = Snapshot(records: [], isDetected: false, readFailed: true,
                                         snapshotDate: nil, sourceDates: [:])

        var ddmReportedCount: Int { records.filter(\.ddmReported).count }

        func record(forDeviceId id: String) -> DDMDeviceStatusRecord? {
            records.first { $0.deviceId == id }
        }

        /// Worst first: mixed, then invalid, then inactive, then identifier.
        var byIdentifier: [IdentifierSummary] {
            var order: [String] = []
            var perId: [String: (
                active: Int, inactive: Int, invalid: Int, mixed: Int, devices: [DeviceRef]
            )] = [:]
            for r in records where r.ddmReported {
                let grouped = Dictionary(grouping: r.declarations, by: \.identifier)
                for (identifier, decls) in grouped {
                    if perId[identifier] == nil {
                        order.append(identifier)
                        perId[identifier] = (0, 0, 0, 0, [])
                    }
                    let anyInvalid = decls.contains { $0.valid == false }
                    let states = Set(decls.compactMap(\.active))
                    if anyInvalid { perId[identifier]!.invalid += 1 }
                    else if states.count == 2 { perId[identifier]!.mixed += 1 }
                    else if states == [false] { perId[identifier]!.inactive += 1 }
                    else { perId[identifier]!.active += 1 }
                    perId[identifier]!.devices.append(DeviceRef(id: r.deviceId, name: r.name))
                }
            }
            return order.map { id in
                let v = perId[id]!
                return IdentifierSummary(identifier: id, active: v.active, inactive: v.inactive,
                                         invalid: v.invalid, mixed: v.mixed, devices: v.devices)
            }.sorted(by: Self.worstFirst)
        }

        /// Field-by-field comparator (avoids a heterogeneous tuple comparison,
        /// which Swift 6.1's type-checker can time out on).
        private static func worstFirst(_ a: IdentifierSummary, _ b: IdentifierSummary) -> Bool {
            if a.mixed != b.mixed { return a.mixed > b.mixed }
            if a.invalid != b.invalid { return a.invalid > b.invalid }
            if a.inactive != b.inactive { return a.inactive > b.inactive }
            return a.identifier < b.identifier
        }

        var failingDeclarationCount: Int { byIdentifier.reduce(0) { $0 + $1.issues } }

        var pendingVersions: [(version: String, devices: [DeviceRef])] {
            bucket(records, key: { $0.softwareUpdate.pendingOSVersion })
                .map { (version: $0.key, devices: $0.devices) }
        }

        var failureReasons: [(reason: String, devices: [DeviceRef])] {
            bucket(records, key: { $0.softwareUpdate.failureReason })
                .map { (reason: $0.key, devices: $0.devices) }
        }

        /// Groups by a string key, largest bucket first, first-seen order on ties.
        private func bucket(
            _ rows: [DDMDeviceStatusRecord], key: (DDMDeviceStatusRecord) -> String?
        ) -> [(key: String, devices: [DeviceRef])] {
            var order: [String] = []
            var by: [String: [DeviceRef]] = [:]
            for r in rows {
                guard let k = key(r), !k.isEmpty else { continue }
                if by[k] == nil { order.append(k) }
                by[k, default: []].append(DeviceRef(id: r.deviceId, name: r.name))
            }
            return order.map { (key: $0, devices: by[$0] ?? []) }
                .enumerated()
                .sorted {
                    ($1.element.devices.count, $0.offset) < ($0.element.devices.count, $1.offset)
                }
                .map(\.element)
        }
    }

    static func load(profile: String) -> Snapshot {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return .empty }
        let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
        return load(url: FileManager.newestJSONFile(in: kindDir))
    }

    static func load(url: URL?) -> Snapshot {
        guard let url else { return .empty }
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .empty
        }
        guard let rows = try? JSONDecoder().decode([DDMDeviceStatusRecord].self, from: data) else {
            AppLogger.collect.warning(
                "DDMDeviceStatusService: decode failed \(url.lastPathComponent, privacy: .public)"
            )
            return .unreadable
        }
        let date = CloudStorage.snapshotTimestamp(of: url)
        return Snapshot(records: rows, isDetected: true, readFailed: false, snapshotDate: date,
                        sourceDates: date.map { [kind: $0] } ?? [:])
    }

    /// "DDM enabled N of M" from inventory alone — costs zero jamf-cli calls,
    /// so the screen can say DDM is on before the scan has ever run.
    static func fleetDDMCounts(profile: String) -> (enabled: Int, total: Int) {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return (0, 0) }
        return fleetDDMCounts(computersURL: FileManager.newestJSONFile(
            in: dir.appendingPathComponent("computers", isDirectory: true)))
    }

    static func fleetDDMCounts(computersURL: URL?) -> (enabled: Int, total: Int) {
        guard let computersURL, let data = try? Data(contentsOf: computersURL),
              let rows = try? JSONDecoder().decode([ReportEngine.DeviceScanTarget].self, from: data)
        else { return (0, 0) }
        return (rows.filter(\.ddmEnabled).count, rows.count)
    }
}
