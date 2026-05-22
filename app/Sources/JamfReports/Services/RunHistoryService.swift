import Foundation

/// Reads completed run logs from `~/Jamf-Reports/<profile>/automation/logs/*.log`.
///
/// All path operations canonicalize against the expected directory and verify the
/// result stays inside `~/Jamf-Reports/<profile>/automation/logs/` after symlink
/// resolution — preventing directory traversal via crafted filenames or symlinks.
enum RunHistoryService {

    struct RunSummary: Identifiable, Sendable {
        var id: String { logURL.lastPathComponent }
        let logURL: URL
        let label: String
        let name: String
        let date: Date
        let exitCode: Int32?
        let status: Schedule.LastStatus
        let duration: String?
    }

    // MARK: - List

    /// All run summaries for `profile`, newest first. Returns [] for invalid profiles.
    static func list(profile: String) -> [RunSummary] {
        guard let logsDir = try? WorkspacePaths.runHistoryDir(for: profile) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let safeDirPath = logsDir.resolvingSymlinksInPath().path
        let safeDirPrefix = safeDirPath + "/"

        return entries
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> RunSummary? in
                let resolved = url.resolvingSymlinksInPath()
                let resolvedPath = resolved.path
                guard resolvedPath == safeDirPath || resolvedPath.hasPrefix(safeDirPrefix) else {
                    return nil
                }

                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let label = url.deletingPathExtension().lastPathComponent
                let (exitCode, duration, logText) = parseLogTail(from: url)
                let status: Schedule.LastStatus
                if let code = exitCode {
                    if code == 0 && isPartialRun(logURL: url, logTailText: logText) {
                        status = .partial
                    } else {
                        status = code == 0 ? .ok : .fail
                    }
                } else {
                    status = .ok
                }
                return RunSummary(
                    logURL: resolved,
                    label: label,
                    name: humanName(from: label),
                    date: mtime,
                    exitCode: exitCode,
                    status: status,
                    duration: duration
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Load log

    /// Read `url` into classified log lines, capping at 5 MB (tail for larger files).
    /// Validates that the resolved path is inside `~/Jamf-Reports/<profile>/automation/logs/`.
    static func loadLog(_ url: URL) -> [CLIBridge.LogLine] {
        guard isInsideLogsDir(url) else { return [] }

        guard let fh = FileHandle(forReadingAtPath: url.resolvingSymlinksInPath().path) else {
            return []
        }
        defer { fh.closeFile() }

        let maxBytes: UInt64 = 5 * 1024 * 1024
        let fileSize = fh.seekToEndOfFile()
        var truncated = false

        if fileSize > maxBytes {
            truncated = true
            fh.seek(toFileOffset: fileSize - maxBytes)
        } else {
            fh.seek(toFileOffset: 0)
        }

        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else { return [] }

        var lines: [CLIBridge.LogLine] = []
        if truncated {
            lines.append(.init(timestamp: Date(), level: .warn, text: "[truncated — showing tail]"))
        }
        // Redact credential patterns before surfacing log lines to clipboard/file
        // exports or the Runs UI. jamf-cli should not echo secrets, but a future
        // debug-mode flag or upstream regression could; the on-disk file is left
        // untouched so admins still have the raw record for investigation.
        // Redact the whole text in one pass so multi-line patterns (e.g. a bearer
        // token split by a continuation line) are caught before splitting.
        let redactedText = LogRedactor.redact(text)
        for raw in redactedText.components(separatedBy: "\n") where !raw.isEmpty {
            lines.append(.init(
                timestamp: Date(),
                level: CLIBridge.LogLevel.from(line: raw),
                text: raw
            ))
        }
        return lines
    }

    // MARK: - Private

    /// Validate `url` resolves inside `~/Jamf-Reports/<valid-profile>/automation/logs/`.
    private static func isInsideLogsDir(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let reportsRoot = home.appendingPathComponent("Jamf-Reports")
            .resolvingSymlinksInPath()
        let resolved = url.resolvingSymlinksInPath()

        let prefix = reportsRoot.path + "/"
        guard resolved.path.hasPrefix(prefix) else { return false }

        let rest = String(resolved.path.dropFirst(prefix.count))
        let parts = rest.components(separatedBy: "/")
        // Expected: <profile>/automation/logs/<file>.log  → 4 components minimum
        return parts.count >= 4
            && ProfileService.isValid(parts[0])
            && parts[1] == "automation"
            && parts[2] == "logs"
    }

    /// Convert a plist/log label like
    /// `com.github.tonyyo11.jamf-reports-community.profile.daily-snapshot.out`
    /// to `"Daily Snapshot"`.
    private static func humanName(from label: String) -> String {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        guard label.hasPrefix(prefix) else { return label }
        let tail = String(label.dropFirst(prefix.count))
        guard let dot = tail.firstIndex(of: ".") else { return tail }
        var slug = String(tail[tail.index(after: dot)...])
        if slug.hasSuffix(".out") || slug.hasSuffix(".err") {
            slug = String(slug.dropLast(4))
        }
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// Read the last 1 KB of a log to infer exit code, duration, and tail text
    /// (returned for `isPartialRun` log-marker fallback).
    static func parseLogTail(from url: URL) -> (Int32?, String?, String) {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return (nil, nil, "") }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        let readSize = min(fileSize, 1024)
        fh.seek(toFileOffset: fileSize - readSize)
        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil, "") }

        var hasFatal = false
        var duration: String? = nil
        var parsedExitCode: Int32? = nil

        for line in text.components(separatedBy: "\n").reversed() {
            let level = CLIBridge.LogLevel.from(line: line)
            if level == .fail { hasFatal = true }
            if duration == nil,
               let r = line.range(of: #"\d+m \d+s|\d+s"#, options: .regularExpression) {
                duration = String(line[r])
            }
            if parsedExitCode == nil,
               let parsed = exitCode(from: line) {
                parsedExitCode = parsed
                if duration != nil { break }
            }
        }
        return (parsedExitCode ?? (hasFatal ? 1 : 0), duration, text)
    }

