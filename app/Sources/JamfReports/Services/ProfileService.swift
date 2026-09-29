import Foundation

/// Profile name validation and discovery.
///
/// A "profile" is a `jamf-cli` profile id whose workspace folder is
/// `~/Jamf-Reports/<ProfileName.pathComponent(profile)>/`. We never expose API client secrets
/// — those live in `jamf-cli`'s keychain. The GUI only ever sees the profile
/// id, the URL, and the on-disk workspace folder.
enum ProfileService {

    enum CleanupError: Error, LocalizedError {
        case invalidProfile(String)
        case outsideWorkspaceRoot(URL)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile):
                return "Invalid profile name: \(profile)"
            case .outsideWorkspaceRoot(let url):
                return "Refusing to remove workspace outside \(workspacesRoot().path): \(url.path)"
            }
        }
    }

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

        init(name: String, url: String?, authMethod: String?, isDefault: Bool) {
            self.name = name
            self.url = url
            self.authMethod = authMethod
            self.isDefault = isDefault
        }
    }

    /// True for every jamf-cli profile name the app can use: all of them except those
    /// `ProfileName.problem(with:)` names. Paths and labels never take the raw name; they go
    /// through `ProfileName`, which is what keeps `/`, `..` and `.` (S-03's label split) safe.
    static func isValid(_ name: String) -> Bool {
        ProfileName.problem(with: name) == nil
    }

    /// Why Jamf Reports can't use a configured jamf-cli profile.
    enum UnusableReason: Equatable, Sendable {
        /// The name fails `isValid`.
        case unsupportedName(ProfileName.Problem)
        /// The name matches `owner` except for letter case. The workspace root is
        /// normally on a case-insensitive volume, where both would use one folder.
        case sharesFolder(with: String)

        /// Full sentence for the setup screen.
        var explanation: String {
            switch self {
            case .unsupportedName(let problem):
                return problem.explanation + " jamf-cli can't rename a profile, so add this "
                    + "connection again under a new name."
            case .sharesFolder(let owner):
                return "Matches \(owner) except for letter case, so both would use one workspace "
                    + "folder, which belongs to \(owner). To use this profile, add it again in "
                    + "jamf-cli under a name that differs by more than case."
            }
        }

        /// Short form for one-line connection rows.
        var label: String {
            switch self {
            case .unsupportedName: return "(unsupported name)"
            case .sharesFolder(let owner): return "(same folder as \(owner))"
            }
        }
    }

    /// Configured profiles Jamf Reports can't use. Of names that differ only by
    /// case, the one an existing workspace folder records keeps it, matching the
    /// bind and collect guards; with no folder, the all-lowercase spelling (the
    /// only one older builds accepted), else the first listed.
    /// `recordedOwner` maps a `ProfileName.folderKey` to that folder's profile.
    static func unusableProfiles(
        in names: [String],
        recordedOwner: (String) -> String? = recordedWorkspaceOwner(matching:)
    ) -> [String: UnusableReason] {
        var reasons: [String: UnusableReason] = [:]
        for name in names {
            if let problem = ProfileName.problem(with: name) {
                reasons[name] = .unsupportedName(problem)
            }
        }
        let spellings = Dictionary(grouping: names.filter(isValid), by: ProfileName.folderKey)
        for (key, group) in spellings where group.count > 1 {
            let recorded = recordedOwner(key)
            let owner = group.first { $0 == recorded } ?? group.first { $0 == key } ?? group[0]
            for name in group where name != owner {
                reasons[name] = .sharesFolder(with: owner)
            }
        }
        return reasons
    }

    /// The profile an existing workspace folder spelled like `key` (any case)
    /// records in `jamf_cli.profile`, or the name the folder encodes when that is blank.
    static func recordedWorkspaceOwner(matching key: String) -> String? {
        guard let folder = workspaceFolders(matching: key).first else { return nil }
        let config = workspacesRoot().appendingPathComponent(folder.component)
            .appendingPathComponent("config.yaml")
        let recorded = (try? ConfigLoader.load(from: config))?.jamfCli?.resolvedProfile ?? ""
        return recorded.isEmpty ? folder.name : recorded
    }

    /// Workspace folders (holding a `config.yaml`) whose profile has the folder key `key`,
    /// with the name each encodes. More than one exists only on a case-sensitive volume.
    private static func workspaceFolders(
        matching key: String
    ) -> [(component: String, name: String)] {
        let root = workspacesRoot()
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            return [] // no workspace root yet — first-run state
        } catch {
            AppLogger.collect.error(
                """
                workspaceFolders: enumeration failed at \(root.path, privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """
            )
            return []
        }
        return names.compactMap { component in
            guard let name = ProfileName.name(fromPathComponent: component),
                  ProfileName.folderKey(name) == key else { return nil }
            let config = root.appendingPathComponent(component)
                .appendingPathComponent("config.yaml")
            return FileManager.default.fileExists(atPath: config.path) ? (component, name) : nil
        }
    }

    /// True when a workspace's recorded `jamf_cli.profile` is another profile
    /// spelled like `profile` apart from case: the two share the folder, and
    /// using it would mix their tenants' data.
    static func isCaseVariant(_ recorded: String, of profile: String) -> Bool {
        recorded != profile && ProfileName.folderKey(recorded) == ProfileName.folderKey(profile)
    }

    /// Workspace root. Defaults to `~/Jamf-Reports`; an operator hosting the
    /// workspace on a synced team folder repoints it via `WorkspaceRootStore`,
    /// which owns the resolution order and the validation rules.
    static func workspacesRoot() -> URL {
        WorkspaceRootStore.current()
    }

    /// Path to a specific workspace. Returns nil for invalid names.
    static func workspaceURL(for profile: String) -> URL? {
        guard isValid(profile) else { return nil }
        return workspacesRoot().appendingPathComponent(
            ProfileName.pathComponent(profile), isDirectory: true
        )
    }

    /// The profile of an existing workspace folder spelled like `profile` apart from
    /// letter case. On a case-insensitive volume it is `profile`'s folder as well.
    static func caseVariantWorkspace(of profile: String) -> String? {
        workspaceFolders(matching: ProfileName.folderKey(profile)).map(\.name)
            .first { $0 != profile }
    }

    /// Discover real profiles from `jamf-cli config list` first, then merge in
    /// local `~/Jamf-Reports/<profile>/config.yaml` workspaces. Returns sorted by
    /// default profile first, then by name. In demo mode, the caller falls back
    /// to `DemoData.cliProfiles`.
    static func discoverLocal() -> [JamfCLIProfile] {
        let scheduleCounts = Dictionary(
            grouping: ScheduleStore().load().filter { !$0.allProfiles }, by: \.profile
        ).mapValues(\.count)

        var profiles = discoverJamfCLIProfiles(scheduleCounts: scheduleCounts)

        let workspaceProfiles = localOnlyWorkspaces(
            under: workspacesRoot(), cliNames: profiles.map(\.name)
        ).map { name in
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

    /// Profiles of the workspace folders under `root` (holding a `config.yaml`) that no
    /// jamf-cli profile names. Compared by folder key: on a case-insensitive volume a
    /// folder spelled unlike a profile is still that profile's folder.
    static func localOnlyWorkspaces(under root: URL, cliNames: [String]) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let claimed = Set(cliNames.map(ProfileName.folderKey))
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { folder in
                let config = folder.appendingPathComponent("config.yaml")
                return FileManager.default.fileExists(atPath: config.path)
            }
            .compactMap { ProfileName.name(fromPathComponent: $0.lastPathComponent) }
            .filter(isValid)
            .filter { !claimed.contains(ProfileName.folderKey($0)) }
    }

    /// The profiles a multi-profile run collects: exclusions applied, and the
    /// `.error` ones dropped. Discovery marks a profile the app can't use that way
    /// (unsupported name, or a case variant sharing another's folder); it has no
    /// workspace to run in, and counting it failed every run of the schedule.
    static func runnableProfiles(
        _ profiles: [JamfCLIProfile],
        excluding excluded: Set<String>
    ) -> [JamfCLIProfile] {
        applyingExclusions(profiles, excluding: excluded).filter { $0.status != .error }
    }

    // MARK: - Run-time exclusion (--exclude-profiles)

    /// Parse a comma-separated `--exclude-profiles` value into a validated set
    /// of profile names. Whitespace-trimmed; empty and invalid tokens dropped.
    static func parseExclusions(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        let names = raw.split(separator: ",").map(ProfileName.name(fromListElement:))
        return Set(names.filter(isValid))
    }

    /// Drop `excluded` profiles from `profiles` (run-time exclusion).
    ///
    /// The managed `--all-profiles` runner discovers the full profile set at
    /// run time and then removes the excluded slugs here — it never swaps to an
    /// explicit positive list, which would break the dynamic property that a
    /// single managed agent picks up profiles added later and drops profiles
    /// deleted later without being rewritten.
    static func applyingExclusions(
        _ profiles: [JamfCLIProfile],
        excluding excluded: Set<String>
    ) -> [JamfCLIProfile] {
        guard !excluded.isEmpty else { return profiles }
        return profiles.filter { !excluded.contains($0.name) }
    }

    /// Remove one local workspace folder under `~/Jamf-Reports/<profile>`.
    /// This never edits jamf-cli credentials or profiles; it only removes the
    /// app's local workspace directory after path-boundary validation.
    @discardableResult
    static func removeLocalWorkspace(profile: String) throws -> Bool {
        guard isValid(profile), let url = workspaceURL(for: profile) else {
            throw CleanupError.invalidProfile(profile)
        }
        let root = workspacesRoot().resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let expected = root.appendingPathComponent(
            ProfileName.pathComponent(profile), isDirectory: true
        )
        guard resolved.path == expected.path else {
            throw CleanupError.outsideWorkspaceRoot(url)
        }
        guard resolved.deletingLastPathComponent().standardizedFileURL.path == root.path else {
            throw CleanupError.outsideWorkspaceRoot(url)
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            return false
        }
    }

    /// Lists profiles from `jamf-cli config list`. The
    /// `_testBinaryOverride` parameter is a test seam, NOT a production
    /// API: pass nil (default) in production code; tests pass a known URL
    /// so the codesign-gate path is reachable without a real jamf-cli on
    /// disk. The leading underscore signals "do not pass from production
    /// callers." Production callers must omit this argument so the binary
    /// always resolves via `ExecutableLocator.locate("jamf-cli")`.
    static func discoverJamfCLIProfiles(
        scheduleCounts: [String: Int],
        _testBinaryOverride: URL? = nil
    ) -> [JamfCLIProfile] {
        guard let binary = _testBinaryOverride ?? ExecutableLocator.locate("jamf-cli") else {
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }

        // M-01: refuse to spawn a tampered jamf-cli even for `config list`.
        // Fall back to reading `~/.config/jamf-cli/config.yaml` directly —
        // the same recovery path used when the binary is absent or launch
        // fails. The user still sees their profiles; nothing un-trusted runs.
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["config", "list", "--output", "json"]
        // SF-10/B-13: pin a minimal environment so DYLD_*, SSL_CERT_FILE,
        // JAMF_CLI_* etc. inherited from the parent can't alter how jamf-cli
        // resolves its config or validates TLS.
        process.environment = CLIBridge.environmentForJamfCLI()

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
        return rows(for: decoded, scheduleCounts: scheduleCounts)
    }

    /// Profiles Jamf Reports can't use stay listed, marked `.error` with the
    /// reason, so the user can see why they do nothing (SettingsView greys them
    /// out, the setup screen won't initialize them, WorkspaceStore never makes one
    /// active, multi-profile runs and catch-up skip them).
    private static func rows(
        for configured: [JamfCLIConfigProfile],
        scheduleCounts: [String: Int]
    ) -> [JamfCLIProfile] {
        let unusable = unusableProfiles(in: configured.map(\.name))
        return configured.map { item in
            if let reason = unusable[item.name] {
                return JamfCLIProfile(
                    name: item.name,
                    url: displayURL(item.url),
                    schedules: 0,
                    status: .error,
                    authMethod: reason.label,
                    isDefault: false
                )
            }
            return JamfCLIProfile(
                name: item.name,
                url: displayURL(item.url),
                schedules: scheduleCounts[item.name] ?? 0,
                status: item.isDefault ? .ok : .idle,
                authMethod: item.authMethod ?? "",
                isDefault: item.isDefault
            )
        }
    }

    /// Reads profiles straight from jamf-cli's config file when `config list`
    /// can't run. `configURL` is a test seam; production callers omit it.
    static func fallbackConfigProfiles(
        scheduleCounts: [String: Int],
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jamf-cli/config.yaml")
    ) -> [JamfCLIProfile] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }

        let defaultProfile = firstScalar("default-profile", in: text)
        var configured: [JamfCLIConfigProfile] = []
        var currentName: String?
        var currentURL: String?
        var currentAuthMethod: String?

        func flush() {
            guard let name = currentName else { return }
            configured.append(JamfCLIConfigProfile(
                name: name, url: currentURL, authMethod: currentAuthMethod,
                isDefault: name == defaultProfile
            ))
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
                currentName = unquotedYAMLKey(String(line.dropLast()))
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
        return rows(for: configured, scheduleCounts: scheduleCounts)
    }

    /// A mapping key as jamf-cli's YAML writer emits it: plain, `"double"` (with `\"` and `\\`
    /// escapes) or `'single'` (with `''` for a quote), as it does for names like `#hash`.
    static func unquotedYAMLKey(_ key: String) -> String {
        guard key.count >= 2, let first = key.first, first == key.last else { return key }
        let inner = String(key.dropFirst().dropLast())
        switch first {
        case "\"":
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        case "'":
            return inner.replacingOccurrences(of: "''", with: "'")
        default:
            return key
        }
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

// MARK: - API scope persistence

extension ProfileService {

    private static func scopeKey(for slug: String) -> String {
        "profile.scope.\(slug)"
    }

    /// Returns the persisted `APIScope` for `profileSlug`.
    ///
    /// Returns `.limited` when no value has been stored — explicit elevation is
    /// required before any destructive action can be gated on `fullAdmin`.
    ///
    /// - Parameter profileSlug: A validated profile slug (`ProfileService.isValid`).
    /// - Parameter store: The `UserDefaults` suite to read from. Defaults to `.standard`.
    /// - Returns: The stored scope, or `.limited` if absent or the slug is invalid.
    static func scope(
        for profileSlug: String,
        store: UserDefaults = .standard
    ) -> APIScope {
        guard isValid(profileSlug) else { return .limited }
        guard let raw = store.string(forKey: scopeKey(for: profileSlug)),
              let parsed = APIScope(rawValue: raw) else {
            return .limited
        }
        return parsed
    }

    /// Persists `scope` for `profileSlug`.
    ///
    /// - Parameter scope: The `APIScope` to store.
    /// - Parameter profileSlug: A validated profile slug. Silently no-ops for invalid slugs.
    /// - Parameter store: The `UserDefaults` suite to write to. Defaults to `.standard`.
    static func setScope(
        _ scope: APIScope,
        for profileSlug: String,
        store: UserDefaults = .standard
    ) {
        guard isValid(profileSlug) else { return }
        store.set(scope.rawValue, forKey: scopeKey(for: profileSlug))
    }
}
