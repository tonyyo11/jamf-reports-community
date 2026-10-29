import Foundation

/// Emits a consolidated fleet report (CSV) for a `ReportGroup` from each
/// member profile's trend summaries (v2.2.0 Phase 4).
///
/// The CSV is the consolidated report's first form: aggregated KPIs with
/// period-over-period delta columns. A full multi-sheet consolidated workbook
/// is a future enrichment; the CSV reuses the already-collected summaries and
/// is what the scheduled reports run and the Automation UI emit.
///
/// Cell values are fixed metric labels + numbers (no per-device user data), so
/// the CSV is formula-injection-safe by construction; the user-provided group
/// name only appears in the filename (sanitized by `ExportNaming`).
enum FleetReportEmitter {

    /// Shared output dir for consolidated reports — `_fleet-reports` under the
    /// workspaces root. The leading underscore is an invalid profile slug, so
    /// it never collides with profile discovery. Throws when the folder is a symbolic link,
    /// which a peer on a shared root could plant to redirect the reports.
    static func consolidatedDir() throws -> URL {
        try WorkspacePaths.confinedFolder(
            ["_fleet-reports"], under: ProfileService.workspacesRoot())
    }

    static let logFileName = "fleet-reports.log"

    /// Appends one timestamped line to `<dir>/fleet-reports.log` without following a link at
    /// that name (`O_NOFOLLOW`), emptying the file first when it is over `maxBytes`.
    static func appendLog(_ message: String, in dir: URL, maxBytes: Int = 1_048_576) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(logFileName).path
        // O_NONBLOCK so opening a FIFO planted at the name returns instead of waiting for a
        // reader; the type check then refuses anything but a regular file.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                      0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw POSIXError(.EFTYPE)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        if Int(info.st_size) > maxBytes { _ = ftruncate(fd, 0) }
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        // write(contentsOf:), not write(_:): the latter raises on failure, which Swift cannot
        // catch. On a synced workspace the write really can fail.
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    }

    /// CSV text for a rollup: `Metric,Current,Previous,Delta`. Pure — testable.
    static func csv(for rollup: FleetRollup) -> String {
        var lines = ["Metric,Current,Previous,Delta"]
        for metric in rollup.metrics {
            // The label is text; the figures are the app's own number formats, which a delta's
            // sign must not be guarded out of.
            lines.append([
                StaleDeviceService.csvField(metric.label),
                format(metric.value, unit: metric.unit),
                format(metric.previous, unit: metric.unit),
                formatDelta(metric.delta, unit: metric.unit),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Prior-period summary for deltas: the newest summary at least
    /// `lookbackDays` older than the current (last) summary, falling back to the
    /// immediately-prior summary. nil when fewer than two summaries exist.
    static func priorSummary(_ summaries: [DailySummary], lookbackDays: Int) -> DailySummary? {
        guard summaries.count >= 2, let current = summaries.last else { return nil }
        let cutoff = current.parsedDate.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let older = summaries.dropLast().filter { $0.parsedDate <= cutoff }
        return older.last ?? summaries[summaries.count - 2]
    }

    /// Build the rollup for a group from per-profile summary lists (each sorted
    /// oldest→newest as `SummaryJSONParser.parseDirectory` returns). Pure.
    static func rollup(
        for group: ReportGroup,
        summariesByProfile: [[DailySummary]],
        lookbackDays: Int
    ) -> FleetRollup? {
        let nonEmpty = summariesByProfile.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let current = nonEmpty.compactMap { $0.last }
        let previous = nonEmpty.compactMap { priorSummary($0, lookbackDays: lookbackDays) }
        return FleetRollup.compute(groupName: group.name, current: current, previous: previous)
    }

    /// Load a group's summaries, compute the rollup, and write the consolidated
    /// CSV. Returns the written URL, or nil when no member profile has data.
    /// `summariesFor` is injectable for tests.
    @discardableResult
    static func emit(
        group: ReportGroup,
        lookbackDays: Int,
        timestamp: String,
        outputDir: URL? = nil,
        summariesFor: (String) -> [DailySummary] = defaultSummaries
    ) throws -> URL? {
        let lists = group.profiles.map(summariesFor)
        guard let rollup = rollup(for: group, summariesByProfile: lists, lookbackDays: lookbackDays) else {
            return nil
        }
        let dir = try outputDir ?? consolidatedDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = "fleet-\(ExportNaming.sanitize(group.name))"
        let url = dir.appendingPathComponent("\(stem)-\(timestamp).csv")
        try csv(for: rollup).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Default loader: read `<profile>/…/summaries/summary_*.json`.
    static func defaultSummaries(_ profile: String) -> [DailySummary] {
        TrendStore.readSummaries(profile: profile)
    }

    // MARK: - Formatting

    /// Shared with `FleetWorkbookEmitter` — one Current/Previous formatting rule.
    static func format(_ value: Double?, unit: FleetRollup.Unit) -> String {
        guard let value else { return "—" }
        switch unit {
        case .count:   return String(Int(value.rounded()))
        case .percent: return String(format: "%.1f%%", value)
        }
    }

    /// Shared with `FleetWorkbookEmitter` — one Δ formatting rule.
    static func formatDelta(_ delta: Double?, unit: FleetRollup.Unit) -> String {
        guard let delta else { return "—" }
        let sign = delta > 0 ? "+" : ""
        switch unit {
        case .count:   return "\(sign)\(Int(delta.rounded()))"
        case .percent: return "\(sign)\(String(format: "%.1f", delta))pp"
        }
    }
}
