import Foundation

/// Profile name validation and discovery.
///
/// A "profile" is a `jamf-cli` profile id that doubles as a workspace folder
/// name under `~/Jamf-Reports/<profile>/`. We never expose API client secrets
/// — those live in `jamf-cli`'s keychain. The GUI only ever sees the profile
/// id, the URL, and the on-disk workspace folder.
enum ProfileService {

    private struct JamfCLIConfigProfile: Decodable {
        let name: String
        let url: String?
        let authMethod: String?
        let isDefault: Bool

        private enum CodingKeys: String, CodingKey {
            case name
            case url
            case authMethod = "auth-method"
            case isDefault = "default"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        }
    }

    /// `^[a-z0-9][a-z0-9._-]*$` — the regex from the design handoff. Profile
    /// names are used in path construction (`~/Jamf-Reports/<name>/`) and
    /// LaunchAgent labels (`com.tonyyo.jrc.<name>.…`); a permissive pattern
    /// would let attackers slip in path traversal or arbitrary plist labels.
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Workspace root, always inside the user's home dir.
    static func workspacesRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports")
    }

    /// Path to a specific workspace. Returns nil for invalid names.
    static func workspaceURL(for profile: String) -> URL? {
        guard isValid(profile) else { return nil }
        return workspacesRoot().appendingPathComponent(profile, isDirectory: true)
    }

    /// Discover real profiles from `jamf-cli config list` first, then merge in
    /// local `~/Jamf-Reports/<profile>/config.yaml` workspaces. Returns sorted by
    /// default profile first, then by name. In demo mode, the caller falls back
    /// to `DemoData.cliProfiles`.
    static func discoverLocal() -> [JamfCLIProfile] {
        let schedules = LaunchAgentService.list()
        let scheduleCounts = Dictionary(grouping: schedules, by: \.profile)
            .mapValues(\.count)

        var profiles = discoverJamfCLIProfiles(scheduleCounts: scheduleCounts)
        let namesFromCLI = Set(profiles.map(\.name))

        let root = workspacesRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return profiles.sorted(by: profileSort)
        }
        let workspaceProfiles = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .filter(isValid)
            .filter { !namesFromCLI.contains($0) }
            .filter { name in
                let cfg = root.appendingPathComponent(name).appendingPathComponent("config.yaml")
                return FileManager.default.fileExists(atPath: cfg.path)
            }
            .map { name in
                JamfCLIProfile(
                    name: name,
                    url: "(local workspace)",
                    schedules: scheduleCounts[name] ?? 0,
                    status: .idle
                )
            }
        profiles.append(contentsOf: workspaceProfiles)
        return profiles.sorted(by: profileSort)
    }

    static func defaultProfileName() -> String? {
        discoverLocal().first(where: \.isDefault)?.name
    }

    private static func discoverJamfCLIProfiles(scheduleCounts: [String: Int]) -> [JamfCLIProfile] {
        guard let binary = ExecutableLocator.locate("jamf-cli") else {
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["config", "list", "--output", "json"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }

        guard process.terminationStatus == 0 else {
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let decoded = try? JSONDecoder().decode([JamfCLIConfigProfile].self, from: data) else {
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }

        return decoded
            .filter { isValid($0.name) }
            .map { item in
                JamfCLIProfile(
                    name: item.name,
                    url: displayURL(item.url),
                    schedules: scheduleCounts[item.name] ?? 0,
                    status: item.isDefault ? .ok : .idle,
                    authMethod: item.authMethod ?? "",
                    isDefault: item.isDefault
                )
            }
    }

    private static func fallbackConfigProfiles(scheduleCounts: [String: Int]) -> [JamfCLIProfile] {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jamf-cli/config.yaml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }

        let defaultProfile = firstScalar("default-profile", in: text)
        var profiles: [JamfCLIProfile] = []
        var currentName: String?
        var currentURL: String?
        var currentAuthMethod: String?

        func flush() {
            guard let name = currentName, isValid(name) else { return }
            profiles.append(
                JamfCLIProfile(
                    name: name,
                    url: displayURL(currentURL),
                    schedules: scheduleCounts[name] ?? 0,
                    status: name == defaultProfile ? .ok : .idle,
                    authMethod: currentAuthMethod ?? "",
                    isDefault: name == defaultProfile
                )
            )
        }

        var inProfiles = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "profiles:" {
                inProfiles = true
                continue
            }
            guard inProfiles, !line.isEmpty, !line.hasPrefix("#") else { continue }

            if rawLine.hasPrefix("    "), line.hasSuffix(":") {
                flush()
                currentName = String(line.dropLast())
                currentURL = nil
                currentAuthMethod = nil
            } else if rawLine.hasPrefix("        "), let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if key == "url" { currentURL = value }
                if key == "auth-method" { currentAuthMethod = value }
            } else if !rawLine.hasPrefix(" ") {
                break
            }
        }
        flush()
        return profiles
    }

    private static func firstScalar(_ key: String, in text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(key):"), let colon = line.firstIndex(of: ":") else { continue }
            return String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func displayURL(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "(jamf-cli profile)" }
        if let url = URL(string: raw), let host = url.host {
            return host
        }
        return raw.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func profileSort(_ lhs: JamfCLIProfile, _ rhs: JamfCLIProfile) -> Bool {
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
