import Foundation

/// Reads the latest `pro report patch-status` and `patch-status --scan-failures`
/// snapshots from the workspace's jamf-cli data directory and prepares them for
/// the `PatchView`. Decoupled from the SwiftUI view so it stays unit-testable.
///
/// The view consumes a single `Snapshot` value containing both patch titles
/// (for the main table) and device failures (for the Recent Failures table).
/// Fleet compliance percentage is computed as a weighted average across all titles.
struct PatchStatusService: Sendable {

    /// Everything the PatchView needs from both patch status snapshots.
    /// `nil` sourceFile and snapshotDate mean "data not present" — the view
    /// should render an empty state rather than error.
    struct Snapshot: Sendable, Equatable {
        let titles: [PatchStatusRow]
        let failures: [PatchFailureRow]
        let sourceFile: URL?
        let snapshotDate: Date?

        // MARK: - Computed aggregates

        var totalTitles: Int {
            titles.count
        }

        /// Titles with compliance >= 90%
        var compliantTitleCount: Int {
            titles.filter { parseCompliancePct($0.compliancePct) >= 90.0 }.count
        }

        /// Titles with compliance < 50%
        var failingTitleCount: Int {
            titles.filter { parseCompliancePct($0.compliancePct) < 50.0 }.count
        }

        /// Fleet-wide compliance percentage, weighted by device count per title.
        /// Returns 0 if no titles or all titles have zero devices.
        var fleetCompliancePct: Double {
            guard !titles.isEmpty else { return 0 }
            let totalDevices = titles.reduce(0) { $0 + $1.total }
            guard totalDevices > 0 else { return 0 }

            let weightedSum = titles.reduce(0.0) { sum, title in
                let pct = parseCompliancePct(title.compliancePct)
                return sum + (Double(title.total) * pct)
            }
            return weightedSum / Double(totalDevices)
        }

        /// Number of devices with patch failures, grouped by policy name.
        var failuresByTitle: [String: Int] {
            Dictionary(failures.map { ($0.policy, 1) }, uniquingKeysWith: +)
        }

        /// Total unique devices that have at least one patch failure.
        var devicesWithFailures: Int {
            Set(failures.map(\.deviceId)).count
        }

        static let empty = Snapshot(
            titles: [],
            failures: [],
            sourceFile: nil,
            snapshotDate: nil
        )

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.titles == rhs.titles &&
            lhs.failures == rhs.failures &&
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

        let patchDir = dir.appendingPathComponent("patch-status", isDirectory: true)
        let failuresDir = dir.appendingPathComponent("patch-device-failures", isDirectory: true)

        guard let titlesURL = newestJSON(in: patchDir) else {
            return .empty
        }

        let failuresURL = newestJSON(in: failuresDir)
        return load(from: titlesURL, failuresURL: failuresURL) ?? .empty
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(from titlesURL: URL, failuresURL: URL? = nil) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: titlesURL.path) else {
            return nil
        }

        guard let titlesData = try? Data(contentsOf: titlesURL) else {
            return nil
        }

        guard let titles = try? JSONDecoder().decode([PatchStatusRow].self, from: titlesData) else {
            return nil
        }

        var failures: [PatchFailureRow] = []
        if let failuresURL,
           FileManager.default.fileExists(atPath: failuresURL.path),
           let failuresData = try? Data(contentsOf: failuresURL),
           let decodedFailures = try? JSONDecoder().decode([PatchFailureRow].self, from: failuresData) {
            failures = decodedFailures
        }

        let mtime = (try? titlesURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        return Snapshot(
            titles: titles,
            failures: failures,
            sourceFile: titlesURL,
            snapshotDate: mtime
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

    /// Parse "83%" into 83.0, "100%" into 100.0, etc.
    /// Returns 0 on any parse failure since compliance percentage is decorative
    /// (the actual device counts are the source of truth).
    static func parseCompliancePct(_ raw: String) -> Double {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        return Double(stripped) ?? 0
    }
}