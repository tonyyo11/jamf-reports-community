import Foundation

/// The demo workspace as the admin screens see it — Automation, Run History,
/// Data Sources and Settings — in place of this Mac's own workspace, schedules
/// and jamf-cli. Every value is fixed and dated on or before `referenceDate`;
/// nothing here reads the disk or runs jamf-cli.
extension DemoData {

    /// The tooltip on a control demo mode disables because it would read or
    /// write the real workspace, run jamf-cli or open a real path.
    static let liveOnlyHelp = "Available with a live profile"

    // MARK: - Workspace paths

    /// Where demo screens say the workspaces live. A live screen shows this
    /// Mac's root, which may have been moved to a team folder.
    static let workspacesRootDisplay = "~/Jamf-Reports"

    /// A demo profile's workspace, printed the way a live screen prints one
    /// (`WorkspaceRootStore.displayPath(profile:subpath:)`).
    static func workspaceDisplayPath(profile: String, subpath: String = "") -> String {
        let base = "\(workspacesRootDisplay)/\(profile)"
        return subpath.isEmpty ? base : "\(base)/\(subpath)"
    }

    // MARK: - Run History

    /// One demo Run History entry: the row the list shows and the log it opens.
    struct RunLog: Sendable {
        let summary: RunHistoryService.RunSummary
        let lines: [CLIBridge.LogLine]
    }

    /// A demo profile's Run History, newest first. Each schedule's newest run
    /// is the one `scheduledRuns` reports as its Last Run, status included; a
    /// profile with no schedules has none.
    static func runHistory(for profile: String) -> [RunLog] {
        runPlan
            .filter { $0.schedule.profile == profile }
            .map(runLog)
            .sorted { $0.summary.date > $1.summary.date }
    }

    /// A run's schedule, start and length. `recordedExit` is false for a run
    /// that stopped before it wrote its exit line, which Run History reads as
    /// WARN.
    private struct PlannedRun: Sendable {
        let schedule: Schedule
        let start: Date
        let seconds: Int
        let recordedExit: Bool

        var finished: Date { start.addingTimeInterval(TimeInterval(seconds)) }
    }

    private static let runPlan: [PlannedRun] = [
        // meridian-prod, the week to Apr 25: the daily snapshot every morning,
        // the iPad inventory each weekday and the executive report on Monday.
        // Ends at 06:01:00, the demo's "now" (`referenceDate`); a run can't end later.
        planned("Daily Snapshot Collection", month: 4, day: 25, at: (6, 0, 3), seconds: 57),
        planned("Mobile Inventory (iPad)", month: 4, day: 24, at: (7, 30, 2), seconds: 188,
                recordedExit: false),
        planned("Daily Snapshot Collection", month: 4, day: 24, at: (6, 0, 4), seconds: 61),
        planned("Mobile Inventory (iPad)", month: 4, day: 23, at: (7, 30, 2), seconds: 70),
        planned("Daily Snapshot Collection", month: 4, day: 23, at: (6, 0, 5), seconds: 59),
        planned("Mobile Inventory (iPad)", month: 4, day: 22, at: (7, 30, 1), seconds: 73),
        planned("Daily Snapshot Collection", month: 4, day: 22, at: (6, 0, 3), seconds: 62),
        planned("Mobile Inventory (iPad)", month: 4, day: 21, at: (7, 30, 2), seconds: 69),
        planned("Daily Snapshot Collection", month: 4, day: 21, at: (6, 0, 4), seconds: 60),
        planned("Mobile Inventory (iPad)", month: 4, day: 20, at: (7, 30, 1), seconds: 71),
        planned("Weekly Executive Report", month: 4, day: 20, at: (7, 0, 2), seconds: 124),
        planned("Daily Snapshot Collection", month: 4, day: 20, at: (6, 0, 3), seconds: 57),
        // meridianedu's monthly brief and meridian-sandbox's quarterly pull.
        planned("Monthly Compliance Brief", month: 4, day: 1, at: (6, 0, 5), seconds: 843),
        planned("Monthly Compliance Brief", month: 3, day: 1, at: (6, 0, 4), seconds: 802),
        planned("Quarterly Audit Pull", month: 1, day: 1, at: (6, 0, 4), seconds: 671),
        planned("Quarterly Audit Pull", year: 2025, month: 10, day: 1, at: (6, 0, 3),
                seconds: 655),
    ].compactMap { $0 }

