import Foundation

/// Reads the latest `pro report patch-status` and `patch-status --scan-failures`
/// snapshots from the workspace's jamf-cli data directory and prepares them for
/// the `PatchView`. Decoupled from the SwiftUI view so it stays unit-testable.
///
/// The view consumes a single `Snapshot` value containing both patch titles
/// (for the main table) and device failures (for the Recent Failures table).
/// Fleet compliance is device-weighted across titles (`fleetCompliancePct`).
struct PatchStatusService: Sendable {

    /// Everything the PatchView needs from both patch status snapshots.
    /// `nil` sourceFile and snapshotDate mean "data not present" — the view
    /// should render an empty state rather than error.
    struct Snapshot: Sendable, Equatable {
        let titles: [PatchStatusRow]
        let failures: [PatchFailureRow]
        let sourceFile: URL?
        let snapshotDate: Date?
        /// Per-kind newest-file dates for the freshness chip row. Keys are the
        /// on-disk kind names (`patch-status`, `patch-device-failures`); a kind
        /// absent from disk is absent from the map.
        var sourceDates: [String: Date] = [:]

        // MARK: - Computed aggregates

        var totalTitles: Int {
            titles.count
        }

        /// Titles where on_latest / total >= 90%. Titles with total == 0 are excluded
        /// (no devices enrolled for that patch title — neither compliant nor failing).
        var compliantTitleCount: Int {
            titles.filter { title in
                title.total > 0 && Double(title.onLatest) / Double(title.total) * 100.0 >= 90.0
            }.count
        }

        /// Titles where on_latest / total < 50%. Titles with total == 0 are excluded.
        var failingTitleCount: Int {
            titles.filter { title in
                title.total > 0 && Double(title.onLatest) / Double(title.total) * 100.0 < 50.0
            }.count
        }

        /// `PatchStatusService.fleetCompliancePct(titles)`; nil when no title has devices.
        var fleetCompliancePct: Double? {
            PatchStatusService.fleetCompliancePct(titles)
        }

        /// Number of devices with patch failures, grouped by policy name.
        var failuresByTitle: [String: Int] {
            Dictionary(failures.map { ($0.policy, 1) }, uniquingKeysWith: +)
        }

        /// Total unique devices that have at least one patch failure.
        var devicesWithFailures: Int {
            Set(failures.map(\.deviceId)).count
        }

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
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
            lhs.snapshotDate == rhs.snapshotDate &&
            lhs.sourceDates == rhs.sourceDates
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

        guard let titlesURL = FileManager.newestJSONFile(in: patchDir) else {
            return .empty
        }

        let failuresURL = FileManager.newestJSONFile(in: failuresDir)
        return load(from: titlesURL, failuresURL: failuresURL) ?? .empty
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(from titlesURL: URL, failuresURL: URL? = nil) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: titlesURL.path) else {
            return nil
        }

        guard let titlesData = try? Data(contentsOf: titlesURL) else {
            AppLogger.collect.info(
                "PatchStatusService: could not read patch-status file \(titlesURL.lastPathComponent, privacy: .public)"
            )
            return nil
        }

        guard let titles = (try? JSONDecoder().decode([PatchStatusRow].self, from: titlesData)) else {
            AppLogger.collect.info(
                "PatchStatusService: failed to decode patch-status file \(titlesURL.lastPathComponent, privacy: .public)"
            )
            return nil
        }

        var failures: [PatchFailureRow] = []
        if let failuresURL, FileManager.default.fileExists(atPath: failuresURL.path) {
            if let failuresData = try? Data(contentsOf: failuresURL) {
                if let decodedFailures = try? JSONDecoder().decode(
                    [PatchFailureRow].self, from: failuresData
                ) {
                    failures = decodedFailures
                } else {
                    AppLogger.collect.warning(
                        "PatchStatusService: failed to decode patch-device-failures file \(failuresURL.lastPathComponent, privacy: .public)"
                    )
                }
            } else {
                AppLogger.collect.warning(
                    "PatchStatusService: could not read patch-device-failures file \(failuresURL.lastPathComponent, privacy: .public)"
                )
            }
        }

        let mtime = (try? titlesURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        var sourceDates: [String: Date] = [:]
        if let mtime { sourceDates["patch-status"] = mtime }
        if let failuresURL,
           FileManager.default.fileExists(atPath: failuresURL.path),
           let fmtime = (try? failuresURL.resourceValues(
               forKeys: [.contentModificationDateKey]
           ))?.contentModificationDate {
            sourceDates["patch-device-failures"] = fmtime
        }

        return Snapshot(
            titles: titles,
            failures: failures,
            sourceFile: titlesURL,
            snapshotDate: mtime,
            sourceDates: sourceDates
        )
    }

    // MARK: - Fleet compliance

    /// The one patch-compliance definition (epic #207 C1): `Σ on_latest / Σ total * 100`
    /// over titles with `total > 0`, so each title weighs in by its device count. A title
    /// nobody has carries no signal, and some jamf-cli builds emit a parseable "0%" for it,
    /// so it joins neither sum. jamf-cli can count a device twice across patch policies
    /// (`PatchVelocityBuilder` clamps the same way), so each title's `on_latest` is held
    /// between 0 and its own `total`: the figure never passes 100. Nil, never 0, when no
    /// title has devices.
    static func fleetCompliancePct(_ titles: [PatchStatusRow]) -> Double? {
        let counted = titles.filter { $0.total > 0 }
        let devices = counted.reduce(0) { $0 + $1.total }
        guard devices > 0 else { return nil }
        let onLatest = counted.reduce(0) { $0 + min(max($1.onLatest, 0), $1.total) }
        return Double(onLatest) / Double(devices) * 100.0
    }

    // MARK: - Internals

    /// Parse "83%" into 83.0, "100%" into 100.0, etc.
    /// Returns 0 on any parse failure since compliance percentage is decorative
    /// (the actual device counts are the source of truth).
    static func parseCompliancePct(_ raw: String) -> Double {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        return Double(stripped) ?? 0
    }

    // MARK: - CSV export

    /// Column header for the standalone patch-compliance CSV. Matches the
    /// engine's "Patch Compliance" workbook sheet (`CoreDashboard.writePatch`).
    static let complianceCSVHeader = "Title,Latest,On Latest,On Other,Total,Compliance %"

    /// Render `titles` as a standalone CSV with the same column shape and row
    /// order as the engine's "Patch Compliance" sheet, so an admin can export
    /// the patch report on its own without generating a full workbook.
    static func complianceCSV(_ titles: [PatchStatusRow]) -> String {
        var lines = [complianceCSVHeader]
        for t in titles {
            let cells = [
                t.title, t.latest, String(t.onLatest),
                String(t.onOther), String(t.total), t.compliancePct,
            ]
            lines.append(cells.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escape a value for CSV output. First neutralizes spreadsheet formula
    /// injection — a leading `=`, `+`, `-`, `@`, tab or carriage return can make
    /// Excel/Numbers evaluate the cell — by prefixing a tab, as
    /// `StaleDeviceService.csvField` does. Then applies RFC 4180 quoting: a
    /// field containing a comma, double-quote, CR or LF is wrapped in
    /// double-quotes with embedded quotes doubled.
    private static func csvField(_ value: String) -> String {
        var field = value
        if let first = field.first, "=+-@\t\r".contains(first) {
            field = "\t" + field
        }
        guard field.contains(where: { ",\"\n\r".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}