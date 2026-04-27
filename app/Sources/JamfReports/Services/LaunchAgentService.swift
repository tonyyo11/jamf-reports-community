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
    private static func parse(_ url: URL) -> Schedule? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String,
              LaunchAgentWriter.isValidLabel(label) else {
            return nil
        }

        guard let (profile, slug) = profileAndSlug(from: label) else { return nil }
        let args = plist["ProgramArguments"] as? [String] ?? []
        let enabled = !((plist["Disabled"] as? Bool) ?? false)
        let cadence = describeCadence(plist["StartCalendarInterval"])
        let mode = runMode(from: args) ?? .jamfCLIOnly

        return Schedule(
            name: humanName(from: slug, mode: mode),
            profile: profile,
            schedule: cadence,
            cadence: "custom",
            mode: mode,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: enabled,
            launchAgentLabel: label
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

    private static func profileAndSlug(from label: String) -> (String, String)? {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        guard label.hasPrefix(prefix) else { return nil }
        let tail = String(label.dropFirst(prefix.count))
        let parts = tail.components(separatedBy: ".")
        guard let profile = parts.first, ProfileService.isValid(profile) else { return nil }
        let slug = parts.dropFirst().joined(separator: ".")
        return (profile, slug)
    }

    private static func runMode(from args: [String]) -> Schedule.RunMode? {
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count else { return nil }
        return Schedule.RunMode(rawValue: args[idx + 1])
    }

    /// Convert a `StartCalendarInterval` value (dict or array of dicts) into a
    /// human-readable string for the table.
    private static func describeCadence(_ raw: Any?) -> String {
        if let dict = raw as? [String: Int] {
            return formatCalendar(dict)
        }
        if let array = raw as? [[String: Int]], let first = array.first {
            if array.count == 5,
               Set(array.compactMap { $0["Weekday"] }) == Set(1...5) {
                return "Weekdays \(formatTime(first))"
            }
            return "\(array.count)× weekly · " + formatCalendar(first)
        }
        return "manual"
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
