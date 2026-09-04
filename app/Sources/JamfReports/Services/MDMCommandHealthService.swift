import Foundation

/// Reads the latest `mdm-command-health` snapshot and answers the three
/// operator questions: which Macs have a failed command, which have a command
/// pending past the threshold, and which commands fail most.
struct MDMCommandHealthService: Sendable {

    static let kind = "mdm-command-health"

    struct Snapshot: Sendable, Equatable {
        let records: [MDMCommandHealthRecord]
        let isDetected: Bool
        let readFailed: Bool
        let snapshotDate: Date?
        let sourceDates: [String: Date]

        static let empty = Snapshot(records: [], isDetected: false, readFailed: false,
                                    snapshotDate: nil, sourceDates: [:])
        static let unreadable = Snapshot(records: [], isDetected: false, readFailed: true,
                                         snapshotDate: nil, sourceDates: [:])

        var devicesWithFailures: [MDMCommandHealthRecord] {
            records.filter { $0.failedCount > 0 }
                .sorted { ($1.failedCount, $0.name) < ($0.failedCount, $1.name) }
        }

        /// Oldest pending first. `>=` so a command pending exactly 7 days counts.
        var devicesWithStalePending: [MDMCommandHealthRecord] {
            let threshold = DeviceScanBuilders.pendingAgeThresholdDays
            return records.filter { ($0.oldestPendingDays ?? -1) >= threshold }
                .sorted { ($0.oldestPendingDays ?? 0) > ($1.oldestPendingDays ?? 0) }
        }

        var topFailedCommands: [(name: String, count: Int)] {
            var order: [String] = []
            var counts: [String: Int] = [:]
            for r in records {
                for n in r.failedCommands {
                    if counts[n] == nil { order.append(n) }
                    counts[n, default: 0] += 1
                }
            }
            return order.map { (name: $0, count: counts[$0] ?? 0) }
                .enumerated()
                .sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
                .map(\.element)
        }

        func record(forDeviceId id: String) -> MDMCommandHealthRecord? {
            records.first { $0.deviceId == id }
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
        guard let rows = try? JSONDecoder().decode([MDMCommandHealthRecord].self, from: data) else {
            AppLogger.collect.warning(
                "MDMCommandHealthService: decode failed \(url.lastPathComponent, privacy: .public)"
            )
            return .unreadable
        }
        let date = CloudStorage.snapshotTimestamp(of: url)
        return Snapshot(records: rows, isDetected: true, readFailed: false, snapshotDate: date,
                        sourceDates: date.map { [kind: $0] } ?? [:])
    }
}
