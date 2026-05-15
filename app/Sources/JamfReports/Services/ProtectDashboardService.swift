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

        /// Empty state for when no protect data exists.
        static let empty = Snapshot(
            isDetected: false,
            overviewItems: [],
            alerts: [],
            computers: [],
            insights: [],
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
            lhs.sourceFile == rhs.sourceFile &&
            lhs.snapshotDate == rhs.snapshotDate
        }
    }

    /// Main load entry point — loads all protect data for the given profile.
    static func load(profile: String) -> Snapshot {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else {
            return .empty
        }

        let overviewURL = findNewestJSON(in: dir.appendingPathComponent("protect-overview", isDirectory: true))
        let alertsURL = findNewestJSON(in: dir.appendingPathComponent("protect-alerts", isDirectory: true))
        let computersURL = findNewestJSON(in: dir.appendingPathComponent("protect-computers", isDirectory: true))
        let insightsURL = findNewestJSON(in: dir.appendingPathComponent("protect-insights", isDirectory: true))

        return load(overviewURL: overviewURL, alertsURL: alertsURL, computersURL: computersURL, insightsURL: insightsURL)
    }

    /// Test seam: load directly from specific URLs. Returns `.empty` when all URLs are nil.
    static func load(overviewURL: URL?, alertsURL: URL?, computersURL: URL?, insightsURL: URL?) -> Snapshot {
        guard overviewURL != nil || alertsURL != nil || computersURL != nil || insightsURL != nil else {
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

        let hasData = readSomething

        // Find most recent source file across all loaded data
        let allURLs = [overviewURL, alertsURL, computersURL, insightsURL].compactMap { $0 }
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

        return Snapshot(
            isDetected: hasData,
            overviewItems: overview,
            alerts: alerts,
            computers: computers,
            insights: insights,
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
            snapshotDate: snapshotDate
        )
    }

    // MARK: - Internals

    private static func findNewestJSON(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        return jsonFiles.max { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lDate < rDate
        }
    }

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