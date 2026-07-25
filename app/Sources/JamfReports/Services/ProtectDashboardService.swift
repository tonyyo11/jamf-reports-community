import Foundation

/// Reads Jamf Protect snapshots from the workspace's jamf-cli data directory
/// and aggregates them for the `ProtectView`. Handles cases where tenants
/// don't run Protect by gracefully returning empty state when no data exists.
struct ProtectDashboardService: Sendable {

    /// Everything the ProtectView needs from all protect snapshots combined.
    /// `isDetected` is true when at least one of the four protect data types
    /// was successfully loaded from disk.
    struct Snapshot: Sendable, Equatable {
        let isDetected: Bool
        let overviewItems: [ProtectOverviewItem]
        let alerts: [ProtectAlertRow]
        let computers: [ProtectComputerRow]
        let insights: [ProtectInsightRow]
        let plans: [ProtectPlanRow]

        // Derived aggregates
        let totalComputers: Int
        let webProtectionActiveCount: Int
        let fullDiskAccessCount: Int
        let connectedCount: Int
        let criticalAlerts: Int
        let highAlerts: Int
        let mediumAlerts: Int
        let lowAlerts: Int
        let failingInsights: Int

        let sourceFile: URL?
        let snapshotDate: Date?
        /// Per-kind newest-file dates for the freshness chip row. Keys are the
        /// on-disk kind names (`protect-overview`, `protect-alerts`,
        /// `protect-computers`, `protect-insights`, `protect-plans`); a kind
        /// absent from disk is absent from the map.
        var sourceDates: [String: Date] = [:]

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        /// Empty state for when no protect data exists.
        static let empty = Snapshot(
            isDetected: false,
            overviewItems: [],
            alerts: [],
            computers: [],
            insights: [],
            plans: [],
            totalComputers: 0,
            webProtectionActiveCount: 0,
            fullDiskAccessCount: 0,
            connectedCount: 0,
            criticalAlerts: 0,
            highAlerts: 0,
            mediumAlerts: 0,
            lowAlerts: 0,
            failingInsights: 0,
            sourceFile: nil,
            snapshotDate: nil
        )

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            // Loose equality: compare aggregates and metadata, not full arrays
            lhs.isDetected == rhs.isDetected &&
            lhs.totalComputers == rhs.totalComputers &&
            lhs.webProtectionActiveCount == rhs.webProtectionActiveCount &&
            lhs.fullDiskAccessCount == rhs.fullDiskAccessCount &&
            lhs.connectedCount == rhs.connectedCount &&
            lhs.criticalAlerts == rhs.criticalAlerts &&
            lhs.highAlerts == rhs.highAlerts &&
            lhs.mediumAlerts == rhs.mediumAlerts &&
            lhs.lowAlerts == rhs.lowAlerts &&
            lhs.failingInsights == rhs.failingInsights &&
            lhs.plans.count == rhs.plans.count &&
            lhs.sourceFile == rhs.sourceFile &&
            lhs.snapshotDate == rhs.snapshotDate &&
            lhs.sourceDates == rhs.sourceDates
        }
    }

    /// Main load entry point — loads all protect data for the given profile.
    static func load(profile: String) -> Snapshot {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else {
            return .empty
        }

        let overviewURL = FileManager.newestJSONFile(in: dir.appendingPathComponent("protect-overview", isDirectory: true))
        let alertsURL = FileManager.newestJSONFile(in: dir.appendingPathComponent("protect-alerts", isDirectory: true))
        let computersURL = FileManager.newestJSONFile(in: dir.appendingPathComponent("protect-computers", isDirectory: true))
        let insightsURL = FileManager.newestJSONFile(in: dir.appendingPathComponent("protect-insights", isDirectory: true))
        let plansURL = FileManager.newestJSONFile(in: dir.appendingPathComponent("protect-plans", isDirectory: true))

        return load(overviewURL: overviewURL, alertsURL: alertsURL, computersURL: computersURL,
                    insightsURL: insightsURL, plansURL: plansURL)
    }

    /// Test seam: load directly from specific URLs. Returns `.empty` when all URLs are nil.
    /// `plansURL` defaults to nil so pre-plans callers/tests keep compiling.
    static func load(overviewURL: URL?, alertsURL: URL?, computersURL: URL?,
                     insightsURL: URL?, plansURL: URL? = nil) -> Snapshot {
        guard overviewURL != nil || alertsURL != nil || computersURL != nil
            || insightsURL != nil || plansURL != nil else {
            return .empty
        }

        // Track whether each file decoded successfully (even to an empty
        // array). A readable empty file is "detected" so the view renders
        // its sections instead of the empty state.
        var readSomething = false
        let overview = loadOverview(from: overviewURL, success: &readSomething)
        let alerts = loadAlerts(from: alertsURL, success: &readSomething)
        let computers = loadComputers(from: computersURL, success: &readSomething)
        let insights = loadInsights(from: insightsURL, success: &readSomething)
        let plans = loadPlans(from: plansURL, success: &readSomething)

        let hasData = readSomething

        // Find most recent source file across all loaded data
        let allURLs = [overviewURL, alertsURL, computersURL, insightsURL, plansURL].compactMap { $0 }
        let sourceFile = allURLs.max { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lDate < rDate
        }

        let snapshotDate = sourceFile.flatMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }

        // Compute aggregates
        let totalComputers = computers.count
        let webProtectionActiveCount = computers.filter { $0.webProtectionActive == true }.count
        let fullDiskAccessCount = computers.filter { $0.fullDiskAccess == true }.count
        let connectedCount = computers.filter { isConnected($0.connectionStatus) }.count

        let (critical, high, medium, low) = alertSeverityCounts(alerts)
        let failingInsights = insights.filter { ($0.totalFail ?? 0) > 0 }.count

        // Per-kind freshness for the chip row, based on file presence — honest
        // even when a kind's own decode failed (see PatchStatusService).
        var sourceDates: [String: Date] = [:]
        for (kind, url) in [
            ("protect-overview", overviewURL), ("protect-alerts", alertsURL),
            ("protect-computers", computersURL), ("protect-insights", insightsURL),
            ("protect-plans", plansURL),
        ] {
            guard let url, FileManager.default.fileExists(atPath: url.path),
                  let d = (try? url.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ))?.contentModificationDate
            else { continue }
            sourceDates[kind] = d
        }

        return Snapshot(
            isDetected: hasData,
            overviewItems: overview,
            alerts: alerts,
            computers: computers,
            insights: insights,
            plans: plans,
            totalComputers: totalComputers,
            webProtectionActiveCount: webProtectionActiveCount,
            fullDiskAccessCount: fullDiskAccessCount,
            connectedCount: connectedCount,
            criticalAlerts: critical,
            highAlerts: high,
            mediumAlerts: medium,
            lowAlerts: low,
            failingInsights: failingInsights,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate,
            sourceDates: sourceDates
        )
    }

    // MARK: - Internals

    private static func loadOverview(
        from url: URL?, success: inout Bool
    ) -> [ProtectOverviewItem] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProtectOverviewItem].self, from: data)
        else { return [] }
        success = true
        return decoded
    }

    private static func loadAlerts(
        from url: URL?, success: inout Bool
    ) -> [ProtectAlertRow] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProtectAlertRow].self, from: data)
        else { return [] }
        success = true
        return decoded
    }

    private static func loadComputers(
        from url: URL?, success: inout Bool
    ) -> [ProtectComputerRow] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProtectComputerRow].self, from: data)
        else { return [] }
        success = true
        return decoded
    }

    private static func loadInsights(
        from url: URL?, success: inout Bool
    ) -> [ProtectInsightRow] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProtectInsightRow].self, from: data)
        else { return [] }
        success = true
        return decoded
    }

    /// Plans arrive either as a bare array or a `{ "nodes": [...] }` GraphQL
    /// envelope (same two shapes the workbook's `writeProtectPlans` handles).
    private static func loadPlans(
        from url: URL?, success: inout Bool
    ) -> [ProtectPlanRow] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([ProtectPlanRow].self, from: data) {
            success = true
            return rows
        }
        struct Envelope: Decodable { let nodes: [ProtectPlanRow] }
        if let env = try? decoder.decode(Envelope.self, from: data) {
            success = true
            return env.nodes
        }
        return []
    }

    /// Connection predicate: matches the canonical positive states only.
    /// Substring `contains("connected")` would also match "Disconnected", so
    /// we anchor on exact tokens after lowercasing and trimming whitespace.
    /// Document any new positive state (e.g. "online_paused") by adding it to
    /// `Self.connectedStates` rather than loosening the predicate.
    private static let connectedStates: Set<String> = ["connected", "online"]

    private static func isConnected(_ status: String?) -> Bool {
        guard let status else { return false }
        let normalized = status.lowercased().trimmingCharacters(in: .whitespaces)
        return Self.connectedStates.contains(normalized)
    }

    /// Group alerts by `eventType` for the deep-dive kill-chain donut.
    /// The Protect SDK has no first-class `killChainStage` field — `eventType`
    /// is the closest stable bucketing key without extending the alert model
    /// to parse the unverified `analytics[].categories` shape.
    /// Returns counts sorted descending by count, then alphabetically by key.
    static func killChainBuckets(_ alerts: [ProtectAlertRow]) -> [(stage: String, count: Int)] {
        var counts: [String: Int] = [:]
        for alert in alerts {
            let stage = alert.eventType?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = stage.isEmpty ? "Unknown" : stage
            counts[key, default: 0] += 1
        }
        return counts
            .map { (stage: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.stage < rhs.stage
            }
    }

    /// Distribution of endpoint agent versions across the fleet.
    /// Computers without a `version` field bucket under "Unknown" so the chart
    /// still surfaces them — an unreported version is operationally meaningful.
    /// Returns versions sorted descending by count, then by version string.
    static func agentVersionDistribution(
        _ computers: [ProtectComputerRow]
    ) -> [(version: String, count: Int)] {
        var counts: [String: Int] = [:]
        for computer in computers {
            let version = computer.version?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = version.isEmpty ? "Unknown" : version
            counts[key, default: 0] += 1
        }
        return counts
            .map { (version: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.version > rhs.version
            }
    }

    /// Chronological alert timeline for a specific device, identified by
    /// hostname OR serial (case-insensitive). Returned newest-first so the
    /// detail panel renders the most recent event at the top.
    static func alertTimeline(
        for deviceIdentifier: String,
        in alerts: [ProtectAlertRow]
    ) -> [ProtectAlertRow] {
        let needle = deviceIdentifier.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let matching = alerts.filter { alert in
            let host = alert.hostName?.lowercased() ?? ""
            let serial = alert.serial?.lowercased() ?? ""
            return host == needle || serial == needle
        }
        return matching.sorted { ($0.created ?? "") > ($1.created ?? "") }
    }

    /// Count alerts by severity level (case-insensitive).
    private static func alertSeverityCounts(_ alerts: [ProtectAlertRow]) -> (critical: Int, high: Int, medium: Int, low: Int) {
        var critical = 0, high = 0, medium = 0, low = 0

        for alert in alerts {
            guard let severity = alert.severity?.lowercased() else { continue }
            switch severity {
            case let s where s.contains("critical"):
                critical += 1
            case let s where s.contains("high"):
                high += 1
            case let s where s.contains("medium") || s.contains("med"):
                medium += 1
            case let s where s.contains("low"):
                low += 1
            default:
                break
            }
        }

        return (critical, high, medium, low)
    }
}