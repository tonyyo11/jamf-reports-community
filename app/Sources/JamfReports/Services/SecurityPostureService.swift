import Foundation

/// Reads the latest `pro report security --output json` snapshot from the
/// workspace's jamf-cli data directory and prepares it for the
/// `SecurityPostureView`. Decoupled from the SwiftUI view so it stays
/// unit-testable.
///
/// The view consumes a single `Snapshot` value containing both raw counts
/// (for KPI tiles) and the OS-version distribution (for the donut). The
/// `SecurityScore` is computed separately by `SecurityScoreCalculator` so
/// the view can pass user-configurable weights through.
struct SecurityPostureService: Sendable {

    /// Everything the SecurityPostureView needs from a single security
    /// snapshot. `nil` fields mean "data not present in this snapshot" — the
    /// view should hide the corresponding tile rather than zero it.
    struct Snapshot: Sendable, Equatable {
        let totalDevices: Int
        let fileVaultEncrypted: Int?
        let sipEnabled: Int?
        let firewallEnabled: Int?
        let gatekeeperEnabled: Int?
        let osVersions: [OSVersion]
        let sourceFile: URL?
        let snapshotDate: Date?
        /// Non-nil only when a snapshot file existed but could not be read/decoded —
        /// a true failure, distinct from `.empty` (no data collected yet).
        var loadError: String? = nil

        struct OSVersion: Sendable, Equatable, Identifiable {
            let osVersion: String
            let count: Int
            let pct: Double
            var id: String { osVersion }
        }

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        /// Empty snapshot used when no data file exists for the active profile.
        /// Hides every KPI but renders an explanatory empty state in the view.
        static let empty = Snapshot(
            totalDevices: 0,
            fileVaultEncrypted: nil,
            sipEnabled: nil,
            firewallEnabled: nil,
            gatekeeperEnabled: nil,
            osVersions: [],
            sourceFile: nil,
            snapshotDate: nil
        )

        /// A true read/decode failure (file present but unreadable), distinct from `.empty`.
        static func failed(_ reason: String) -> Snapshot {
            var s = empty
            s.loadError = reason
            return s
        }
    }

    enum LoadError: Error, Equatable {
        case dirMissing
        case noSnapshot
        case decodeFailed(String)
    }

    /// Returns the newest snapshot for `profile`. Returns `.empty` (not throws)
    /// when no snapshot exists — that's a normal state pre-first-collect and
    /// the view should render a "Run Collect" prompt rather than an error.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let securityDir = dir.appendingPathComponent("security", isDirectory: true)
        guard let newest = FileManager.newestJSONFile(in: securityDir) else {
            return .empty
        }
        do {
            return try decode(at: newest)
        } catch let LoadError.decodeFailed(reason) {
            return .failed("Couldn't read the latest security snapshot — \(reason).")
        } catch {
            return .failed("Couldn't read the latest security snapshot.")
        }
    }

    /// Test seam: load directly from an arbitrary file URL.
    static func load(from url: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.noSnapshot
        }
        return try decode(at: url)
    }

    // MARK: - Internals

    private static func decode(at url: URL) throws -> Snapshot {
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.platform.warning(
                "SecurityPostureService: could not read security file \(url.lastPathComponent, privacy: .public)"
            )
            throw LoadError.decodeFailed("could not read \(url.lastPathComponent)")
        }
        guard let items = try? JSONDecoder().decode([SecurityReportItem].self, from: data) else {
            AppLogger.platform.warning(
                "SecurityPostureService: failed to decode security file \(url.lastPathComponent, privacy: .public)"
            )
            throw LoadError.decodeFailed("failed to decode \(url.lastPathComponent)")
        }

        var summary: SecuritySummaryData?
        var osVersions: [Snapshot.OSVersion] = []

        for item in items {
            switch item {
            case .summary(let s):
                summary = s.data
            case .osVersion(let v):
                osVersions.append(.init(
                    osVersion: v.osVersion,
                    count: v.count,
                    pct: parsePct(v.pct)
                ))
            case .device, .unknown:
                continue
            }
        }
        let total = summary?.totalDevices ?? 0
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Snapshot(
            totalDevices: total,
            fileVaultEncrypted: summary?.fileVaultEncrypted,
            sipEnabled: summary?.sipEnabled,
            firewallEnabled: summary?.firewallEnabled,
            gatekeeperEnabled: summary?.gatekeeperEnabled,
            osVersions: osVersions.sorted { $0.osVersion > $1.osVersion },
            sourceFile: url,
            snapshotDate: mtime
        )
    }

    /// "60%" → 60.0. Best-effort: returns 0 on any parse failure since the
    /// percentage is decorative (the count is the source of truth).
    private static func parsePct(_ raw: String) -> Double {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        return Double(stripped) ?? 0
    }
}

// MARK: - SecurityScore convenience

extension SecurityScoreCalculator {
    /// Build the calculator input directly from a posture snapshot. The mSCP,
    /// CrowdStrike, XProtect, CVE, and Secure Boot signals are not in the
    /// `pro security report` JSON — wire those in from EA results or
    /// `device-compliance` once those services land.
    static func input(from snapshot: SecurityPostureService.Snapshot) -> Input {
        var counts: [SecurityScore.Metric: Int] = [:]
        if let n = snapshot.fileVaultEncrypted { counts[.fileVault] = n }
        if let n = snapshot.sipEnabled { counts[.sip] = n }
        if let n = snapshot.firewallEnabled { counts[.firewall] = n }
        // Note: gatekeeperEnabled exists in the snapshot but is not one of the
        // SecurityScore.Metric cases. v3.5 weighted Gatekeeper at 5% under the
        // CVE/Secure Boot bucket — keeping the calculator focused on the 8
        // canonical metrics and treating Gatekeeper as a per-tile signal only.
        return Input(totalDevices: snapshot.totalDevices, compliantCounts: counts)
    }
}