    /// Authoritative source: sibling `summary_<logFilename>.json` matching the
    /// log filename. Fallback: `[partial]` marker in the log tail.
    /// Path: log at `<workspace>/automation/logs/<ts>.log`, summary at
    /// `<workspace>/snapshots/computers/summaries/summary_<ts>.json`.
    ///
    /// PR-11 / threat-model T-12: per-LaunchAgent-run summary files
    /// (`summary_<logFilename>.json`) are now produced by the Python
    /// `_emit_per_log_summary_json` helper, called from `cmd_generate` when
    /// `per_log_summary_filename` is passed. `cmd_launchagent_run` derives
    /// that filename from the `status_file` argument.
    ///
    /// **Manifest discipline:** before trusting the `status` field, verify
    /// the file's SHA-256 against its sibling `manifest.json` (the same
    /// `_atomic_write_summary` writer pins the hash). On `.mismatch` or
    /// `.corrupt`, fall through to the `[partial]` log-marker scan rather
    /// than trusting an attacker-modifiable file — the file would have
    /// flipped an actual partial state to "ok" otherwise (T-12 attack
    /// scenario). On `.absent` (legacy snapshots or summaries that
    /// pre-date PR-11), trust the file content as before.
    static func isPartialRun(logURL: URL, logTailText: String) -> Bool {
        let logFilename = logURL.deletingPathExtension().lastPathComponent
        let workspace = logURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let summaryURL = workspace
            .appendingPathComponent("snapshots")
            .appendingPathComponent("computers")
            .appendingPathComponent("summaries")
            .appendingPathComponent("summary_\(logFilename).json")

        if FileManager.default.fileExists(atPath: summaryURL.path),
           let data = try? Data(contentsOf: summaryURL) {
            let verification = SnapshotManifest.verify(snapshot: summaryURL, data: data)
            // Trust only `.verified` (manifest hash matches) or `.absent`
            // (legacy pre-PR-11 — no manifest discipline to enforce). On
            // `.mismatch` (tampered after manifest write), `.corrupt`
            // (manifest unparseable), or `.omitted` (file not registered
            // in an existing manifest — security-reviewer 2nd pass M-01:
            // injection bypass since every legitimate PR-11 write
            // registers the file), fall back to the `[partial]` log
            // marker rather than trusting an attacker-modifiable signal.
            if verification == .verified || verification == .absent {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    return status == "partial"
                }
            }
        }

        return logTailText.contains("[partial]")
    }

    static func exitCode(from line: String) -> Int32? {
        guard let range = line.range(
            of: #"exit\s+(-?\d+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let match = String(line[range])
        guard let codeRange = match.range(of: #"-?\d+"#, options: .regularExpression),
              let value = Int32(match[codeRange]) else {
            return nil
        }
        return value
    }
}
