import Foundation
import Darwin

/// LaunchAgent label and command helpers for the Python-owned automation flow.
///
/// The macOS app no longer serializes LaunchAgent plists. It shells out to
/// `jamf-reports-community.py launchagent-setup`, which owns the plist schema,
/// status-file path, log paths, CSV inbox behavior, and launchd loading.
enum LaunchAgentWriter {

    static let labelPrefix = "com.github.tonyyo11.jamf-reports-community"
    static let legacyLabelPrefix = "com.tonyyo.jrc"

    enum WriterError: Error, LocalizedError {
        case invalidProfile(String)
        case invalidSlug(String)
        case cadenceParseError(String)
        case outsideSafeDir(URL)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p):      "Profile '\(p)' contains invalid characters."
            case .invalidSlug(let s):          "Name produces invalid slug '\(s)' — use a-z, 0-9, hyphens."
            case .cadenceParseError(let s):    "Cannot parse cadence: \(s)"
            case .outsideSafeDir(let u):       "Path outside ~/Library/LaunchAgents: \(u.lastPathComponent)"
            }
        }
    }

    struct SetupPlan: Sendable {
        let label: String
        let arguments: [String]
        let plistURL: URL
    }

    // MARK: - Python launchagent-setup arguments

    static func setupPlan(
        for schedule: Schedule,
        configURL: URL,
        workspaceURL: URL,
        load: Bool
    ) throws -> SetupPlan {
        guard ProfileService.isValid(schedule.profile) else {
            throw WriterError.invalidProfile(schedule.profile)
        }
        guard let agentLabel = label(for: schedule) else {
            throw WriterError.invalidSlug(sanitizedSlug(from: schedule.name))
        }
        let cadence = try setupCadence(from: schedule.schedule)
        var args = [
            "launchagent-setup",
            "--config", configURL.path,
            "--profile", schedule.profile,
            "--label", agentLabel,
            "--mode", schedule.mode.rawValue,
            "--schedule", cadence.schedule,
            "--time-of-day", cadence.timeOfDay,
            "--workspace-dir", workspaceURL.path,
        ]
        if let weekday = cadence.weekday {
            args.append(contentsOf: ["--weekday", weekday])
        }
        if let day = cadence.dayOfMonth {
            args.append(contentsOf: ["--day-of-month", String(day)])
        }
        if !load {
            args.append(contentsOf: ["--disabled", "--skip-load"])
        }
        return SetupPlan(
            label: agentLabel,
            arguments: args,
            plistURL: LaunchAgentService.agentsDir.appendingPathComponent("\(agentLabel).plist")
        )
    }

    // MARK: - Load / Unload / Delete

    /// Remove the agent: `launchctl bootout gui/<uid>/<label>`.
    static func unload(_ label: String) async -> Int32 {
        guard isValidLabel(label) else { return -1 }
        return await launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    /// Delete a generated Python-owned plist.
    static func delete(_ label: String) throws {
        guard isValidLabel(label) else {
            throw WriterError.outsideSafeDir(
                LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
            )
        }
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        let safeDir = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeDir.path) else {
            throw WriterError.outsideSafeDir(plistURL)
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    // MARK: - Label helper

    static func label(for schedule: Schedule) -> String? {
        if let existing = schedule.launchAgentLabel, isValidLabel(existing) {
            return existing
        }
        guard ProfileService.isValid(schedule.profile) else { return nil }
        let slug = sanitizedSlug(from: schedule.name)
        guard isValidComponent(slug) else { return nil }
        return "\(labelPrefix).\(schedule.profile).\(slug)"
    }

    // MARK: - Private helpers

    private struct CadenceOptions {
        let schedule: String
        let timeOfDay: String
        let weekday: String?
        let dayOfMonth: Int?
    }

    private static func setupCadence(from raw: String) throws -> CadenceOptions {
        let normalized = raw
            .replacingOccurrences(of: " · ", with: " ")
            .replacingOccurrences(of: "\u{00B7}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { throw WriterError.cadenceParseError(raw) }

        let timeOfDay = try parseHHMM(tokens.last!, raw: raw)
        let key = tokens[0].lowercased()

        if key == "daily" {
            return .init(schedule: "daily", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: nil)
        }
        if key == "weekdays" {
            return .init(schedule: "weekdays", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: nil)
        }
        if key == "day", tokens.count >= 3, let day = Int(tokens[1]), (1...28).contains(day) {
            return .init(schedule: "monthly", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: day)
        }
        if let day = parseOrdinal(key), (1...28).contains(day) {
            return .init(schedule: "monthly", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: day)
        }
        if let weekday = normalizedWeekday(key) {
            return .init(schedule: "weekly", timeOfDay: timeOfDay, weekday: weekday, dayOfMonth: nil)
        }
        throw WriterError.cadenceParseError(raw)
    }

    private static func launchctl(_ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
    }

    private static func parseHHMM(_ s: String, raw: String) throws -> String {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            throw WriterError.cadenceParseError(raw)
        }
        return String(format: "%02d:%02d", h, m)
    }

    private static func parseOrdinal(_ s: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] {
            if s.hasSuffix(suffix), let n = Int(s.dropLast(suffix.count)) { return n }
        }
        return nil
    }

    private static func normalizedWeekday(_ s: String) -> String? {
        [
            "sun": "Sunday", "sunday": "Sunday",
            "mon": "Monday", "monday": "Monday",
            "tue": "Tuesday", "tuesday": "Tuesday",
            "wed": "Wednesday", "wednesday": "Wednesday",
            "thu": "Thursday", "thursday": "Thursday",
            "fri": "Friday", "friday": "Friday",
            "sat": "Saturday", "saturday": "Saturday",
        ][s]
    }

    /// Lowercase, spaces to hyphens, strip anything outside `[a-z0-9._-]`, drop leading non-alnum.
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

    static func isValidLabel(_ label: String) -> Bool {
        guard label.hasPrefix("\(labelPrefix).") else { return false }
        let tail = String(label.dropFirst(labelPrefix.count + 1))
        guard !tail.isEmpty, !tail.contains(".."), !tail.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return tail.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !tail.components(separatedBy: ".").isEmpty
    }
}
