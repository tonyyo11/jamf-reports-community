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
        guard ProfileService.isValid(profile) else { return [] }
        let logsDir = logDirectory(for: profile)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let safeDirPath = logsDir.resolvingSymlinksInPath().path

        return entries
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> RunSummary? in
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(safeDirPath) else { return nil }

                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let label = url.deletingPathExtension().lastPathComponent
                let (exitCode, duration) = parseLogTail(from: url)
                let status: Schedule.LastStatus
                if let code = exitCode {
                    status = code == 0 ? .ok : .fail
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
        for raw in text.components(separatedBy: "\n") where !raw.isEmpty {
            lines.append(.init(timestamp: Date(), level: classifyLine(raw), text: raw))
        }
        return lines
    }

    // MARK: - Private

    private static func logDirectory(for profile: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports/\(profile)/automation/logs")
    }

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

    /// Convert a plist label like `com.tonyyo.jrc.profile.daily-snapshot` → `"Daily Snapshot"`.
    private static func humanName(from label: String) -> String {
        let prefix = "com.tonyyo.jrc."
        guard label.hasPrefix(prefix) else { return label }
        let tail = String(label.dropFirst(prefix.count))
        guard let dot = tail.firstIndex(of: ".") else { return tail }
        let slug = String(tail[tail.index(after: dot)...])
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// Read the last 1 KB of a log to infer exit code and duration.
    private static func parseLogTail(from url: URL) -> (Int32?, String?) {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return (nil, nil) }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        let readSize = min(fileSize, 1024)
        fh.seek(toFileOffset: fileSize - readSize)
        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var hasFatal = false
        var duration: String? = nil
        var exitCode: Int32? = nil

        for line in text.components(separatedBy: "\n").reversed() {
            let l = line.lowercased()
            if l.contains("[fatal]") || l.contains("[error]") { hasFatal = true }
            if exitCode == nil {
                if l.contains("exit 0") { exitCode = 0; break }
                if l.contains("exit 1") { exitCode = 1; break }
            }
            if duration == nil,
               let r = line.range(of: #"\d+m \d+s|\d+s"#, options: .regularExpression) {
                duration = String(line[r])
            }
        }
        return (exitCode ?? (hasFatal ? 1 : 0), duration)
    }

    private static func classifyLine(_ line: String) -> CLIBridge.LogLevel {
        let l = line.lowercased()
        if l.contains("[ok]")    { return .ok }
        if l.contains("[warn]")  { return .warn }
        if l.contains("[fatal]") || l.contains("[error]") || l.contains("traceback") { return .fail }
        return .info
    }
}
