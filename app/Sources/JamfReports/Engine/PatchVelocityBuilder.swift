import Foundation

// MARK: - Patch adoption velocity

/// One patch title's adoption trajectory measured against its release date.
///
/// `series` is a daily adoption-percentage curve (`onLatest / total * 100`)
/// built from every dated `patch-status` snapshot on disk. `daysTo50` / `daysTo90`
/// are the observed days-from-release to the first sample that crosses the
/// threshold — velocity metrics only meaningful when the crossing was actually
/// observed in the recorded history.
struct TitleVelocity: Sendable, Identifiable {
    let titleId: String
    let title: String
    let releaseDate: Date?
    /// Days between `releaseDate` and `now`; nil when there is no release date, or
    /// when the newest snapshot shows the title fully adopted (nothing to chase).
    let daysBehind: Int?
    /// Newest snapshot's adoption percentage (`onLatest / total * 100`); nil when
    /// the newest snapshot has `total == 0`.
    let adoptionPct: Double?
    /// Days from `releaseDate` until adoption first reached ≥ 50%; nil unless the
    /// crossing was observed (see `daysToThreshold` semantics below).
    let daysTo50: Int?
    let daysTo90: Int?
    /// Daily adoption curve, ascending, one point per day the title appears.
    let series: [(date: Date, adoptionPct: Double)]

    var id: String { titleId }
}

/// Computes `TitleVelocity` from dated `patch-status` snapshots + release dates.
enum PatchVelocityBuilder {

    // MARK: - Public API

