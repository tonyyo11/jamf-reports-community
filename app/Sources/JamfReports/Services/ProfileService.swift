import Foundation

/// Profile name validation and discovery.
///
/// A "profile" is a `jamf-cli` profile id that doubles as a workspace folder
/// name under `~/Jamf-Reports/<profile>/`. We never expose API client secrets
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
    }

    /// `^[a-z0-9][a-z0-9_-]*$` — the regex used everywhere a profile
    /// slug enters either path construction (`~/Jamf-Reports/<name>/`)
    /// or LaunchAgent labels
    /// (`com.github.tonyyo11.jamf-reports-community.<name>.<slug>`).
    ///
    /// S-03 (2026-05-15): `.` was previously permitted but caused
    /// ambiguous parsing in `LaunchAgentService.profileAndSlug`. The
    /// parser splits the label on `.` and takes the first component as
    /// the profile; a profile named `dummy.prod` plus a slug `daily`
    /// produced `com.jamfreports.dummy.prod.daily`, which the parser
    /// silently re-interpreted as profile=`dummy`, slug=`prod.daily`.
    /// Path-side checks were safe (prefix-bounded), but label parsing
    /// was not. Tightening the regex closes the ambiguity at the root.
    ///
    /// Migration: any workspace directory on disk whose name fails
    /// this rule is surfaced via `dottedLegacyWorkspaces()` so the
    /// user knows why a previously-visible profile no longer appears.
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Workspace directory names on disk that fail the current
    /// `isValid` rule because they contain a `.`. Surfaced so the
    /// caller can emit a one-shot migration warning per name in
    /// `discoverLocal()` — the user sees why their previously-visible
    /// profile has dropped from the sidebar after the S-03 tightening.
    ///
    /// Returns an empty list when no dotted directories exist. A
    /// filesystem error (e.g. permission-denied on the workspace
    /// root) is surfaced via AppLogger so the silent-empty fallback
    /// here doesn't mask the underlying problem.
    static func dottedLegacyWorkspaces() -> [String] {
        let root = workspacesRoot()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            return [] // workspace root doesn't exist yet — first-run state
        } catch {
            AppLogger.collect.error(
                "dottedLegacyWorkspaces: enumeration failed at \(root.path, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .filter { name in
                !isValid(name) && name.contains(".")
            }
            .sorted()
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

        // S-03 migration: surface dotted legacy workspace dirs so the
        // user knows why a previously-visible profile is no longer
        // listed. The directory stays on disk untouched; only its
        // discovery is gated.
        let dotted = dottedLegacyWorkspaces()
        if !dotted.isEmpty {
            AppLogger.collect.warning(
                "ProfileService.discoverLocal: \(dotted.count, privacy: .public) legacy workspace dir(s) contain '.' and are no longer valid profile slugs; rename them under ~/Jamf-Reports/ to surface them again. Names: \(dotted.joined(separator: ", "), privacy: .public)"
            )
        }

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

    // MARK: - Run-time exclusion (--exclude-profiles)

    /// Parse a comma-separated `--exclude-profiles` value into a validated set
    /// of profile slugs. Whitespace-trimmed; empty and invalid tokens dropped.
    static func parseExclusions(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(isValid)
        )
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
        guard resolved.path == root.appendingPathComponent(profile, isDirectory: true).path else {
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

        return decoded.map { item in
            if isValid(item.name) {
                return JamfCLIProfile(
                    name: item.name,
                    url: displayURL(item.url),
                    schedules: scheduleCounts[item.name] ?? 0,
                    status: item.isDefault ? .ok : .idle,
                    authMethod: item.authMethod ?? "",
                    isDefault: item.isDefault
                )
            }
            // Surface invalid-named profiles so the user can see why they
            // appear missing. They cannot be selected for workspace use until
            // renamed in jamf-cli (see SettingsView for greyed-out rendering).
            return JamfCLIProfile(
                name: item.name,
                url: displayURL(item.url),
                schedules: 0,
                status: .error,
                authMethod: "(unsupported name — rename in jamf-cli)",
                isDefault: false
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
