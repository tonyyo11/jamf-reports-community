import Foundation
import Darwin

/// Discovers Python-owned `~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist`
/// files and parses them into `Schedule` model objects.
enum LaunchAgentService {

    struct LegacyCleanupResult: Sendable {
        let removedLabels: [String]

        var message: String? {
            guard !removedLabels.isEmpty else { return nil }
            return "Removed \(removedLabels.count) legacy com.tonyyo.jrc LaunchAgent"
                + (removedLabels.count == 1 ? "." : "s.")
        }
    }

    /// Where macOS UserAgents live. We never touch system-wide LaunchDaemons.
    static let agentsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    /// All Python-owned LaunchAgent plist files.
    static func list() -> [Schedule] {
        launchAgentEntries()
            .filter { $0.lastPathComponent.hasPrefix("\(LaunchAgentWriter.labelPrefix).") }
            .filter { $0.pathExtension == "plist" }
            .compactMap(parse)
            .sorted { $0.name < $1.name }
    }

    /// Delete old Swift-owned `com.tonyyo.jrc.*` plists once at app launch.
    static func cleanupLegacyAgents() -> LegacyCleanupResult {
        let legacyURLs = launchAgentEntries()
            .filter { $0.lastPathComponent.hasPrefix("\(LaunchAgentWriter.legacyLabelPrefix).") }
            .filter { $0.pathExtension == "plist" }

        var removed: [String] = []
        for url in legacyURLs {
            let label = plistLabel(url) ?? url.deletingPathExtension().lastPathComponent
            guard label.hasPrefix("\(LaunchAgentWriter.legacyLabelPrefix).") else { continue }
            _ = bootout(label)
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(label)
            } catch {
                continue
            }
        }
        return LegacyCleanupResult(removedLabels: removed.sorted())
    }

    /// Remove generated Python-owned LaunchAgents for a profile. Used when
    /// leaving demo mode so synthetic demo schedules cannot appear in live mode.
    static func removeAgents(profile: String) -> [String] {
        guard ProfileService.isValid(profile) else { return [] }
        let prefix = "\(LaunchAgentWriter.labelPrefix).\(profile)."
        let urls = launchAgentEntries()
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .filter { $0.pathExtension == "plist" }

        var removed: [String] = []
        for url in urls {
            guard let label = plistLabel(url),
                  LaunchAgentWriter.isValidLabel(label),
                  label.hasPrefix(prefix) else {
                continue
            }
            _ = bootout(label)
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(label)
            } catch {
                continue
            }
        }
        return removed.sorted()
    }

    // MARK: - Private

    private static func launchAgentEntries() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Parse one plist into a Schedule. Returns nil if the plist is malformed
    /// or the label doesn't match the Python-owned naming convention.
    static func parse(_ url: URL) -> Schedule? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String,
              LaunchAgentWriter.isValidLabel(label) else {
            return nil
        }

        guard let labelParts = profileAndSlug(from: label) else { return nil }
        let args = plist["ProgramArguments"] as? [String] ?? []
        let enabled = !((plist["Disabled"] as? Bool) ?? false)
        let cadence = describeCadence(plist["StartCalendarInterval"])
        let mode = runMode(from: args) ?? .jamfCLIOnly
        let statusURL = labelParts.isMulti
            ? multiStatusFileURL(from: args, label: label)
            : statusFileURL(from: args, profile: labelParts.profile, label: label)
        let runStatus = labelParts.isMulti
            ? readMultiRunStatus(from: statusURL, label: label)
            : readRunStatus(from: statusURL, profile: labelParts.profile)
        let logSummary = readLogSummary(
            from: plist,
            profile: labelParts.profile,
            label: label,
            isMulti: labelParts.isMulti
        )
        let lastDate = runStatus?.finishedAt ?? logSummary.date

        return Schedule(
            name: humanName(from: labelParts.slug, mode: mode),
            profile: labelParts.isMulti ? (multiBaseProfile(from: args) ?? "") : labelParts.profile,
            schedule: cadence,
            cadence: "custom",
            mode: mode,
            next: nextRunText(from: plist["StartCalendarInterval"], enabled: enabled),
            last: lastDate.map(FileDisplay.date) ?? "—",
            lastStatus: lastStatus(from: runStatus, logSummary: logSummary),
            artifacts: runStatus?.artifacts ?? [],
            enabled: enabled,
            launchAgentLabel: label,
            multiTarget: labelParts.isMulti ? (multiTarget(from: args) ?? MultiTarget(scope: .all)) : nil
        )
    }

    private static func plistLabel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["Label"] as? String
    }

    private struct LabelParts {
        let profile: String
        let slug: String
        let isMulti: Bool
    }

    private static func profileAndSlug(from label: String) -> LabelParts? {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        guard label.hasPrefix(prefix) else { return nil }
        let tail = String(label.dropFirst(prefix.count))
        if tail.hasPrefix("multi.") {
            let slug = String(tail.dropFirst("multi.".count))
            guard !slug.isEmpty else { return nil }
            return LabelParts(profile: "", slug: slug, isMulti: true)
        }
        let parts = tail.components(separatedBy: ".")
        guard let profile = parts.first, ProfileService.isValid(profile) else { return nil }
        let slug = parts.dropFirst().joined(separator: ".")
        return LabelParts(profile: profile, slug: slug, isMulti: false)
    }

    private static func multiTarget(from args: [String]) -> MultiTarget? {
        let flags: [String]
        if args.count >= 2, args[1] == "multi" {
            flags = Array(args.dropFirst(2).prefix { $0 != "--" })
        } else if let runIndex = args.firstIndex(of: "multi-launchagent-run") {
            flags = Array(args.dropFirst(runIndex + 1))
        } else {
            return nil
        }
        var scope: MultiTarget.Scope = .all
        var sequential = false
        var i = 0
        while i < flags.count {
            switch flags[i] {
            case "--sequential", "--multi-sequential":
                sequential = true
            case "--filter", "--multi-filter":
                if i + 1 < flags.count {
                    scope = .filter(flags[i + 1])
                    i += 1
                }
            case "--profiles", "--multi-profiles":
                if i + 1 < flags.count {
                    let profiles = flags[i + 1]
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { ProfileService.isValid($0) }
                    if !profiles.isEmpty {
                        scope = .list(profiles)
                    }
                    i += 1
                }
            default:
                break
            }
            i += 1
        }
        return MultiTarget(scope: scope, sequential: sequential)
    }

    private static func multiBaseProfile(from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: "--base-profile"), idx + 1 < args.count else {
            return nil
        }
        let profile = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return ProfileService.isValid(profile) ? profile : nil
    }

    private static func runMode(from args: [String]) -> Schedule.RunMode? {
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count else { return nil }
        return Schedule.RunMode(rawValue: args[idx + 1])
    }

    // MARK: - Cadence / Next Run

    /// Convert a `StartCalendarInterval` value (dict or array of dicts) into a
    /// human-readable string for the table.
    private static func describeCadence(_ raw: Any?) -> String {
        let entries = calendarEntries(from: raw)
        if let first = entries.first {
            if entries.count == 5,
               Set(entries.compactMap { $0["Weekday"] }) == Set(1...5) {
                return "Weekdays \(formatTime(first))"
            }
            if entries.count > 1 {
                return "\(entries.count)× weekly · " + formatCalendar(first)
            }
            return formatCalendar(first)
        }
        return "manual"
    }

    private static func nextRunText(from raw: Any?, enabled: Bool) -> String {
        guard enabled, let next = nextRunDate(from: raw) else { return "—" }
        return FileDisplay.date(next)
    }

    private static func nextRunDate(from raw: Any?, now: Date = Date()) -> Date? {
        calendarEntries(from: raw)
            .compactMap { nextDate(for: $0, after: now) }
            .min()
    }

    private static func nextDate(for entry: [String: Int], after now: Date) -> Date? {
        let cal = Calendar.current
        var components = DateComponents()
        components.hour = entry["Hour"] ?? 0
        components.minute = entry["Minute"] ?? 0
        components.second = 0
        if let weekday = entry["Weekday"] {
            components.weekday = calendarWeekday(fromLaunchdWeekday: weekday)
        }
        if let day = entry["Day"] {
            components.day = day
        }
        return cal.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    private static func calendarWeekday(fromLaunchdWeekday value: Int) -> Int {
        value == 0 || value == 7 ? 1 : value + 1
    }

    private static func calendarEntries(from raw: Any?) -> [[String: Int]] {
        if let dict = raw as? [String: Int] {
            return [dict]
        }
        if let dict = raw as? [String: Any] {
            return [intDictionary(from: dict)]
        }
        if let array = raw as? [[String: Int]] {
            return array
        }
        if let array = raw as? [[String: Any]] {
            return array.map(intDictionary)
        }
        return []
    }

    private static func intDictionary(from dict: [String: Any]) -> [String: Int] {
        dict.reduce(into: [:]) { result, item in
            if let value = item.value as? Int {
                result[item.key] = value
            } else if let value = item.value as? NSNumber {
                result[item.key] = value.intValue
            }
        }
    }

    private static func formatCalendar(_ d: [String: Int]) -> String {
        let timeStr = formatTime(d)
        if let weekday = d["Weekday"] {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let dayName = names[safe: weekday] ?? "Day\(weekday)"
            return "\(dayName) \(timeStr)"
        }
        if let day = d["Day"] {
            return "Day \(day) \(timeStr)"
        }
        return "Daily \(timeStr)"
    }

    private static func formatTime(_ d: [String: Int]) -> String {
        let h = d["Hour"] ?? 0
        let m = d["Minute"] ?? 0
        return String(format: "%02d:%02d", h, m)
    }

    private static func humanName(from slug: String, mode: Schedule.RunMode) -> String {
        if slug.isEmpty {
            switch mode {
            case .snapshotOnly: return "Snapshot"
            case .jamfCLIOnly: return "Jamf CLI Report"
            case .jamfCLIFull: return "Full Automation"
            case .csvAssisted: return "CSV Assisted"
            }
        }
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: - Run Status

    private struct ParsedRunStatus {
        let finishedAt: Date?
        let success: Bool?
        let artifacts: [String]
    }

    private struct ParsedLogSummary {
        let date: Date?
        let exitCode: Int32?
        let hasFailureMarker: Bool
    }

    private static func statusFileURL(
        from args: [String],
        profile: String,
        label: String
    ) -> URL? {
        guard let root = WorkspacePathGuard.root(for: profile) else { return nil }
        let rawPath: String
        if let idx = args.firstIndex(of: "--status-file"), idx + 1 < args.count {
            rawPath = args[idx + 1]
        } else {
            rawPath = root
                .appendingPathComponent("automation", isDirectory: true)
                .appendingPathComponent("\(label)_status.json")
                .path
        }
        return validatedWorkspaceURL(rawPath, profile: profile)
    }

    private static func multiStatusFileURL(from args: [String], label: String) -> URL? {
        guard let idx = args.firstIndex(of: "--status-file"), idx + 1 < args.count else {
            return nil
        }
        return validatedMultiLogURL(args[idx + 1], label: label)
    }

    private static func readRunStatus(
        from url: URL?,
        profile: String
    ) -> ParsedRunStatus? {
        guard let root = WorkspacePathGuard.root(for: profile),
              let url,
              let safeURL = WorkspacePathGuard.validate(url, under: root),
              let values = try? safeURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= 1_048_576,
              let data = try? Data(contentsOf: safeURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ParsedRunStatus(
            finishedAt: dateValue(payload["finished_at"]),
            success: payload["success"] as? Bool,
            artifacts: artifactLabels(from: payload, root: root)
        )
    }

    private static func readMultiRunStatus(from url: URL?, label: String) -> ParsedRunStatus? {
        guard let url,
              let safeURL = validatedMultiLogURL(url.path, label: label),
              let values = try? safeURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= 1_048_576,
              let data = try? Data(contentsOf: safeURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ParsedRunStatus(
            finishedAt: dateValue(payload["finished_at"]),
            success: payload["success"] as? Bool,
            artifacts: []
        )
    }

    private static func readLogSummary(
        from plist: [String: Any],
        profile: String,
        label: String,
        isMulti: Bool
    ) -> ParsedLogSummary {
        let urls = ["StandardOutPath", "StandardErrorPath"]
            .compactMap { plist[$0] as? String }
            .compactMap {
                isMulti
                    ? validatedMultiLogURL($0, label: label)
                    : validatedWorkspaceURL($0, profile: profile)
            }
            .filter { fileSize($0) > 0 }

        let newestDate = urls
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate }
            .max()

        var exitCode: Int32?
        var hasFailureMarker = false
        for url in urls {
            let tail = parseLogTail(from: url)
            if exitCode == nil {
                exitCode = tail.exitCode
            }
            hasFailureMarker = hasFailureMarker || tail.hasFailureMarker
        }
        return ParsedLogSummary(
            date: newestDate,
            exitCode: exitCode,
            hasFailureMarker: hasFailureMarker
        )
    }

    private static func lastStatus(
        from runStatus: ParsedRunStatus?,
        logSummary: ParsedLogSummary
    ) -> Schedule.LastStatus {
        if let success = runStatus?.success {
            return success ? .ok : .fail
        }
        if let exitCode = logSummary.exitCode {
            return exitCode == 0 ? .ok : .fail
        }
        return logSummary.hasFailureMarker ? .fail : .ok
    }

    private static func artifactLabels(
        from payload: [String: Any],
        root: URL
    ) -> [String] {
        var labels: [String] = []
        var seen: Set<String> = []
        addArtifact("xlsx_report_path", as: "XLSX", from: payload, root: root, labels: &labels, seen: &seen)
        addArtifact("html_report_path", as: "HTML", from: payload, root: root, labels: &labels, seen: &seen)
        addArtifact("inventory_csv_path", as: "CSV", from: payload, root: root, labels: &labels, seen: &seen)
        if labels.isEmpty {
            addReportArtifact(from: payload["report_path"], root: root, labels: &labels, seen: &seen)
        }
        if let exported = payload["exported_reports"] as? [String],
           exported.contains(where: { artifactExists($0, root: root) }) {
            appendUnique("EXPORTS", labels: &labels, seen: &seen)
        }
        return labels
    }

    private static func addArtifact(
        _ key: String,
        as label: String,
        from payload: [String: Any],
        root: URL,
        labels: inout [String],
        seen: inout Set<String>
    ) {
        guard let raw = payload[key] as? String, artifactExists(raw, root: root) else { return }
        appendUnique(label, labels: &labels, seen: &seen)
    }

    private static func addReportArtifact(
        from raw: Any?,
        root: URL,
        labels: inout [String],
        seen: inout Set<String>
    ) {
        guard let path = raw as? String,
              artifactExists(path, root: root) else { return }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "xlsx": appendUnique("XLSX", labels: &labels, seen: &seen)
        case "html": appendUnique("HTML", labels: &labels, seen: &seen)
        case "csv": appendUnique("CSV", labels: &labels, seen: &seen)
        default: appendUnique("OUTPUT", labels: &labels, seen: &seen)
        }
    }

    private static func appendUnique(
        _ label: String,
        labels: inout [String],
        seen: inout Set<String>
    ) {
        guard seen.insert(label).inserted else { return }
        labels.append(label)
    }

    private static func artifactExists(_ rawPath: String, root: URL) -> Bool {
        let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        guard let safeURL = WorkspacePathGuard.validate(url, under: root) else { return false }
        return FileManager.default.fileExists(atPath: safeURL.path)
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: text)
    }

    static func parseLogTail(from url: URL) -> (exitCode: Int32?, hasFailureMarker: Bool) {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return (nil, false) }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        let readSize = min(fileSize, 2_048)
        fh.seek(toFileOffset: fileSize - readSize)
        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, false) }

        var hasFailureMarker = false
        var parsedExitCode: Int32? = nil
        for line in text.components(separatedBy: "\n").reversed() {
            let lower = line.lowercased()
            hasFailureMarker = hasFailureMarker
                || lower.contains("[fatal]")
                || lower.contains("[error]")
                || lower.contains("[fail]")
                || lower.contains("error:")
                || lower.contains("traceback")
            if parsedExitCode == nil {
                parsedExitCode = exitCode(from: line)
            }
        }
        return (parsedExitCode, hasFailureMarker)
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

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func validatedWorkspaceURL(_ rawPath: String, profile: String) -> URL? {
        guard let root = WorkspacePathGuard.root(for: profile) else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return WorkspacePathGuard.validate(url, under: root)
    }

    private static func validatedMultiLogURL(_ rawPath: String, label: String) -> URL? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(label)", isDirectory: true)
            .resolvingSymlinksInPath()
        let resolved = url.resolvingSymlinksInPath()
        let safePath = logDir.path
        let safePrefix = safePath + "/"
        guard resolved.path == safePath || resolved.path.hasPrefix(safePrefix) else { return nil }
        return resolved
    }

    private static func bootout(_ label: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
