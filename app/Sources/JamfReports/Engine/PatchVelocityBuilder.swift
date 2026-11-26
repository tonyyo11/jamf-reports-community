import Foundation
import Synchronization

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

/// What one read of the patch history gives every reader: Patch Velocity's titles, every
/// version window, and the `patch-version-dates` read the windows were dated from.
typealias PatchHistory = (
    velocities: [TitleVelocity], versions: [VersionVelocity], versionDates: VersionDatesRead,
    now: Date
)

/// One report run's patch history: the workbook and the HTML beside it read it once and
/// measure it against one "now". Bound by `ReportEngine` through `PatchVelocityBuilder.runShare`.
final class PatchHistoryShare: Sendable {
    private let state = Mutex<(now: Date?, histories: [String: PatchHistory])>((nil, [:]))

    /// The run's "now": the first one given wins, so a later step cannot move it.
    func adopt(now: Date) { state.withLock { if $0.now == nil { $0.now = now } } }

    func history(dataDir: URL, now: Date, build: (Date) -> PatchHistory) -> PatchHistory {
        let key = dataDir.standardizedFileURL.path
        let (cached, runNow) = state.withLock { ($0.histories[key], $0.now ?? now) }
        if let cached { return cached }
        let built = build(runNow)
        state.withLock { $0.histories[key] = built; if $0.now == nil { $0.now = runNow } }
        return built
    }
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
        computeWithVersions(dataDir: dataDir, releaseRows: releaseRows, now: now).velocities
    }

    /// The report run this read belongs to, when one is bound; nil reads afresh every call.
    @TaskLocal static var runShare: PatchHistoryShare?

    /// `compute` and the version windows it is built on, from one read of the history, for
    /// the Patch screen, which shows both. Inside a report run (`runShare`) it is read once per
    /// data folder and measured against the run's "now".
    static func computeWithVersions(
        dataDir: URL,
        releaseRows: [PatchReleaseDateService.Row],
        now: Date = Date()
    ) -> PatchHistory {
        guard let share = runShare else {
            return AppLogger.signpost("Patch history") {
                readHistory(dataDir: dataDir, releaseRows: releaseRows, now: now)
            }
        }
        // The run's rows come from its own data folder, so no caller's rows can change the
        // history another step of the run is served.
        return share.history(dataDir: dataDir, now: now) { runNow in
            AppLogger.signpost("Patch history") {
                readHistory(dataDir: dataDir,
                            releaseRows: PatchReleaseDateService.load(dataDir: dataDir),
                            now: runNow)
            }
        }
    }

    private static func readHistory(
        dataDir: URL, releaseRows: [PatchReleaseDateService.Row], now: Date
    ) -> PatchHistory {
        // Read before the empty-history guard: the card lists versions and notes with no history.
        let versionDates = PatchReleaseDateService.versionDates(dataDir: dataDir)
        let daily = loadDailyRows(dataDir: dataDir)
        guard !daily.isEmpty else { return ([], [], versionDates, now) }

        // Accumulate per-title series across days. day is already deduped so each
        // (title, day) contributes at most one point.
        var byTitle: [String: TitleAccumulator] = [:]
        // Ascending day order so each title's series is naturally ascending.
        for day in daily.sorted(by: { $0.date < $1.date }) {
            for row in day.rows {
                guard row.total > 0 else { continue }  // no denominator — skip.
                // Clamp at 100: jamf-cli can double-count devices across patch
                // policies (on_latest > total) — never chart >100% adoption.
                let pct = min(Double(row.onLatest) / Double(row.total) * 100.0, 100.0)
                var acc = byTitle[row.id] ?? TitleAccumulator(titleId: row.id, title: row.title)
                // Keep the most recent title label seen (last-writer-wins on name).
                acc.title = row.title
                acc.series.append((date: day.date, adoptionPct: pct))
                byTitle[row.id] = acc
            }
        }

        let byId = PatchReleaseDateService.releaseDateLookup(from: releaseRows)
        let byName = nameLookup(releaseRows)
        // One calculator with Version History: a title's release date and days-to figures
        // come from its latest version window.
        let lookup = PatchReleaseDateService.releaseDateLookup(
            releaseRows: releaseRows, dataDir: dataDir, versionDates: versionDates, now: now)
        let allVersions = versions(days: daily, lookup: lookup)
        // The latest window counts only when it is the version Jamf named on the newest day
        // that named one; when that version has no points, the whole series stands.
        var newestNamed: [String: String] = [:]
        for day in daily.sorted(by: { $0.date < $1.date }) {
            for row in day.rows {
                let latest = row.latest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !latest.isEmpty { newestNamed[row.id] = latest }
            }
        }
        let latestWindows = latestWindowByTitle(allVersions)
            .filter { newestNamed[$0.key] == $0.value.version }

        let velocities: [TitleVelocity] = byTitle.values.map { acc in
            let adoptionPct = acc.series.last?.adoptionPct
            // A title with no window (every `latest` blank) keeps the whole series, as before.
            let latest = latestWindows[acc.titleId]
            let releaseDate = latest.map {
                $0.releaseDate ?? lookup.latestReleaseDate(titleId: acc.titleId, title: acc.title)
            } ?? releaseDateISO(titleId: acc.titleId, title: acc.title, byId: byId, byName: byName)
                .flatMap { SOFAFeedService.parseSOFADate($0) }
            let measured = latest?.window.series ?? acc.series
            return TitleVelocity(
                titleId: acc.titleId,
                title: acc.title,
                releaseDate: releaseDate,
                daysBehind: daysBehind(
                    releaseDate: releaseDate, adoptionPct: adoptionPct, now: now),
                adoptionPct: adoptionPct,
                daysTo50: daysToThreshold(50, series: measured, releaseDate: releaseDate),
                daysTo90: daysToThreshold(90, series: measured, releaseDate: releaseDate),
                series: acc.series
            )
        }

        let sorted = velocities.sorted { lhs, rhs in
            switch (lhs.daysBehind, rhs.daysBehind) {
            case let (l?, r?) where l != r: return l > r        // more days behind first.
            case (_?, nil): return true                          // known before nil.
            case (nil, _?): return false
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return (sorted, allVersions, versionDates, now)
    }

    // MARK: - Internals

    /// Mutable per-title accumulator (dictionaries can't hold growing arrays inline).
    private struct TitleAccumulator {
        let titleId: String
        var title: String
        var series: [(date: Date, adoptionPct: Double)] = []
    }

    /// One deduped calendar day's worth of patch-status rows.
    struct DayRows {
        let date: Date
        let rows: [PatchStatusRow]
    }

    /// Read + dedupe every dated patch-status snapshot into one entry per calendar day.
    static func loadDailyRows(dataDir: URL) -> [DayRows] {
        let dir = dataDir.appendingPathComponent("patch-status", isDirectory: true)
        let fm = FileManager.default
        guard let files = FileManager.snapshotFolderEntries(in: dir) else {
            return []
        }

        // Ascending by snapshot date so the newest file for a day overwrites earlier ones.
        let jsonFiles = files
            .filter { $0.pathExtension == "json"
                && $0.lastPathComponent.lowercased() != "manifest.json" }
            .filter { !CloudStorage.isLikelySyncConflict($0.lastPathComponent) }
            .sorted {
                MSCPChartDataBuilder.dateFromSnapshotFilename($0)
                    < MSCPChartDataBuilder.dateFromSnapshotFilename($1)
            }

        var byDay: [String: DayRows] = [:]
        for url in jsonFiles {
            guard let data = BoundedFile.readLogged(url, inside: dataDir) else { continue }
            guard let rows = try? JSONDecoder().decode([PatchStatusRow].self, from: data) else {
                AppLogger.platform.notice(
                    "PatchVelocityBuilder: patch-status \(url.lastPathComponent, privacy: .private) undecodable — skipped"
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

    // MARK: - Version windows

    /// Every version window of every title, from the days given (ascending or not).
    ///
    /// A window opens on the first day Jamf's `latest` (trimmed, non-blank) names a version and
    /// closes on the first later day a different non-blank `latest` appears; a version that
    /// comes back opens a new window. A day with the title missing, `total == 0` or a blank
    /// `latest` adds no point and closes nothing, and a window with no points is dropped.
    static func versions(days: [DayRows], lookup: ReleaseDateLookup) -> [VersionVelocity] {
        typealias Series = [(date: Date, adoptionPct: Double)]
        var open: [String: (version: String, title: String, start: Date, series: Series)] = [:]
        var closed: [(titleId: String, title: String, version: String, start: Date, end: Date?,
                      series: Series)] = []
        for day in days.sorted(by: { $0.date < $1.date }) {
            for row in day.rows {
                let latest = row.latest.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latest.isEmpty else { continue }
                if let current = open[row.id], current.version != latest {
                    closed.append((row.id, current.title, current.version, current.start, day.date,
                                   current.series))
                    open[row.id] = nil
                }
                var window = open[row.id] ?? (latest, row.title, day.date, [])
                window.title = row.title
                if row.total > 0 {
                    let pct = min(Double(row.onLatest) / Double(row.total) * 100.0, 100.0)
                    window.series.append((date: day.date, adoptionPct: pct))
                }
                open[row.id] = window
            }
        }
        for (titleId, window) in open {
            closed.append((titleId, window.title, window.version, window.start, nil, window.series))
        }
        var byVersion: [String: VersionVelocity] = [:]
        var order: [String] = []
        for item in closed.sorted(by: { $0.start < $1.start }) where !item.series.isEmpty {
            let key = item.titleId + "|" + item.version
            let releaseDate = lookup.date(
                titleId: item.titleId, title: item.title, version: item.version)
            let window = VersionWindow(
                start: item.start, end: item.end, series: item.series, releaseDate: releaseDate,
                daysTo50: daysToThreshold(50, series: item.series, releaseDate: releaseDate),
                daysTo90: daysToThreshold(90, series: item.series, releaseDate: releaseDate))
            if byVersion[key] == nil {
                order.append(key)
                byVersion[key] = VersionVelocity(
                    titleId: item.titleId, title: item.title, version: item.version,
                    releaseDate: releaseDate, windows: [])
            }
            byVersion[key]?.windows.append(window)
        }
        return order.compactMap { byVersion[$0] }
    }

    /// Each title's latest window: the one opened last, which is the window of the version
    /// Jamf named on the newest day with a non-blank `latest`.
    static func latestWindowByTitle(
        _ versions: [VersionVelocity]
    ) -> [String: (window: VersionWindow, releaseDate: Date?, version: String)] {
        var latest: [String: (window: VersionWindow, releaseDate: Date?, version: String)] = [:]
        for version in versions {
            for window in version.windows {
                if let seen = latest[version.titleId], seen.window.start >= window.start {
                    continue
                }
                latest[version.titleId] = (window, version.releaseDate, version.version)
            }
        }
        return latest
    }

    /// Days to 90% across titles over the last `periodDays`, counted in windows.
    static func summary(
        _ versions: [VersionVelocity], periodDays: Int = 90, now: Date = Date()
    ) -> FleetVersionSummary {
        let since = now.addingTimeInterval(-Double(periodDays) * 86_400)
        func inPeriod(_ date: Date?) -> Bool { date.map { $0 >= since && $0 <= now } ?? false }
        var summary = FleetVersionSummary()
        summary.since = since
        summary.now = now
        var days: [Int] = []
        for window in versions.flatMap(\.windows) {
            switch window.outcome {
            case .crossed:
                guard inPeriod(window.crossedAt90) else { continue }
                if let value = window.daysTo90 {
                    days.append(value)
                } else {
                    summary.noReleaseDate += 1
                }
            case .superseded:
                if inPeriod(window.end) { summary.superseded += 1 }
            case .alreadyAt90:
                if inPeriod(window.start) { summary.alreadyAt90 += 1 }
            case .open:
                summary.notYet += 1
            }
        }
        summary.crossed = days.count
        if days.count >= FleetVersionSummary.minimumForMedian {
            let sorted = days.sorted()
            summary.median = nearestRank(50, of: sorted)
            summary.p90 = nearestRank(90, of: sorted)
        }
        return summary
    }

    /// Nearest-rank percentile of an ascending list: the value at rank ceil(p/100 × n).
    static func nearestRank(_ percentile: Double, of sorted: [Int]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
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

// MARK: - Version history types

/// One stretch of days during which Jamf reported one version as a title's latest.
struct VersionWindow: Sendable {
    /// English, used as-is in the workbook and HTML report and shown through `LShown` on screen.
    enum Outcome: String, Sendable, CaseIterable {
        case crossed = "Reached 90%"
        case alreadyAt90 = "Already at 90%"
        case superseded = "Superseded before 90%"
        case open = "Not yet at 90%"

        var label: String { rawValue }
    }

    let start: Date
    /// The day another version took over; nil while the window is open.
    let end: Date?
    let series: [(date: Date, adoptionPct: Double)]
    let releaseDate: Date?
    let daysTo50: Int?
    let daysTo90: Int?

    /// From the series alone: the release date only feeds the days-to figures.
    var outcome: Outcome {
        guard let first = series.first else { return end == nil ? .open : .superseded }
        if first.adoptionPct >= 90 { return .alreadyAt90 }
        if crossedAt90 != nil { return .crossed }
        return end == nil ? .open : .superseded
    }

    /// The first day of the window at or above 90%, when the window started below it.
    var crossedAt90: Date? {
        guard let first = series.first, first.adoptionPct < 90 else { return nil }
        return series.first(where: { $0.adoptionPct >= 90 })?.date
    }
}

/// One version of one title, with each window it was the latest.
struct VersionVelocity: Sendable, Identifiable {
    let titleId: String
    let title: String
    let version: String
    let releaseDate: Date?
    var windows: [VersionWindow]

    var id: String { titleId + "|" + version }
}

/// Days to 90% across titles over a period, counted in windows. The median and 90th
/// percentile cover crossed windows with a release date only, and need at least five.
struct FleetVersionSummary: Sendable, Equatable {
    static let minimumForMedian = 5

    var median: Int?
    var p90: Int?
    var crossed = 0
    var superseded = 0
    var notYet = 0
    var alreadyAt90 = 0
    var noReleaseDate = 0
    /// The period the figures cover, so a list beside them uses the same bounds.
    var since: Date?
    var now: Date?
}
