import Foundation

/// Discovers `~/Library/LaunchAgents/com.tonyyo.jrc.*.plist` files and parses
/// them into `Schedule` model objects.
///
/// **Read-only in this revision.** Write/load/unload land in a follow-up
/// session — the security surface for write operations (validating the plist
/// structure before handing it to launchd, ensuring atomic writes, and
/// confirming destructive actions like `launchctl unload`) deserves more care
/// than a quick wire-up.
enum LaunchAgentService {

    /// Where macOS UserAgents live. We never touch system-wide LaunchDaemons.
    static let agentsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    /// All plist files with the `com.tonyyo.jrc.*` label prefix.
    static func list() -> [Schedule] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("com.tonyyo.jrc.") }
            .filter { $0.pathExtension == "plist" }
            .compactMap(parse)
            .sorted { $0.name < $1.name }
    }

    /// Parse one plist into a Schedule. Returns nil if the plist is malformed
    /// or the label doesn't match our naming convention.
    private static func parse(_ url: URL) -> Schedule? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else {
            return nil
        }

        // Label form: com.tonyyo.jrc.<profile>.<slug>
        let parts = label.components(separatedBy: ".")
        guard parts.count >= 5, parts[0] == "com", parts[1] == "tonyyo", parts[2] == "jrc" else {
            return nil
        }
        let profile = parts[3]
        let slug = parts[4...].joined(separator: ".")
        guard ProfileService.isValid(profile) else { return nil }

        let enabled = !((plist["Disabled"] as? Bool) ?? false)
        let cadence = describeCadence(plist["StartCalendarInterval"])

        return Schedule(
            name: slug.replacingOccurrences(of: "-", with: " ").capitalized,
            profile: profile,
            schedule: cadence,
            cadence: "custom",
            mode: .jamfCLIOnly,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: enabled
        )
    }

    /// Convert a `StartCalendarInterval` value (dict or array of dicts) into a
    /// human-readable string for the table.
    private static func describeCadence(_ raw: Any?) -> String {
        if let dict = raw as? [String: Int] {
            return formatCalendar(dict)
        }
        if let array = raw as? [[String: Int]], let first = array.first {
            return "\(array.count)× weekly · " + formatCalendar(first)
        }
        return "manual"
    }

    private static func formatCalendar(_ d: [String: Int]) -> String {
        let h = d["Hour"] ?? 0
        let m = d["Minute"] ?? 0
        let timeStr = String(format: "%02d:%02d", h, m)
        if let weekday = d["Weekday"] {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let dayName = names[safe: weekday] ?? "Day\(weekday)"
            return "\(dayName) · \(timeStr)"
        }
        if let day = d["Day"] {
            return "Day \(day) · \(timeStr)"
        }
        return "Daily · \(timeStr)"
    }
}
