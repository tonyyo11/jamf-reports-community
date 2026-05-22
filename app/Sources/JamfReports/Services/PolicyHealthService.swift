import Foundation

/// Reads the latest `pro report policy-status` and `pro classic-macos-profiles list`
/// snapshots from the workspace's jamf-cli data directory and prepares them for
/// the `PolicyProfileView`. Decoupled from the SwiftUI view so it stays unit-testable.
///
/// The view consumes a single `Snapshot` value containing both policy status
/// (for KPIs and findings table) and profile deployment status (for profile health).
struct PolicyHealthService: Sendable {

    /// Everything the PolicyProfileView needs from both policy and profile snapshots.
    /// `nil` sourceFile and snapshotDate mean "data not present" — the view should
    /// render an empty state rather than error.
    struct Snapshot: Sendable, Equatable {
        let summary: PolicyStatusSummary?
        let findings: [PolicyFinding]
        let profiles: [ProfileStatusRow]
        let sourceFile: URL?
        let snapshotDate: Date?

        // MARK: - Computed aggregates

        var findingsBySeverity: [String: Int] {
            let counts = Dictionary(findings.map {
                (key: $0.severity.lowercased(), value: 1)
            }, uniquingKeysWith: +)
            return counts
        }

        var totalProfiles: Int {
            profiles.count
        }

        var pendingProfiles: Int {
            profiles.filter { profile in
                guard let status = profile.managementStatus else { return false }
                return status.lowercased().contains("pending")
            }.count
        }

        var installedProfiles: Int {
            profiles.filter { profile in
                guard let status = profile.managementStatus else { return false }
                return status.lowercased().contains("installed") ||
                       status.lowercased().contains("success")
            }.count
        }

        var failedProfiles: Int {
            profiles.filter { profile in
                guard let status = profile.managementStatus else { return false }
                let lower = status.lowercased()
                return lower.contains("failed") || lower.contains("removed") ||
                       lower.contains("error")
            }.count
        }

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        static let empty = Snapshot(
            summary: nil,
            findings: [],
            profiles: [],
            sourceFile: nil,
            snapshotDate: nil
        )

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.summary?.totalPolicies == rhs.summary?.totalPolicies &&
            lhs.summary?.enabled == rhs.summary?.enabled &&
            lhs.summary?.disabled == rhs.summary?.disabled &&
            lhs.summary?.configFindings == rhs.summary?.configFindings &&
            lhs.findings.count == rhs.findings.count &&
            lhs.profiles.count == rhs.profiles.count &&
            lhs.sourceFile == rhs.sourceFile &&
            lhs.snapshotDate == rhs.snapshotDate
        }
    }

    /// Returns the newest snapshot for `profile`. Returns `.empty` when no
    /// snapshot exists — that's a normal state pre-first-collect and the view
    /// should render a "Run Collect" prompt rather than an error.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }

        let policyDir = dir.appendingPathComponent("policy-status", isDirectory: true)
        let profileDir = dir.appendingPathComponent("profile-status", isDirectory: true)

        let policyURL = newestJSON(in: policyDir)
        let profileURL = newestJSON(in: profileDir)

        return load(policyURL: policyURL, profileURL: profileURL) ?? .empty
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(policyURL: URL?, profileURL: URL?) -> Snapshot? {
        var summary: PolicyStatusSummary?
        var findings: [PolicyFinding] = []
        var profiles: [ProfileStatusRow] = []
        var sourceFile: URL?
        var snapshotDate: Date?

        // Load policy data
        if let policyURL,
           FileManager.default.fileExists(atPath: policyURL.path),
           let policyData = try? Data(contentsOf: policyURL),
           let policyReports = try? JSONDecoder().decode([PolicyStatusReport].self, from: policyData),
           let firstReport = policyReports.first {
            summary = firstReport.summary
            findings = firstReport.configFindings
            sourceFile = policyURL
            snapshotDate = (try? policyURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }

        // Load profile data
        if let profileURL,
           FileManager.default.fileExists(atPath: profileURL.path),
           let profileData = try? Data(contentsOf: profileURL),
           let decodedProfiles = try? JSONDecoder().decode([ProfileStatusRow].self, from: profileData) {
            profiles = decodedProfiles

            // Use profile timestamp if we don't have a policy timestamp
            if sourceFile == nil {
                sourceFile = profileURL
                snapshotDate = (try? profileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
        }

        // Return nil if we have no data at all
        guard summary != nil || !profiles.isEmpty else { return nil }

        return Snapshot(
            summary: summary,
            findings: findings,
            profiles: profiles,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate
        )
    }

    // MARK: - Internals

    private static func newestJSON(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let json = files.filter { $0.pathExtension == "json" }
        return json.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return l < r
        }
    }
}