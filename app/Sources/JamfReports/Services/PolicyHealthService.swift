import Foundation

/// Reads the latest `pro report policy-status` and `pro report profile-status`
/// snapshots from the workspace's jamf-cli data directory and prepares them for
/// the `PolicyProfileView`. Decoupled from the SwiftUI view so it stays unit-testable.
///
/// The view consumes a single `Snapshot` value containing both policy status
/// (for KPIs and findings table) and profile assignment failures.
struct PolicyHealthService: Sendable {

    /// One per-profile failure row, with identity assigned at load time —
    /// stable and unique by construction (#185: a per-access computed id
    /// aborts SwiftUI Table on macOS 26).
    struct ProfileFailure: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let deviceType: String
        let errors: Int
        let devices: Int
        let lastError: String
        let topError: String
    }

    /// Everything the PolicyProfileView needs from both policy and profile snapshots.
    /// `nil` sourceFile and snapshotDate mean "data not present" — the view should
    /// render an empty state rather than error.
    struct Snapshot: Sendable, Equatable {
        let summary: PolicyStatusSummary?
        let findings: [PolicyFinding]
        let profiles: [ProfileFailure]
        let profileSummary: ProfileFailureSummary?
        let sourceFile: URL?
        let snapshotDate: Date?

        // MARK: - Computed aggregates

        var findingsBySeverity: [String: Int] {
            let counts = Dictionary(findings.map {
                (key: $0.severity.lowercased(), value: 1)
            }, uniquingKeysWith: +)
            return counts
        }

        /// True when a profile-status snapshot decoded — distinguishes "no
        /// data collected" (empty state) from "zero failures" (healthy state).
        var hasProfileData: Bool {
            profileSummary != nil || !profiles.isEmpty
        }

        var profileTotalErrors: Int {
            profileSummary?.totalErrors ?? profiles.reduce(0) { $0 + $1.errors }
        }

        var profilesWithFailures: Int {
            profileSummary?.uniqueProfiles ?? profiles.count
        }

        var profileDevicesAffected: Int? {
            profileSummary?.uniqueDevices
        }

        var profileLookbackDays: Int? {
            profileSummary?.days
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
            profileSummary: nil,
            sourceFile: nil,
            snapshotDate: nil
        )

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.summary?.totalPolicies == rhs.summary?.totalPolicies &&
            lhs.summary?.enabled == rhs.summary?.enabled &&
            lhs.summary?.disabled == rhs.summary?.disabled &&
            lhs.summary?.configFindings == rhs.summary?.configFindings &&
            lhs.findings.count == rhs.findings.count &&
            lhs.profiles == rhs.profiles &&
            lhs.profileSummary == rhs.profileSummary &&
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

        let policyURL = FileManager.newestJSONFile(in: policyDir)
        let profileURL = FileManager.newestJSONFile(in: profileDir)

        return load(policyURL: policyURL, profileURL: profileURL) ?? .empty
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(policyURL: URL?, profileURL: URL?) -> Snapshot? {
        var summary: PolicyStatusSummary?
        var findings: [PolicyFinding] = []
        var profiles: [ProfileFailure] = []
        var profileSummary: ProfileFailureSummary?
        var sourceFile: URL?
        var snapshotDate: Date?

        // Load policy data
        if let policyURL, FileManager.default.fileExists(atPath: policyURL.path) {
            if let policyData = try? Data(contentsOf: policyURL) {
                if let policyReports = try? JSONDecoder().decode(
                    [PolicyStatusReport].self, from: policyData
                ), let firstReport = policyReports.first {
                    summary = firstReport.summary
                    findings = firstReport.configFindings
                    sourceFile = policyURL
                    snapshotDate = (try? policyURL.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                } else {
                    AppLogger.engine.warning(
                        "PolicyHealthService: failed to decode policy-status file \(policyURL.lastPathComponent, privacy: .public)"
                    )
                }
            } else {
                AppLogger.engine.warning(
                    "PolicyHealthService: could not read policy-status file \(policyURL.lastPathComponent, privacy: .public)"
                )
            }
        }

        // Load profile data
        if let profileURL, FileManager.default.fileExists(atPath: profileURL.path) {
            if let profileData = try? Data(contentsOf: profileURL) {
                if let envelopes = try? JSONDecoder().decode(
                    [ProfileStatusEnvelope].self, from: profileData
                ) {
                    if let envelope = envelopes.first {
                        profileSummary = envelope.summary
                        profiles = failureRows(from: envelope.failures ?? [])

                        // Use profile timestamp if we don't have a policy timestamp
                        if sourceFile == nil {
                            sourceFile = profileURL
                            snapshotDate = (try? profileURL.resourceValues(
                                forKeys: [.contentModificationDateKey]))?
                                .contentModificationDate
                        }
                    } else {
                        AppLogger.engine.info(
                            "PolicyHealthService: profile-status snapshot decoded but contains no envelope — treating as no data"
                        )
                    }
                } else {
                    AppLogger.engine.warning(
                        "PolicyHealthService: failed to decode profile-status file \(profileURL.lastPathComponent, privacy: .public)"
                    )
                }
            } else {
                AppLogger.engine.warning(
                    "PolicyHealthService: could not read profile-status file \(profileURL.lastPathComponent, privacy: .public)"
                )
            }
        }

        // Return nil if we have no data at all
        guard summary != nil || profileSummary != nil || !profiles.isEmpty else { return nil }

        return Snapshot(
            summary: summary,
            findings: findings,
            profiles: profiles,
            profileSummary: profileSummary,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate
        )
    }

    // MARK: - Internals

    /// Map decoded failure rows to view rows. Rows with neither an id nor a
    /// name are dropped (a shape mismatch decodes all-Optional structs as
    /// all-nil — the #185 phantom row); the index prefix makes ids unique
    /// even when two profiles share a name.
    static func failureRows(from rows: [ProfileFailureRow]) -> [ProfileFailure] {
        rows.enumerated().compactMap { index, row in
            let rawId = row.profileId?.stringValue
            guard row.name != nil || rawId != nil else { return nil }
            return ProfileFailure(
                id: "\(index)-\(rawId ?? row.name ?? "")",
                name: row.name ?? "Profile \(rawId ?? "?")",
                deviceType: row.deviceType ?? "—",
                errors: row.errors?.intValue ?? 0,
                devices: row.devices?.intValue ?? 0,
                lastError: row.lastError ?? "",
                topError: row.topError ?? ""
            )
        }
    }
}
