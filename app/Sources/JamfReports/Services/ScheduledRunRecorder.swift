import Foundation

/// Writes the per-run artifacts that Run History and the Schedules screen read.
///
/// The headless `--scheduled-run` path (invoked by both launchd and the GUI's
/// "Run now" button) historically wrote its output only to
/// `~/Library/Logs/JamfReports/<label>/` via launchd stdout redirection.
/// Neither `RunHistoryService` (which scans `<workspace>/automation/logs/`)
/// nor `LaunchAgentService.parse` (which reads
/// `<workspace>/automation/<label>_status.json`) ever sees those files, so
/// every native run was invisible: Run History stayed empty and Schedules
/// showed "Last Run —" with a default OK pill.
///
/// This recorder writes both artifacts:
/// - `<workspace>/automation/logs/<label>.<yyyyMMdd-HHmmss>.log` — one file
///   per run, picked up by `RunHistoryService.list`.
/// - `<workspace>/automation/<label>_status.json` — read by
///   `LaunchAgentService.parse` for the "Last Run" date and status pill.
///
/// Thread safety: log lines arrive from `@Sendable` stream callbacks; an
/// `NSLock` guards the file handle (same pattern as `LaunchAgentWriter`).
final class ScheduledRunRecorder: @unchecked Sendable {

    /// Per-run log files beyond this count are pruned, oldest first. Only
    /// files matching this recorder's `<label>.<timestamp>.log` pattern are
    /// pruned — legacy `.out.log` / `.err.log` files are never touched.
    static let maxRunLogs = 50

    let logURL: URL
    let statusURL: URL

    private let lock = NSLock()
    private var handle: FileHandle?
    private let started: Date
    private let label: String

    /// Returns nil when the automation directories cannot be created or the
    /// log file cannot be opened — the run proceeds without recording rather
    /// than failing.
    init?(workspace: URL, label: String, now: Date = Date()) {
        self.started = now
        self.label = label

        let automationDir = workspace.appendingPathComponent("automation", isDirectory: true)
        let logsDir = automationDir.appendingPathComponent("logs", isDirectory: true)
        let fm = FileManager.default
        do {
            // 0o700: run logs contain device serials, hostnames, and usernames.
            try fm.createDirectory(
                at: logsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        let stamp = Self.timestamp(from: now)
        self.logURL = logsDir.appendingPathComponent("\(label).\(stamp).log")
        self.statusURL = automationDir.appendingPathComponent("\(label)_status.json")

        // 0600 atomically at create — same contract as LaunchAgentWriter.appendHandle.
        guard fm.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ), let fh = try? FileHandle(forWritingTo: logURL) else {
            return nil
        }
        self.handle = fh
        record("[info] run started \(ISO8601DateFormatter().string(from: now)) for \(label)")
    }

    /// Append one line to the per-run log.
    func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, let data = (text + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    /// Write the exit footer + status JSON, close the log, prune old run logs.
    ///
    /// `artifacts` are output files the run produced (workbook, HTML, CSV);
    /// they map to the `xlsx_report_path` / `html_report_path` /
    /// `inventory_csv_path` keys `LaunchAgentService.artifactLabels` reads.
    func finish(exitCode: Int32, artifacts: [URL] = []) {
        let seconds = max(0, Int(Date().timeIntervalSince(started).rounded()))
        record("[info] exit \(exitCode) after \(seconds)s")

        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()

        writeStatusJSON(exitCode: exitCode, artifacts: artifacts)
        Self.pruneRunLogs(in: logURL.deletingLastPathComponent(), keep: Self.maxRunLogs)
    }

    // MARK: - Status JSON

    private func writeStatusJSON(exitCode: Int32, artifacts: [URL]) {
        var payload: [String: Any] = [
            "finished_at": ISO8601DateFormatter().string(from: Date()),
            "success": exitCode == 0,
            "exit_code": Int(exitCode),
            "label": label,
        ]
        for url in artifacts {
            switch url.pathExtension.lowercased() {
            case "xlsx": payload["xlsx_report_path"] = url.path
            case "html": payload["html_report_path"] = url.path
            case "csv": payload["inventory_csv_path"] = url.path
            default: break
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }

        let fm = FileManager.default
        let tempURL = statusURL.deletingLastPathComponent()
            .appendingPathComponent(".\(statusURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: tempURL.path
            )
            if !fm.fileExists(atPath: statusURL.path) {
                fm.createFile(
                    atPath: statusURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
                )
            }
            _ = try fm.replaceItemAt(statusURL, withItemAt: tempURL)
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }

    // MARK: - Naming + pruning

    static func timestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Matches `<anything>.<yyyyMMdd-HHmmss>.log` — only files this recorder wrote.
    static func isRecorderLogName(_ name: String) -> Bool {
        name.range(of: #"\.\d{8}-\d{6}\.log$"#, options: .regularExpression) != nil
    }

    /// Delete recorder-written run logs beyond the newest `keep`. Files not
    /// matching the recorder naming pattern are never touched.
    static func pruneRunLogs(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let runLogs = entries
            .filter { isRecorderLogName($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        guard runLogs.count > keep else { return }
        for url in runLogs.dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
    }
}
