import Foundation

extension ReportEngine {

    static let schoolBackfillMaxDays = 400
    /// In the `state` folder; present once a workspace's backfill has run to the end.
    static let schoolBackfillMarker = "school-history-backfill.done"

    /// The one-time School history backfill, run at the start of `schoolCollect`. The marker is
    /// the only cost of a later run. `staleDays` is asked for only when a pass will run. A
    /// refused `state` folder warns and skips the pass, so nothing repeats on every collect.
    static func backfillSchoolHistoryOnce(
        dataDir: URL, summariesDir: URL, staleDays: () -> Int, now: Date = Date(),
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        guard let stateDir = WorkspacePaths.confinedFolderOrWarn(
            ["state"], under: dataDir, onLine: onLine) else { return }
        let marker = stateDir.appendingPathComponent(schoolBackfillMarker)
        guard BoundedFile.stateText(marker) == nil else { return }
        let result = backfillSchoolSummaries(
            dataDir: dataDir, summariesDir: summariesDir, staleDays: staleDays(), now: now,
            onLine: onLine)
        guard result.writeFailures == 0 else { return }  // the next collect tries again
        do {
            try FileManager.default.createDirectory(
                at: stateDir, withIntermediateDirectories: true)
            try Data(SummaryJSONParser.dateFormatter.string(from: now).utf8)
                .write(to: marker, options: .atomic)
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] School history backfill marker not written: "
                    + "\(error.localizedDescription)"))
        }
        if result.written > 0 {
            onLine(.init(timestamp: Date(), level: .info,
                text: "[info] backfilled \(result.written) days of Jamf School history"))
        }
    }

    /// Writes `summary_<day>.json` for each local day (newest first, at most
    /// `schoolBackfillMaxDays` days with a snapshot) that has a `school-devices` snapshot and no
    /// summary, from the day's newest snapshot that decodes, judged as of its own stamp. Never
    /// replaces a summary. Conflict copies and manifests are not candidates; snapshots that do
    /// not decode are counted in one `[warn]`. OS currency is left out: the cached SOFA feed is
    /// today's, and an old version list judged against it would read as behind. A snapshot
    /// stamped on a day after `now`'s is skipped and counted in one `[warn]`.
    static func backfillSchoolSummaries(
        dataDir: URL, summariesDir: URL, staleDays: Int, now: Date = Date(),
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> (written: Int, writeFailures: Int) {
        let kind = SchoolFleetService.devicesKind
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let files = (FileManager.snapshotFolderEntries(in: dir, includingPropertiesForKeys: nil) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter(FileManager.isSelectableSnapshot)
            .compactMap { url in
                CloudStorage.snapshotTimestamp(of: url).map { (url: url, date: $0) }
            }
            .sorted { $0.date > $1.date }

        let today = SummaryJSONParser.dateFormatter.string(from: now)
        var daysSeen: Set<String> = []
        var written = 0, writeFailures = 0, undecodable = 0, futureDated = 0
        for file in files {
            let day = SummaryJSONParser.dateFormatter.string(from: file.date)
            // yyyy-MM-dd orders as text; a future day would sit in Trends ahead of today.
            if day > today {
                futureDated += 1
                continue
            }
            if daysSeen.contains(day) { continue }
            let target = summariesDir.appendingPathComponent("summary_\(day).json")
            if FileManager.default.fileExists(atPath: target.path) {
                daysSeen.insert(day)
                continue
            }
            guard let snapshot = SchoolFleetService.devicesSnapshot(at: file.url, inside: dataDir) else {
                undecodable += 1
                continue
            }
            if daysSeen.count >= schoolBackfillMaxDays { break }
            daysSeen.insert(day)
            guard let summary = schoolSummary(
                from: snapshot, date: day, staleDays: staleDays, now: file.date,
                collectionSources: [kind: "live"], collectedByHost: nil) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: summariesDir, withIntermediateDirectories: true)
            } catch {
                writeFailures += 1
                continue
            }
            if writeSummaryFile(summary, to: target, onLine: nil) {
                written += 1
            } else {
                writeFailures += 1
            }
        }
        if undecodable > 0 {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] School history backfill skipped \(undecodable) "
                    + "school-devices snapshot(s) that could not be read"))
        }
        if futureDated > 0 {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] skipped \(futureDated) future-dated school-devices snapshot(s)"))
        }
        return (written, writeFailures)
    }
}
