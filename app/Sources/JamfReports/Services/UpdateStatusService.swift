import Foundation

/// Reads the latest `pro report update-status` snapshot from the workspace's
/// jamf-cli data directory and prepares it for the `UpdatesView`. Decoupled
/// from the SwiftUI view so it stays unit-testable.
///
/// Handles both summary-only and with-failures shapes. Detects which shape
/// based on presence of `errorDevices` or `failedPlans` arrays.
struct UpdateStatusService: Sendable {

    struct Snapshot: Sendable, Equatable {
        let total: Int
        let planTotal: Int
        let statusBreakdown: [Slice]
        let planStateBreakdown: [Slice]
        let errorDevices: [UpdateErrorDevice]
        let failedPlans: [UpdateFailedPlan]
        let sourceFile: URL?
        let snapshotDate: Date?

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.total == rhs.total
                && lhs.planTotal == rhs.planTotal
                && lhs.statusBreakdown == rhs.statusBreakdown
                && lhs.planStateBreakdown == rhs.planStateBreakdown
                && lhs.errorDevices.count == rhs.errorDevices.count
                && lhs.failedPlans.count == rhs.failedPlans.count
                && lhs.sourceFile == rhs.sourceFile
                && lhs.snapshotDate == rhs.snapshotDate
        }

        struct Slice: Sendable, Equatable, Identifiable {
            let label: String
            let count: Int
            let colorHex: UInt32
            var id: String { label }
        }

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        /// Empty snapshot used when no data file exists for the active profile.
        static let empty = Snapshot(
            total: 0,
            planTotal: 0,
            statusBreakdown: [],
            planStateBreakdown: [],
            errorDevices: [],
            failedPlans: [],
            sourceFile: nil,
            snapshotDate: nil
        )
    }

    /// Returns the newest snapshot for `profile`. Returns `.empty` when no
    /// snapshot exists — that's a normal state pre-first-collect.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let updateDir = dir.appendingPathComponent("update-status", isDirectory: true)
        guard let newest = FileManager.newestJSONFile(in: updateDir) else {
            return .empty
        }
        return load(from: newest) ?? .empty
    }

    /// Test seam: load directly from an arbitrary file URL.
    static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Try UpdateFailuresReport first (has more fields)
        if let failuresReport = try? JSONDecoder()
            .decode([UpdateFailuresReport].self, from: data).first {
            return decode(failures: failuresReport, url: url)
        }

        // Fall back to UpdateStatusReport
        if let statusReport = try? JSONDecoder()
            .decode([UpdateStatusReport].self, from: data).first {
            return decode(status: statusReport, url: url)
        }

        return nil
    }

    // MARK: - Internals

    private static func decode(failures: UpdateFailuresReport, url: URL) -> Snapshot {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        return Snapshot(
            total: failures.total,
            planTotal: failures.planTotal ?? 0,
            statusBreakdown: makeStatusSlices(from: failures.statusSummary),
            planStateBreakdown: makePlanStateSlices(from: failures.planStateSummary ?? []),
            errorDevices: failures.errorDevices,
            failedPlans: failures.failedPlans,
            sourceFile: url,
            snapshotDate: mtime
        )
    }

    private static func decode(status: UpdateStatusReport, url: URL) -> Snapshot {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        return Snapshot(
            total: status.total,
            planTotal: status.planTotal ?? 0,
            statusBreakdown: makeStatusSlices(from: status.statusSummary),
            planStateBreakdown: makePlanStateSlices(from: status.planStateSummary ?? []),
            errorDevices: [],
            failedPlans: [],
            sourceFile: url,
            snapshotDate: mtime
        )
    }

    private static func makeStatusSlices(from summary: [UpdateStatusCount]) -> [Snapshot.Slice] {
        summary.map { item in
            Snapshot.Slice(
                label: item.status,
                count: item.count,
                colorHex: statusColor(for: item.status)
            )
        }
    }

    private static func makePlanStateSlices(from summary: [UpdateStateCount]) -> [Snapshot.Slice] {
        summary.map { item in
            Snapshot.Slice(
                label: item.state,
                count: item.count,
                colorHex: planStateColor(for: item.state)
            )
        }
    }

    private static func statusColor(for status: String) -> UInt32 {
        let upper = status.uppercased()
        switch upper {
        case let s where s.contains("COMPLETED") || s.contains("SUCCESS"):
            return 0x30D158  // green
        case let s where s.contains("ERROR") || s.contains("FAILED"):
            return 0xFF453A  // red
        case let s where s.contains("PENDING") || s.contains("IDLE") || s.contains("INSTALLING"):
            return 0x007AFF  // blue
        default:
            return 0x8E8E93  // gray
        }
    }

    private static func planStateColor(for state: String) -> UInt32 {
        let upper = state.uppercased()
        switch upper {
        case "PLANCOMPLETED":
            return 0x30D158  // green
        case let s where s.contains("PLANFAILED") || s.contains("PLANEXCEPTION") || s.contains("PLANCANCELED"):
            return 0xFF453A  // red
        default:
            return 0x007AFF  // blue
        }
    }
}