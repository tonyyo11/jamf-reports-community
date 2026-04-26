import Foundation
import Darwin

/// Write, load, unload, and delete `~/Library/LaunchAgents/com.tonyyo.jrc.*.plist` files.
///
/// Security invariants (enforced here, not by callers):
/// - Every plist label must match `com.tonyyo.jrc.<valid-profile>.<valid-slug>`.
/// - Write destination must not be a symlink.
/// - Delete refuses any label that doesn't start with `com.tonyyo.jrc.`.
/// - `ProgramArguments[0]` is always the absolute resolved path to `jrc` — never a shell wrapper.
/// - Log paths always resolve inside `~/Jamf-Reports/<profile>/automation/logs/`.
enum LaunchAgentWriter {

    enum WriterError: Error, LocalizedError {
        case invalidProfile(String)
        case invalidSlug(String)
        case destinationIsSymlink(URL)
        case cadenceParseError(String)
        case outsideSafeDir(URL)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p):      "Profile '\(p)' contains invalid characters."
            case .invalidSlug(let s):          "Name produces invalid slug '\(s)' — use a-z, 0-9, hyphens."
            case .destinationIsSymlink(let u): "Refusing to overwrite symlink at \(u.lastPathComponent)."
            case .cadenceParseError(let s):    "Cannot parse cadence: \(s)"
            case .outsideSafeDir(let u):       "Path outside ~/Library/LaunchAgents: \(u.lastPathComponent)"
            }
        }
    }

    // MARK: - Write

    /// Emit a launchd plist, atomically replacing any existing file. Returns the plist URL.
    static func write(_ schedule: Schedule, jrcPath: URL) throws -> URL {
        guard ProfileService.isValid(schedule.profile) else {
            throw WriterError.invalidProfile(schedule.profile)
        }
        let slug = sanitizedSlug(from: schedule.name)
        guard isValidComponent(slug) else { throw WriterError.invalidSlug(slug) }

        let agentLabel = "com.tonyyo.jrc.\(schedule.profile).\(slug)"
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(agentLabel).plist")

        // Refuse to write over a symlink (symlink-swap defense)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw WriterError.destinationIsSymlink(plistURL)
        }

        let logDir = logDirectory(for: schedule.profile)
        let logPath = logDir.appendingPathComponent("\(agentLabel).log").path

        var plist: [String: Any] = [
            "Label":             agentLabel,
            "ProgramArguments":  [jrcPath.path, "run", "--profile", schedule.profile,
                                  "--mode", schedule.mode.rawValue],
            "RunAtLoad":         false,
            "KeepAlive":         false,
            "Disabled":          !schedule.enabled,
            "StandardOutPath":   logPath,
            "StandardErrorPath": logPath,
        ]
        plist["StartCalendarInterval"] = try parseCadence(schedule.schedule)

        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let tmpURL = LaunchAgentService.agentsDir.appendingPathComponent(".\(agentLabel).plist.tmp")
        try data.write(to: tmpURL)

        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = try FileManager.default.replaceItem(
                at: plistURL, withItemAt: tmpURL, backupItemName: nil, resultingItemURL: nil
            )
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: plistURL)
        }
        return plistURL
    }

    // MARK: - Load / Unload

    /// Register the agent with launchd: `launchctl bootstrap gui/<uid> <plist>`.
    static func load(_ label: String) async -> Int32 {
        guard isValidLabel(label) else { return -1 }
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return -1 }
        return await launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// Remove the agent: `launchctl bootout gui/<uid>/<label>`.
    static func unload(_ label: String) async -> Int32 {
        guard isValidLabel(label) else { return -1 }
        return await launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    // MARK: - Delete

    /// Delete a plist. Refuses any label not starting with `com.tonyyo.jrc.`.
    static func delete(_ label: String) throws {
        guard label.hasPrefix("com.tonyyo.jrc.") else {
            throw WriterError.outsideSafeDir(
                LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
            )
        }
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        let safeDir  = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeDir.path) else {
            throw WriterError.outsideSafeDir(plistURL)
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    // MARK: - Cadence parser (exported for SchedulesView form → round-trip validation)

    /// Human cadence string → `StartCalendarInterval` value (dict or array of dicts).
    ///
    /// Accepted forms (space or ` · ` separator):
    /// `Daily HH:MM`, `<Weekday> HH:MM`, `Weekdays HH:MM`,
    /// `<N>st|nd|rd|th HH:MM`, `Day <N> HH:MM`.
    static func parseCadence(_ raw: String) throws -> Any {
        let normalized = raw
            .replacingOccurrences(of: " · ", with: " ")
            .replacingOccurrences(of: "\u{00B7}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { throw WriterError.cadenceParseError(raw) }

        let (hour, minute) = try parseHHMM(tokens.last!, raw: raw)
        let key = tokens[0].lowercased()

        if key == "daily"    { return ["Hour": hour, "Minute": minute] }
        if key == "weekdays" { return (1...5).map { ["Weekday": $0, "Hour": hour, "Minute": minute] } }

        if key == "day", tokens.count >= 3, let day = Int(tokens[1]) {
            return ["Day": day, "Hour": hour, "Minute": minute]
        }
        if let day = parseOrdinal(key) { return ["Day": day, "Hour": hour, "Minute": minute] }
        if let wd  = parseWeekday(key) { return ["Weekday": wd, "Hour": hour, "Minute": minute] }
        throw WriterError.cadenceParseError(raw)
    }

    // MARK: - Label helper (used by SchedulesView for consistent label derivation)

    static func label(for schedule: Schedule) -> String? {
        let slug = sanitizedSlug(from: schedule.name)
        guard isValidComponent(slug) else { return nil }
        return "com.tonyyo.jrc.\(schedule.profile).\(slug)"
    }

    // MARK: - Private helpers

    private static func launchctl(_ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError  = Pipe()
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
    }

    private static func logDirectory(for profile: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports/\(profile)/automation/logs")
    }

    private static func parseHHMM(_ s: String, raw: String) throws -> (Int, Int) {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            throw WriterError.cadenceParseError(raw)
        }
        return (h, m)
    }

    private static func parseOrdinal(_ s: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] {
            if s.hasSuffix(suffix), let n = Int(s.dropLast(suffix.count)) { return n }
        }
        return nil
    }

    private static func parseWeekday(_ s: String) -> Int? {
        [
            "sun": 0, "sunday": 0, "mon": 1, "monday": 1,
            "tue": 2, "tuesday": 2, "wed": 3, "wednesday": 3,
            "thu": 4, "thursday": 4, "fri": 5, "friday": 5,
            "sat": 6, "saturday": 6,
        ][s]
    }

    /// Lowercase, spaces → hyphens, strip anything outside `[a-z0-9._-]`, drop leading non-alnum.
    static func sanitizedSlug(from name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        s = s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        while let first = s.first, !first.isLetter, !first.isNumber { s.removeFirst() }
        return s
    }

    private static func isValidComponent(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidLabel(_ label: String) -> Bool {
        guard label.hasPrefix("com.tonyyo.jrc.") else { return false }
        let tail = String(label.dropFirst("com.tonyyo.jrc.".count))
        guard !tail.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return tail.unicodeScalars.allSatisfy { allowed.contains($0) }
            && tail.components(separatedBy: ".").count >= 2
    }
}
