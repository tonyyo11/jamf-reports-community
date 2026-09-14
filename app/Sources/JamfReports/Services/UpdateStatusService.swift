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
        var errorDevices: [UpdateErrorDevice]
        var failedPlans: [UpdateFailedPlan]
        let sourceFile: URL?
        let snapshotDate: Date?
        /// Per-kind newest-file dates for the freshness chip row. Keyed by the
        /// on-disk kind name — `update-status` always, plus
        /// `update-device-failures` when the snapshot is a `--scan-failures` run.
        var sourceDates: [String: Date] = [:]
        /// True only when the snapshot came from a `--scan-failures` run.
        /// Without the scan, `errorDevices`/`failedPlans` are empty because
        /// the data was never fetched — NOT because nothing is failing.
        /// KPIs must not render those empty arrays as "0 failures".
        var scanFailuresAvailable: Bool = false

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.total == rhs.total
                && lhs.planTotal == rhs.planTotal
                && lhs.statusBreakdown == rhs.statusBreakdown
                && lhs.planStateBreakdown == rhs.planStateBreakdown
                && lhs.errorDevices.count == rhs.errorDevices.count
                && lhs.failedPlans.count == rhs.failedPlans.count
                && lhs.sourceFile == rhs.sourceFile
                && lhs.snapshotDate == rhs.snapshotDate
                && lhs.sourceDates == rhs.sourceDates
                && lhs.scanFailuresAvailable == rhs.scanFailuresAvailable
        }

        /// Failed/exception plan count derived from `plan_state_summary`,
        /// which every update-status snapshot carries. This is the number the
        /// plan-state donut shows — the "Failing Plans" KPI uses it so the two
        /// can never disagree. PlanCanceled is a user action, not a failure.
        var plansFailedFromStates: Int {
            planStateBreakdown
                .filter {
                    let upper = $0.label.uppercased()
                    return upper.contains("PLANFAILED") || upper.contains("PLANEXCEPTION")
                }
                .reduce(0) { $0 + $1.count }
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
        return load(
            statusURL: FileManager.newestJSONFile(
                in: dir.appendingPathComponent("update-status", isDirectory: true)),
            failuresURL: FileManager.newestJSONFile(
                in: dir.appendingPathComponent("update-device-failures", isDirectory: true))
        )
    }

    /// The summary kind lands twice a day; the `--scan-failures` kind lands
    /// weekly under its own directory, which this loader never read before
    /// 2.8.0 — the failed-plan tables stayed empty and the chip read "never"
    /// on every jamf-cli-only workspace. Totals come from the summary when it
    /// exists; the failure arrays only ever come from the scan.
    static func load(statusURL: URL?, failuresURL: URL?) -> Snapshot {
        let scan = failuresURL.flatMap { load(from: $0) }
        guard var merged = statusURL.flatMap({ load(from: $0) }) ?? scan else { return .empty }
        if let scan, scan.scanFailuresAvailable {
            merged.errorDevices = scan.errorDevices
            merged.failedPlans = scan.failedPlans
            merged.scanFailuresAvailable = true
            merged.sourceDates["update-device-failures"] =
                scan.sourceDates["update-device-failures"]
        }
        return merged
    }

    /// Test seam: load directly from an arbitrary file URL.
    static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.collect.warning(
                "UpdateStatusService: could not read update-status file \(url.lastPathComponent, privacy: .public)"
            )
            return nil
        }

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

        AppLogger.collect.warning(
            "UpdateStatusService: failed to decode update-status file \(url.lastPathComponent, privacy: .public)"
        )
        return nil
    }

    // MARK: - Internals

    private static func decode(failures: UpdateFailuresReport, url: URL) -> Snapshot {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        var sourceDates: [String: Date] = [:]
        if let mtime {
            // A --scan-failures file carries both kinds' data; date both.
            sourceDates["update-status"] = mtime
            sourceDates["update-device-failures"] = mtime
        }

        return Snapshot(
            total: failures.total,
            planTotal: failures.planTotal ?? 0,
            statusBreakdown: makeStatusSlices(from: failures.statusSummary),
            planStateBreakdown: makePlanStateSlices(from: failures.planStateSummary ?? []),
            errorDevices: uniqueByID(failures.errorDevices),
            failedPlans: uniqueByID(failures.failedPlans),
            sourceFile: url,
            snapshotDate: mtime,
            sourceDates: sourceDates,
            scanFailuresAvailable: true
        )
    }

    /// A SwiftUI `Table` needs unique row ids; two byte-identical rows say nothing twice.
    private static func uniqueByID<Row: Identifiable>(_ rows: [Row]) -> [Row] {
        var seen = Set<Row.ID>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private static func decode(status: UpdateStatusReport, url: URL) -> Snapshot {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        var sourceDates: [String: Date] = [:]
        if let mtime { sourceDates["update-status"] = mtime }

        return Snapshot(
            total: status.total,
            planTotal: status.planTotal ?? 0,
            statusBreakdown: makeStatusSlices(from: status.statusSummary),
            planStateBreakdown: makePlanStateSlices(from: status.planStateSummary ?? []),
            errorDevices: [],
            failedPlans: [],
            sourceFile: url,
            snapshotDate: mtime,
            sourceDates: sourceDates
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