    /// Build per-title adoption velocity from every dated `patch-status` snapshot
    /// in `dataDir/patch-status/`.
    ///
    /// **Series construction.** Reads every `patch-status_<yyyyMMddTHHmmss>.json`
    /// file (skips `manifest.json`; logs and skips undecodable files at `.notice`).
    /// For each title on each day, adoption% = `onLatest / total * 100`; days with
    /// `total == 0` are skipped (no denominator). One point per calendar day — the
    /// newest file for that day wins, mirroring `MSCPChartDataBuilder`'s
    /// last-writer-per-day dedupe.
    ///
    /// **Release-date join.** Matched by `titleId` first; falls back to a
    /// case-insensitive title-name match ONLY when the id join misses (mirrors the
    /// name-tolerant matching `CoreDashboard.writePatch` relies on).
    ///
    /// **`daysToThreshold` semantics (daysTo50 / daysTo90).** The value is
    /// `crossingSampleDate − releaseDate`, clamped ≥ 0, reported ONLY for a crossing
    /// actually present in the series. It is deliberately `nil` when:
    ///   - there is no release date, or
    ///   - no sample reaches the threshold, or
    ///   - the series' FIRST sample is already ≥ the threshold. In that case the
    ///     true crossing happened before recording began, so any computed value
    ///     would be a fabricated upper bound; we return nil and let `adoptionPct`
    ///     speak instead of inventing a crossing.
    /// A crossing whose release date predates the series start is still honest
    /// (the first below-threshold sample was recorded, then a later sample crossed),
    /// so it IS reported.
    ///
    /// - Parameters:
    ///   - dataDir: workspace jamf-cli data dir (contains `patch-status/`).
    ///   - releaseRows: `PatchReleaseDateService` rows (inject for tests).
    ///   - now: reference date for `daysBehind` (inject for tests).
    /// - Returns: one `TitleVelocity` per title seen in the history, sorted by
    ///   `daysBehind` descending (nil last), then title. Empty when no dated
    ///   snapshots decode.
    static func compute(
        dataDir: URL,
        releaseRows: [PatchReleaseDateService.Row],
        now: Date = Date()
    ) -> [TitleVelocity] {
        let daily = loadDailyRows(dataDir: dataDir)
        guard !daily.isEmpty else { return [] }

        // Accumulate per-title series across days. day is already deduped so each
        // (title, day) contributes at most one point.
        var byTitle: [String: TitleAccumulator] = [:]
        // Ascending day order so each title's series is naturally ascending.
        for day in daily.sorted(by: { $0.date < $1.date }) {
            for row in day.rows {
                guard row.total > 0 else { continue }  // no denominator — skip.
                let pct = Double(row.onLatest) / Double(row.total) * 100.0
                var acc = byTitle[row.id] ?? TitleAccumulator(titleId: row.id, title: row.title)
                // Keep the most recent title label seen (last-writer-wins on name).
                acc.title = row.title
                acc.series.append((date: day.date, adoptionPct: pct))
                byTitle[row.id] = acc
            }
        }

        let byId = PatchReleaseDateService.releaseDateLookup(from: releaseRows)
        let byName = nameLookup(releaseRows)

        let velocities: [TitleVelocity] = byTitle.values.map { acc in
            let releaseISO = releaseDateISO(titleId: acc.titleId, title: acc.title,
                                            byId: byId, byName: byName)
            let releaseDate = releaseISO.flatMap { SOFAFeedService.parseSOFADate($0) }
            let adoptionPct = acc.series.last?.adoptionPct
            return TitleVelocity(
                titleId: acc.titleId,
                title: acc.title,
                releaseDate: releaseDate,
                daysBehind: daysBehind(releaseDate: releaseDate, adoptionPct: adoptionPct, now: now),
                adoptionPct: adoptionPct,
                daysTo50: daysToThreshold(50, series: acc.series, releaseDate: releaseDate),
                daysTo90: daysToThreshold(90, series: acc.series, releaseDate: releaseDate),
                series: acc.series
            )
        }

        return velocities.sorted { lhs, rhs in
            switch (lhs.daysBehind, rhs.daysBehind) {
            case let (l?, r?) where l != r: return l > r        // more days behind first.
            case (_?, nil): return true                          // known before nil.
            case (nil, _?): return false
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    // MARK: - Internals

    /// Mutable per-title accumulator (dictionaries can't hold growing arrays inline).
    private struct TitleAccumulator {
        let titleId: String
        var title: String
        var series: [(date: Date, adoptionPct: Double)] = []
    }

    /// One deduped calendar day's worth of patch-status rows.
    private struct DayRows {
        let date: Date
        let rows: [PatchStatusRow]
    }

    /// Read + dedupe every dated patch-status snapshot into one entry per calendar day.
    private static func loadDailyRows(dataDir: URL) -> [DayRows] {
        let dir = dataDir.appendingPathComponent("patch-status", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Ascending by snapshot date so the newest file for a day overwrites earlier ones.
        let jsonFiles = files
            .filter { $0.pathExtension == "json"
                && $0.lastPathComponent.lowercased() != "manifest.json" }
            .sorted {
                MSCPChartDataBuilder.dateFromSnapshotFilename($0)
                    < MSCPChartDataBuilder.dateFromSnapshotFilename($1)
            }

        var byDay: [String: DayRows] = [:]
        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let rows = try? JSONDecoder().decode([PatchStatusRow].self, from: data) else {
                AppLogger.platform.notice(
                    "PatchVelocityBuilder: patch-status \(url.lastPathComponent, privacy: .public) undecodable — skipped"
                )
                continue
            }
            let date = MSCPChartDataBuilder.dateFromSnapshotFilename(url, fm: fm)
            let dayKey = dayKeyFormatter.string(from: date)
            // Later file (newer snapshot date) for the same day wins.
            byDay[dayKey] = DayRows(date: date, rows: rows)
        }
        return Array(byDay.values)
    }

    /// Case-insensitive title-name → releaseDate ISO fallback lookup.
    /// First writer wins per name so it's deterministic across duplicate titles.
    private static func nameLookup(_ rows: [PatchReleaseDateService.Row]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            let key = row.title.lowercased()
            if out[key] == nil { out[key] = row.releaseDate }
        }
        return out
    }

    /// Resolve a title's release-date ISO string: id join first, name fallback only on miss.
    private static func releaseDateISO(
        titleId: String, title: String,
        byId: [String: String], byName: [String: String]
    ) -> String? {
        if let byId = byId[titleId], !byId.isEmpty { return byId }
        if let byName = byName[title.lowercased()], !byName.isEmpty { return byName }
        return nil
    }

    /// Days between the release date and `now`; nil without a release date, and nil
    /// once the newest sample shows full adoption (100%) — nothing left to chase.
    private static func daysBehind(
        releaseDate: Date?, adoptionPct: Double?, now: Date
    ) -> Int? {
        guard let releaseDate else { return nil }
        if let pct = adoptionPct, pct >= 100.0 { return nil }
        let diff = Calendar.current.dateComponents([.day], from: releaseDate, to: now)
        guard let days = diff.day else { return nil }
        return max(0, days)
    }

    /// First series sample reaching `threshold`, expressed as days from `releaseDate`.
    /// See `compute`'s doc comment for the full semantics (nil when the series starts
    /// already ≥ threshold, no release date, or never crosses).
    private static func daysToThreshold(
        _ threshold: Double,
        series: [(date: Date, adoptionPct: Double)],
        releaseDate: Date?
    ) -> Int? {
        guard let releaseDate, let first = series.first else { return nil }
        // Series already above threshold at the first recorded sample: the true
        // crossing predates recording — don't fabricate one.
        if first.adoptionPct >= threshold { return nil }
        guard let crossing = series.first(where: { $0.adoptionPct >= threshold }) else {
            return nil
        }
        let diff = Calendar.current.dateComponents([.day], from: releaseDate, to: crossing.date)
        guard let days = diff.day else { return nil }
        return max(0, days)
    }

    /// Day-string formatter in LOCAL time on purpose: dateFromSnapshotFilename
    /// parses snapshot timestamps as local time (the canonical saveSnapshot
    /// convention), so day-bucketing must use the same zone — a UTC key would
    /// split one local day across two buckets past the UTC midnight boundary.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        return f
    }()
}
