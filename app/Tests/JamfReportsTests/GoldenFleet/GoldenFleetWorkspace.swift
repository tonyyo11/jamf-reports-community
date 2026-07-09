import Foundation
@testable import JamfReports

// MARK: - Golden fleet correctness harness — builder

/// Deterministic clock for the golden fleet. Every synthetic timestamp is
/// derived from a single `anchor` instant that is normalized to LOCAL noon, so
/// day-difference arithmetic (`daysBehind`, `daysToThreshold`) is an exact
/// integer offset in ANY timezone.
///
/// Two invariants make the whole suite timezone-independent:
///
/// 1. The anchor is local noon. A release/snapshot at `dayOffset` is also local
///    noon of that day, so `Calendar.current.dateComponents([.day], …)` between
///    any two of them equals their offset difference — no DST or wall-clock drift.
/// 2. Snapshot filenames are formatted with the SAME formatter settings the
///    engine's `MSCPChartDataBuilder.dateFromSnapshotFilename` parses them back
///    with (`yyyyMMdd'T'HHmmss`, `en_US_POSIX`, no explicit timezone → local),
///    so a `stamp → parse` round-trip is the identity instant.
enum GoldenFleetClock {

    /// Local noon of the calendar day that contains `reference`. All other
    /// synthetic times are offsets from this.
    static func anchorNoon(from reference: Date = Date()) -> Date {
        timestamp(dayOffset: 0, hour: 12, minute: 0, relativeTo: reference)
    }

    /// A wall-clock instant `dayOffset` days from `anchor` at `hour:minute`
    /// (LOCAL time). Built via explicit y/m/d + h/m components so a DST
    /// transition never shifts the wall clock.
    static func timestamp(
        dayOffset: Int, hour: Int, minute: Int, second: Int = 0, relativeTo anchor: Date
    ) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: dayOffset, to: anchor)!
        var comps = cal.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return cal.date(from: comps)!
    }

    /// Snapshot-filename timestamp, byte-identical to what
    /// `ReportEngine.saveSnapshot` writes and `dateFromSnapshotFilename` parses.
    static func stamp(_ date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    /// `summary.json` day string (`yyyy-MM-dd`) as `SummaryJSONParser` reads it.
    static func daySummaryString(_ date: Date) -> String {
        SummaryJSONParser.dateFormatter.string(from: date)
    }

    /// ISO-8601 with the LOCAL timezone offset. `SOFAFeedService.parseSOFADate`
    /// (`.withInternetDateTime`) reconstructs the exact instant, so a
    /// release-date round-trip preserves the local-noon wall clock and keeps
    /// day arithmetic exact.
    static func isoLocal(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // Matches MSCPChartDataBuilder.snapshotDateFormatter exactly (no explicit
    // timezone → renders in local time; parse side is likewise local).
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .iso8601)
        return f
    }()
}

/// Writes a complete, deterministic synthetic workspace to a temp dir. The only
/// component that WRITES files; the tests only read them back through the real
/// engine/readers and assert against hand-computed truth.
enum GoldenFleetWorkspace {

    // MARK: - Temp dirs

    /// A fresh, empty, created temp directory. Callers must remove it.
    static func freshRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Low-level writers

    static func writeJSON(_ obj: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: url)
    }

    static func writeRaw(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func setModificationDate(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Snapshot payload builders

    /// A `pro security report` summary section. When `filevaultPct` is nil the
    /// engine derives FileVault% from `filevault/total`, which is what Case A
    /// exercises.
    static func securitySummaryPayload(
        total: Int, filevault: Int, sip: Int, firewall: Int, gatekeeper: Int,
        filevaultPct: String? = nil
    ) -> [[String: Any]] {
        var data: [String: Any] = [
            "total_devices": total,
            "filevault_encrypted": filevault,
            "sip_enabled": sip,
            "firewall_enabled": firewall,
            "gatekeeper_enabled": gatekeeper,
        ]
        if let filevaultPct { data["filevault_encrypted_pct"] = filevaultPct }
        return [["section": "summary", "data": data]]
    }

    /// One `patch-status` row (all keys the strict decoder requires).
    static func patchRow(id: String, title: String, onLatest: Int, total: Int) -> [String: Any] {
        let pct = total > 0 ? Double(onLatest) / Double(total) * 100.0 : 0.0
        return [
            "title": title,
            "id": id,
            "on_latest": onLatest,
            "on_other": max(0, total - onLatest),
            "total": total,
            "latest": "1.0",
            "compliance_pct": String(format: "%.1f", pct),
        ]
    }

    /// Writes a `patch-status` snapshot file for one instant.
    static func writePatchStatus(
        dataDir: URL, at ts: Date, rows: [[String: Any]]
    ) throws {
        let url = dataDir.appendingPathComponent("patch-status", isDirectory: true)
            .appendingPathComponent("patch-status_\(GoldenFleetClock.stamp(ts)).json")
        try writeJSON(rows, to: url)
    }

    /// Writes a raw (possibly corrupt) `patch-status` file for one instant.
    static func writePatchStatusRaw(
        dataDir: URL, at ts: Date, raw: String
    ) throws {
        let url = dataDir.appendingPathComponent("patch-status", isDirectory: true)
            .appendingPathComponent("patch-status_\(GoldenFleetClock.stamp(ts)).json")
        try writeRaw(raw, to: url)
    }

    /// Writes an `ea-results` bare-array snapshot for one instant.
    static func writeEAResults(
        dataDir: URL, at ts: Date, rows: [[String: Any]]
    ) throws -> URL {
        let url = dataDir.appendingPathComponent("ea-results", isDirectory: true)
            .appendingPathComponent("ea-results_\(GoldenFleetClock.stamp(ts)).json")
        try writeJSON(rows, to: url)
        return url
    }

    /// Writes an `ea-results` file truncated mid-object (no trailing `]`), so the
    /// decoder must take its salvage path. Returns the count of COMPLETE objects
    /// (== the number of rows salvage should recover). Sized > 16 KB to mimic the
    /// real pipe-boundary truncation.
    @discardableResult
    static func writeTruncatedEAResults(
        dataDir: URL, at ts: Date, column: String, completeObjects n: Int
    ) throws -> Int {
        var s = "["
        for i in 0..<n {
            if i > 0 { s += "," }
            s += "{\"device\":\"mac-\(i)\",\"ea_name\":\"\(column)\",\"value\":0}"
        }
        // A final object that opens but never closes → the array is unterminated.
        // `lastDepth1ObjectEnd` finds object n-1's brace, so salvage keeps n rows.
        s += ",{\"device\":\"mac-partial\",\"ea_name\":\"\(column)\",\"value\":"
        let url = dataDir.appendingPathComponent("ea-results", isDirectory: true)
            .appendingPathComponent("ea-results_\(GoldenFleetClock.stamp(ts)).json")
        try writeRaw(s, to: url)
        return n
    }

    // MARK: - EA-results row helpers

    static func eaRow(device: String, ea: String, value: Any) -> [String: Any] {
        ["device": device, "ea_name": ea, "value": value]
    }
}
