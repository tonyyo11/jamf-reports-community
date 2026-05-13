import Foundation

/// One-shot importer that reads the legacy v3.5
/// `fleet_health_metrics_history.json` corpus and re-emits each entry as a
/// `summary_YYYY-MM-DD.json` file inside the active workspace's summaries
/// directory. Seeds `TrendStore` with 12+ weeks of fleet-health history on
/// day one without ongoing CSV ingestion.
///
/// Idempotent: existing summary files for a given date are not overwritten
/// unless `overwriteExisting` is `true`.
struct LegacyHistoryImporter: Sendable {

    /// Outcome of a single import run. Surfaced in the SettingsView toast.
    struct Outcome: Sendable, Equatable {
        let imported: [String]   // ISO dates ("2026-05-11") that were written
        let skipped: [String]    // ISO dates that already existed and were not overwritten
        let invalid: [String]    // raw `date` values that could not be parsed
        var totalParsed: Int { imported.count + skipped.count + invalid.count }
    }

    enum Failure: Error, Equatable {
        case fileNotFound(URL)
        case invalidJSON(String)
        case writeFailed(String)
        case noEntries
    }

    /// The shape of a single entry in the legacy history JSON. Matches the
    /// snake_case keys emitted by `FleetHealthDashboard._save_metrics_history()`.
    private struct LegacyEntry: Decodable {
        let totalDevices: Int
        let fileVaultCompliant: Int?
        let sipCompliant: Int?
        let firewallCompliant: Int?
        let gatekeeperCompliant: Int?
        let crowdstrikeConnected: Int?
        let xprotectCurrent: Int?
        let cveClean: Int?
        let secureBootFull: Int?
        let bootstrapEscrowed: Int?
        let noBaselineActive: Int?
        let mscpScorePct: Double?
        let securityScore: Double?
        let actionItemsP0: Int?
        let actionItemsP1: Int?
        let actionItemsP2: Int?
        let date: String

        private enum CodingKeys: String, CodingKey {
            case totalDevices = "total_devices"
            case fileVaultCompliant = "filevault_compliant"
            case sipCompliant = "sip_compliant"
            case firewallCompliant = "firewall_compliant"
            case gatekeeperCompliant = "gatekeeper_compliant"
            case crowdstrikeConnected = "crowdstrike_connected"
            case xprotectCurrent = "xprotect_current"
            case cveClean = "cve_clean"
            case secureBootFull = "secure_boot_full"
            case bootstrapEscrowed = "bootstrap_escrowed"
            case noBaselineActive = "no_baseline_active"
            case mscpScorePct = "mscp_score_pct"
            case securityScore = "security_score"
            case actionItemsP0 = "action_items_p0"
            case actionItemsP1 = "action_items_p1"
            case actionItemsP2 = "action_items_p2"
            case date
        }
    }

    /// Default path to the legacy history file. Used as the file-picker
    /// default in the Settings action; callers can pass an arbitrary URL.
    static var defaultHistoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Mac_Engineering/Jamf Reports/Generated Reports/fleet_health_metrics_history.json")
    }

    /// Reads `source`, translates each entry to `DailySummary`, and writes
    /// one `summary_YYYY-MM-DD.json` per date into `destinationDir`.
    static func importHistory(
        from source: URL,
        to destinationDir: URL,
        overwriteExisting: Bool = false
    ) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw Failure.fileNotFound(source)
        }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw Failure.invalidJSON(error.localizedDescription)
        }
        let entries: [LegacyEntry]
        do {
            entries = try JSONDecoder().decode([LegacyEntry].self, from: data)
        } catch {
            throw Failure.invalidJSON(error.localizedDescription)
        }
        guard !entries.isEmpty else { throw Failure.noEntries }

        try FileManager.default.createDirectory(
            at: destinationDir,
            withIntermediateDirectories: true
        )

        var imported: [String] = []
        var skipped: [String] = []
        var invalid: [String] = []

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for entry in entries {
            guard let isoDate = isoDate(from: entry.date) else {
                invalid.append(entry.date)
                continue
            }
            let destination = destinationDir
                .appendingPathComponent("summary_\(isoDate).json")
            if !overwriteExisting,
               FileManager.default.fileExists(atPath: destination.path) {
                skipped.append(isoDate)
                continue
            }
            let summary = dailySummary(from: entry, isoDate: isoDate)
            do {
                let encoded = try encoder.encode(summary)
                try encoded.write(to: destination, options: [.atomic])
                imported.append(isoDate)
            } catch {
                throw Failure.writeFailed(error.localizedDescription)
            }
        }

        return Outcome(imported: imported, skipped: skipped, invalid: invalid)
    }

    /// Convenience wrapper for the active workspace profile. Throws if the
    /// profile slug is invalid or the workspace summaries dir cannot be
    /// resolved.
    static func importHistory(
        from source: URL,
        forProfile profile: String,
        overwriteExisting: Bool = false
    ) throws -> Outcome {
        let dir = try WorkspacePaths.summariesDir(for: profile)
        return try importHistory(
            from: source,
            to: dir,
            overwriteExisting: overwriteExisting
        )
    }

    // MARK: - Translation

    /// Accept both `YYYYMMDD` (v3.5 default) and `YYYY-MM-DD` (newer python),
    /// returning the canonical `YYYY-MM-DD` form used by `summary.json`.
    private static func isoDate(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatters: [DateFormatter] = [yyyymmddFormatter, isoFormatter]
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) {
                return isoFormatter.string(from: date)
            }
        }
        return nil
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let yyyymmddFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func dailySummary(from entry: LegacyEntry, isoDate: String) -> DailySummary {
        DailySummary(
            date: isoDate,
            totalDevices: entry.totalDevices,
            fileVaultPct: pct(of: entry.fileVaultCompliant, total: entry.totalDevices) ?? 0,
            // mscpScorePct is the v3.5 STIG/compliance signal — use it for
            // the existing `compliancePct` slot so TrendsView's compliance
            // line plots the legacy data immediately.
            compliancePct: entry.mscpScorePct,
            staleCount: 0,    // not tracked in legacy history JSON
            osCurrentPct: 0,  // not tracked
            crowdstrikePct: pct(of: entry.crowdstrikeConnected, total: entry.totalDevices),
            patchPct: 0,      // not tracked
            source: "legacy-import",
            sipPct: pct(of: entry.sipCompliant, total: entry.totalDevices),
            firewallPct: pct(of: entry.firewallCompliant, total: entry.totalDevices),
            gatekeeperPct: pct(of: entry.gatekeeperCompliant, total: entry.totalDevices),
            secureBootPct: pct(of: entry.secureBootFull, total: entry.totalDevices),
            bootstrapPct: pct(of: entry.bootstrapEscrowed, total: entry.totalDevices),
            xprotectPct: pct(of: entry.xprotectCurrent, total: entry.totalDevices),
            cvePct: pct(of: entry.cveClean, total: entry.totalDevices),
            mscpScorePct: entry.mscpScorePct,
            securityScore: entry.securityScore,
            actionItemsP0: entry.actionItemsP0,
            actionItemsP1: entry.actionItemsP1,
            actionItemsP2: entry.actionItemsP2,
            noBaselineActive: entry.noBaselineActive
        )
    }

    private static func pct(of count: Int?, total: Int) -> Double? {
        guard let count, total > 0 else { return nil }
        return (Double(count) / Double(total)) * 100
    }
}
