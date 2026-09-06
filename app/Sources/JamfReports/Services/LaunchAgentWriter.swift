import Foundation

/// LaunchAgent label, slug, and cadence helpers for JamfReports automation.
///
/// As of 2.8.0, scheduled runs are driven by the bundled `SMAppService`
/// ticker (see `Tick.swift`), not per-kind LaunchAgent plists — this file no
/// longer writes, loads, or removes plists. What remains is the identity and
/// parsing vocabulary a handful of other pieces still depend on: the label
/// format `LaunchAgentService.parse` reads back, and the cadence-string
/// grammar the ticker and the dead-man switch both turn into fire times.
enum LaunchAgentWriter {

    static let labelPrefix = "com.github.tonyyo11.jamf-reports-community"

    enum WriterError: Error, LocalizedError {
        case cadenceParseError(String)

        var errorDescription: String? {
            switch self {
            case .cadenceParseError(let s):    "Cannot parse cadence: \(s)"
            }
        }
    }

    // MARK: - Label helper

    static func label(for schedule: Schedule) -> String? {
        if let existing = schedule.launchAgentLabel, isValidLabel(existing) {
            return existing
        }
        let slug = sanitizedSlug(from: schedule.name)
        guard isValidComponent(slug) else { return nil }
        if schedule.isMulti {
            let candidate = "\(labelPrefix).multi.\(slug)"
            return isValidLabel(candidate) ? candidate : nil
        }
        guard ProfileService.isValid(schedule.profile) else { return nil }
        let candidate = "\(labelPrefix).\(schedule.profile).\(slug)"
        return isValidLabel(candidate) ? candidate : nil
    }

    // MARK: - Private helpers

    private struct CadenceOptions {
        let schedule: String
        let timeOfDay: String
        let weekday: String?
        let dayOfMonth: Int?

        var startCalendarIntervals: [[String: Int]] {
            let parts = timeOfDay.split(separator: ":").compactMap { Int($0) }
            let hour = parts.count > 0 ? parts[0] : 6
            let minute = parts.count > 1 ? parts[1] : 0
            let wdMap = ["sunday":0,"monday":1,"tuesday":2,"wednesday":3,"thursday":4,"friday":5,"saturday":6]
            switch schedule {
            case "weekly":
                let wd = wdMap[weekday?.lowercased() ?? ""] ?? 1
                return [["Weekday": wd, "Hour": hour, "Minute": minute]]
            case "weekdays":
                return (1...5).map { ["Weekday": $0, "Hour": hour, "Minute": minute] }
            case "monthly":
                return [["Day": dayOfMonth ?? 1, "Hour": hour, "Minute": minute]]
            default:
                return [["Hour": hour, "Minute": minute]]
            }
        }
    }

    /// The launchd `StartCalendarInterval` entries a cadence string denotes —
    /// the one place the tick and the dead-man switch turn "Daily 06:20" into
    /// fire times. Throws `WriterError.cadenceParseError` for anything else.
    static func calendarIntervals(for cadence: String) throws -> [[String: Int]] {
        try setupCadence(from: cadence).startCalendarIntervals
    }

    private static func setupCadence(from raw: String) throws -> CadenceOptions {
        let normalized = raw
            .replacingOccurrences(of: " · ", with: " ")
            .replacingOccurrences(of: "\u{00B7}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2, let lastToken = tokens.last else {
            throw WriterError.cadenceParseError(raw)
        }

        let timeOfDay = try parseHHMM(lastToken, raw: raw)
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
    ///
    /// Note: `.` is intentionally preserved by the sanitizer so that a
    /// malformed schedule name like `"daily."` or `"daily..snapshot"`
    /// surfaces a downstream `nil` label rather than being silently
    /// rewritten to `"daily"` / `"dailysnapshot"`. The post-PR-3
    /// validity gate is `isValidComponent`, which rejects `.` — so a
    /// dotted slug is caught at label construction with a visible
    /// error rather than disappearing into the writer.
    static func sanitizedSlug(from name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        s = s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        while let first = s.first, !first.isLetter, !first.isNumber { s.removeFirst() }
        return s
    }

    /// S-03 (PR-3, 2026-05-15): `.` is no longer permitted in slug
    /// components. The LaunchAgent label format is
    /// `<prefix>.<profile>.<slug>`; if either contains `.`, the
    /// resulting label has >2 components after the prefix and
    /// `LaunchAgentService.profileAndSlug` rejects it at parse —
    /// the writer would succeed but the schedule would silently
    /// disappear from the Schedules UI. Rejecting `.` here keeps
    /// writer and parser symmetric.
    private static func isValidComponent(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        return !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Syntactic validity check on the label string: prefix + allowed
    /// character set + no consecutive or trailing dots. The structural
    /// "must split cleanly into <profile>.<slug>" rule lives in
    /// `LaunchAgentService.profileAndSlug` so it can reject legacy
    /// 3-component labels at parse time without rejecting them at the
    /// syntactic level (where some callers historically accept
    /// `<prefix>.<profile>` shapes too).
    static func isValidLabel(_ label: String) -> Bool {
        guard label.hasPrefix("\(labelPrefix).") else { return false }
        let tail = String(label.dropFirst(labelPrefix.count + 1))
        guard !tail.isEmpty, !tail.contains(".."), !tail.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return tail.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !tail.components(separatedBy: ".").isEmpty
    }
}