    private static func planned(
        _ name: String, year: Int = 2026, month: Int, day: Int, at time: (Int, Int, Int),
        seconds: Int, recordedExit: Bool = true
    ) -> PlannedRun? {
        guard let schedule = scheduledRuns.first(where: { $0.name == name }),
              let start = Calendar(identifier: .gregorian).date(from: DateComponents(
                  year: year, month: month, day: day,
                  hour: time.0, minute: time.1, second: time.2))
        else { return nil }
        return PlannedRun(
            schedule: schedule, start: start, seconds: seconds, recordedExit: recordedExit)
    }

    /// The row and log a real run of the same schedule would leave: named like
    /// `ScheduledRunRecorder`'s files, listed at the log's last write.
    private static func runLog(_ run: PlannedRun) -> RunLog {
        let label = LaunchAgentWriter.label(for: run.schedule) ?? run.schedule.name
        // Display only: demo mode never reads it. It sits where the demo's
        // paths say the workspace is, not under this Mac's real root.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports", isDirectory: true)
            .appendingPathComponent(run.schedule.profile, isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(label).\(stamp(run.start, "yyyyMMdd-HHmmss")).log")
        let summary = RunHistoryService.RunSummary(
            logURL: logURL,
            label: label,
            name: run.schedule.name,
            date: run.finished,
            exitCode: run.recordedExit ? 0 : nil,
            status: run.recordedExit ? .ok : .warn,
            duration: run.recordedExit ? "\(run.seconds)s" : nil
        )
        let lines = logText(run, label: label).map { text in
            CLIBridge.LogLine(timestamp: run.finished, level: .from(line: text), text: text)
        }
        return RunLog(summary: summary, lines: lines)
    }

    /// The log lines, in the formats `ScheduledRunRecorder`, `ReportEngine`
    /// and the scheduled-run path write.
    private static func logText(_ run: PlannedRun, label: String) -> [String] {
        let profile = run.schedule.profile
        var lines = [
            "[info] run started \(ISO8601DateFormatter().string(from: run.start)) for \(label)",
        ]
        guard run.recordedExit else {
            lines.append(contentsOf: staleMobileCacheWarnings)
            return lines
        }
        switch run.schedule.mode {
        case .snapshotOnly:
            lines.append(contentsOf: collectLines(refreshKinds, profile: profile))
            lines.append(contentsOf: feedLines(profile: profile))
            lines.append(summaryWritten(run.start))
            lines.append(contentsOf: collectLines(protectKinds, profile: profile))
            lines.append("[ok] scheduled snapshot complete for '\(profile)' — Trends updated")
        case .csvAssisted:
            // The morning's snapshot already collected the refresh tier.
            lines.append(contentsOf: collectLines(inventoryKinds, profile: profile))
            lines.append(contentsOf: collectLines(scanKinds, profile: profile))
            lines.append("[info] summary_\(stamp(run.start, "yyyy-MM-dd")).json already "
                + "exists — leaving existing file in place")
            lines.append(reportWritten(run))
        case .jamfCLIFull:
            lines.append(contentsOf: collectLines(refreshKinds, profile: profile))
            lines.append(contentsOf: feedLines(profile: profile))
            lines.append(contentsOf: collectLines(inventoryKinds, profile: profile))
            lines.append(contentsOf: collectLines(scanKinds, profile: profile))
            lines.append(summaryWritten(run.start))
            lines.append(reportWritten(run))
        case .jamfCLIOnly:
            lines.append(reportWritten(run))
        case .backup:
            lines.append("[ok] scheduled backup complete for '\(profile)'")
        }
        lines.append("[info] exit 0 after \(run.seconds)s")
        return lines
    }

    /// The Apr 24 iPad run's log. It rendered from mobile snapshots only
    /// Monday's executive report collects, then stopped before its exit line.
    private static let staleMobileCacheWarnings = [
        "[warn] mobile-devices-list: newest cached snapshot is from Apr 20 — 4 days old",
        "[warn] mobile-device-inventory-details: newest cached snapshot is from Apr 20 "
            + "— 4 days old",
    ]

    private static let refreshKinds = [
        "overview", "security", "inventory-summary", "patch-status", "policy-status", "audit",
    ]
    private static let inventoryKinds = [
        "computers", "mobile-devices-list", "mobile-device-inventory-details", "ea-results",
        "app-status", "update-status",
    ]
    private static let scanKinds = ["patch-device-failures", "update-device-failures"]
    private static let protectKinds = [
        "protect-overview", "protect-alerts", "protect-computers", "protect-insights",
        "protect-plans",
    ]

    private static let snapshotBytes: [String: Int] = [
        "overview": 18_422, "security": 412_880, "inventory-summary": 9_310,
        "patch-status": 22_614, "policy-status": 58_102, "audit": 31_447,
        "computers": 2_914_336, "mobile-devices-list": 48_210,
        "mobile-device-inventory-details": 162_904, "ea-results": 1_204_418,
        "app-status": 88_120, "update-status": 14_632, "patch-device-failures": 18_872,
        "update-device-failures": 21_406, "protect-overview": 2_140, "protect-alerts": 36_518,
        "protect-computers": 128_774, "protect-insights": 44_203, "protect-plans": 6_912,
    ]

    private static func collectLines(_ kinds: [String], profile: String) -> [String] {
        kinds.flatMap { kind in
            [
                "[info] collecting \(kind) for \(profile)",
                "[ok] \(kind): \(snapshotBytes[kind] ?? 4_096) bytes",
            ]
        }
    }

    private static func feedLines(profile: String) -> [String] {
        [
            "[info] collecting sofa for \(profile)",
            "[ok] sofa: feeds refreshed",
            "[info] collecting patch-release-dates for \(profile)",
            "[ok] patch-release-dates: \(patchTitleSummary.count) title(s)",
        ]
    }

    private static func summaryWritten(_ day: Date) -> String {
        "[ok] wrote summary_\(stamp(day, "yyyy-MM-dd")).json — trend chart and "
            + "StaleDataBanner will reflect this run"
    }

    /// The report a generate run wrote, stamped just before the run finished.
    private static func reportWritten(_ run: PlannedRun) -> String {
        let written = stamp(run.finished.addingTimeInterval(-11), "yyyy-MM-dd_HHmmss")
        let profile = run.schedule.profile
        return "[ok] scheduled run complete for '\(profile)': report_\(profile)_\(written).xlsx"
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: - Diagnostic log

    /// Settings → Logging's events in demo mode, oldest first: the demo org's
    /// newest run, the collect Run History lists, spread over its length so the
    /// last line lands when the run ended. The real buffer holds this Mac's
    /// session, which a demo screen never shows.
    static let diagnosticEvents: [LogEntry] = {
        guard let run = runPlan
            .filter({ $0.schedule.profile == org.profile })
            .max(by: { $0.start < $1.start })
        else { return [] }
        let label = LaunchAgentWriter.label(for: run.schedule) ?? run.schedule.name
        let lines = logText(run, label: label)
        let step = TimeInterval(run.seconds) / TimeInterval(max(lines.count - 1, 1))
        return lines.enumerated().map { index, text in
            LogEntry(
                date: run.start.addingTimeInterval(step * TimeInterval(index)),
                category: "collect",
                level: LogEntry.Level(CLIBridge.LogLevel.from(line: text)),
                message: text)
        }
    }()

    // MARK: - Data Sources

    /// When a demo profile last wrote one of the Data Sources card's caches:
    /// the start of its newest run whose log collects that kind, so the card
    /// and Run History agree. The daily snapshot writes the refresh tier and
    /// Jamf Protect; a report run collects the inventory tier. Nil for a cache
    /// no run has written.
    static func cacheDate(for cacheNames: [String], profile: String) -> Date? {
        guard let name = cacheNames.first else { return nil }
        let modes: Set<Schedule.RunMode>
        if inventoryCaches.contains(name) {
            modes = [.csvAssisted, .jamfCLIFull]
        } else if name == "protect-overview" {
            modes = [.snapshotOnly]
        } else {
            modes = [.snapshotOnly, .jamfCLIFull]
        }
        return runPlan
            .filter { $0.schedule.profile == profile && modes.contains($0.schedule.mode) }
            .map { $0.start.addingTimeInterval(20) }
            .max()
    }

    private static let inventoryCaches: Set<String> = [
        "computers", "ea-results", "app-status", "update-status",
    ]

    /// A demo profile's csv-inbox: the export a CSV-assisted schedule runs
    /// from — meridian-prod's executive report, dropped the morning of its Apr
    /// 20 run — or nothing for a profile without one.
    static func inboxFiles(for profile: String) -> [InboxFile] {
        let needsCSV = scheduledRuns.contains { $0.profile == profile && $0.mode == .csvAssisted }
        guard needsCSV else { return [] }
        let name = "meridian-computers-2026-04-20.csv"
        let dropped = Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2026, month: 4, day: 20, hour: 6, minute: 48)) ?? referenceDate
        return [
            InboxFile(name: name, relativePath: name, size: FileDisplay.size(638_976),
                      mtime: dropped, status: .pending),
        ]
    }

    /// A demo profile's snapshot families: the daily summaries its collects
    /// wrote, the newest by its latest collect. meridian-prod has as many as
    /// its trend history has points, another profile one per collect in its
    /// Run History, and a profile nothing has collected for none.
    static func snapshotFamilies(for profile: String) -> [SnapshotFamily] {
        let collects = runPlan.filter {
            $0.schedule.profile == profile && $0.schedule.mode != .jamfCLIOnly
                && $0.schedule.mode != .backup
        }
        guard let latest = collects.map(\.finished).max() else { return [] }
        let count = profile == org.profile ? trendDates.count : collects.count
        return [
            SnapshotFamily(
                name: "summaries", glob: "*summary*.json", snapshotCount: count,
                latestDate: latest, totalBytes: Int64(count) * 6_144,
                usedBy: "Trends · Overview score cards"),
        ]
    }

    /// The Data Sources command matrix: every command the app tracks,
    /// available. No version is claimed, since no jamf-cli ran.
    static let jamfCLICapabilities = CLICapabilitySnapshot(
        version: nil,
        availability: Dictionary(
            CapabilityService.trackedCommands.map { ($0, CommandAvailability.available) },
            uniquingKeysWith: { first, _ in first })
    )

    // MARK: - Settings and the toolbar

    /// Shown where a live screen names this Mac's jamf-cli: demo mode never
    /// runs it, so it claims no version or path.
    static let jamfCLINote = "Not used in demo mode"

    /// What Settings' token probe would have found for each demo connection:
    /// a token issued at `referenceDate`, valid for 30 minutes. A connection in
    /// error is not probed, as on a live Mac.
    static func tokenStatuses(for profiles: [JamfCLIProfile]) -> [String: TokenStatus] {
        var statuses: [String: TokenStatus] = [:]
        for profile in profiles where profile.status != .error {
            statuses[profile.name] = TokenStatus.make(
                profile: profile.name, token: "demo",
                expiresAt: referenceDate.addingTimeInterval(30 * 60), raw: "")
        }
        return statuses
    }
}
