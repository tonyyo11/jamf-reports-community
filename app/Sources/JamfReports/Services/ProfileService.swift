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
                return ProfileName.invalidMessage(profile)
            case .outsideWorkspaceRoot(let url):
                return "Refusing to remove workspace outside \(workspacesRoot().path): \(url.path)"
            }
        }
    }

    /// One profile of jamf-cli's config, read from `config list -o json` or the config file.
    /// The environment and tenant IDs are reduced to `platformLevel` on decode and not kept.
    struct JamfCLIConfigProfile: Decodable {
        let name: String
        let url: String?
        let authMethod: String?
        let isDefault: Bool
        /// The file's `product:` key; `config list` does not print it.
        var product: String?
        var platformLevel: PlatformScopeLevel?

        private enum CodingKeys: String, CodingKey {
            case name
            case url
            case authMethod = "auth-method"
            case isDefault = "default"
            case environmentID = "environment-id"
            case tenantID = "tenant-id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            product = nil
            platformLevel = Self.level(
                authMethod: authMethod,
                environmentID: try container.decodeIfPresent(String.self, forKey: .environmentID),
                tenantID: try container.decodeIfPresent(String.self, forKey: .tenantID))
        }

        init(
            name: String, url: String?, authMethod: String?, isDefault: Bool,
            product: String? = nil, platformLevel: PlatformScopeLevel? = nil
        ) {
            self.name = name
            self.url = url
            self.authMethod = authMethod
            self.isDefault = isDefault
            self.product = product
            self.platformLevel = platformLevel
        }

        /// Only a platform profile has a scope level.
        static func level(
            authMethod: String?, environmentID: String?, tenantID: String?
        ) -> PlatformScopeLevel? {
            guard JamfCLIAuthMethod(raw: authMethod)?.isPlatform == true else { return nil }
            return PlatformScopeLevel.level(environmentID: environmentID, tenantID: tenantID)
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

    /// Configured profiles Jamf Reports can't use. Where workspace folders spelled like a name
    /// (any case) exist, the bind, collect and backup rule decides (`caseVariantWorkspace`): a
    /// name is unusable when a folder of another spelling exists, judged by the folders' own
    /// names, never config.yaml. With no folder, of names that differ only by case the
    /// all-lowercase spelling (the only one older builds accepted) keeps it, else the first
    /// listed. `folderNames` maps a `ProfileName.folderKey` to the names its folders encode.
    static func unusableProfiles(
        in names: [String],
        folderNames: (String) -> [String] = workspaceFolderNames(matching:)
    ) -> [String: UnusableReason] {
        var reasons: [String: UnusableReason] = [:]
        for name in names {
            if let problem = ProfileName.problem(with: name) {
                reasons[name] = .unsupportedName(problem)
            }
        }
        let spellings = Dictionary(grouping: names.filter(isValid), by: ProfileName.folderKey)
        for (key, group) in spellings {
            let folders = folderNames(key)
            if !folders.isEmpty {
                for name in group {
                    if let other = caseVariant(of: name, among: folders) {
                        reasons[name] = .sharesFolder(with: other)
                    }
                }
                continue
            }
            guard group.count > 1 else { continue }
            let owner = group.first { $0 == key } ?? group[0]
            for name in group where name != owner {
                reasons[name] = .sharesFolder(with: owner)
            }
        }
        return reasons
    }

    /// The names the existing workspace folders spelled like `key` (any case) encode, case
    /// preserved. More than one only on a case-sensitive volume.
    static func workspaceFolderNames(matching key: String) -> [String] {
        workspaceFolders(matching: key).map(\.name)
    }

    /// The one folder rule: another spelling's folder `name` would share.
    private static func caseVariant(of name: String, among folders: [String]) -> String? {
        folders.first { $0 != name }
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

    /// True when the owner a workspace's config.yaml names is another profile
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

    /// Path to a specific workspace (`WorkspacePaths.workspaceURL`). Returns nil for invalid names.
    static func workspaceURL(for profile: String) -> URL? {
        WorkspaceID(profile).map { WorkspacePaths.workspaceURL(for: $0) }
    }

    /// Why nothing may run for `profile`: its workspace folder is another spelling's
    /// (`caseVariantWorkspace`), whatever config.yaml says. Nil when the folder is its own.
    static func caseVariantRefusal(of profile: String) -> String? {
        caseVariantWorkspace(of: profile).map {
            CLIBridgeError.profileCaseConflict(profile: profile, owner: $0).localizedDescription
        }
    }

    /// The profile of an existing workspace folder spelled like `profile` apart from
    /// letter case. On a case-insensitive volume it is `profile`'s folder as well.
    static func caseVariantWorkspace(of profile: String) -> String? {
        caseVariant(
            of: profile, among: workspaceFolderNames(matching: ProfileName.folderKey(profile)))
    }

    /// Discover real profiles from `jamf-cli config list` first, then merge in
    /// local `~/Jamf-Reports/<profile>/config.yaml` workspaces. Returns sorted by
    /// default profile first, then by name. In demo mode, the caller falls back
    /// to `DemoData.cliProfiles`.
    static func discoverLocal(keeping active: Set<String> = []) -> [JamfCLIProfile] {
        let scheduleCounts = Dictionary(
            grouping: ScheduleStore().load().filter { !$0.allWorkspaces }, by: \.workspace
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
        return droppingPairedProductProfiles(profiles.sorted(by: profileSort), keeping: active)
    }

    /// Drops a jamf-cli profile that is not a workspace of its own: another workspace's Protect
    /// connection or foreign School login (connecting Protect creates a second jamf-cli profile
    /// and names it in `protect.profile`; earlier builds did the same for Jamf School in
    /// `school_cli.profile`), and a Protect or Security Cloud login whatever names it
    /// (`JamfCLIProfile.product`). None of these holds Jamf Pro data, so listing one offers an
    /// empty workspace and makes `--all-profiles` runs collect Jamf Pro data against it. A
    /// paired profile with its own `config.yaml` stays, as does one in `keeping` (the active
    /// one). A Protect or Security Cloud login is dropped even then: its Protect data lives in
    /// the Jamf Pro workspace that names it, and a folder of its own (made by a catch-up,
    /// scheduled run or click on 2.9.0) holds nothing the app reads. The folder is left alone.
    static func droppingPairedProductProfiles(
        _ profiles: [JamfCLIProfile],
        under root: URL = workspacesRoot(),
        keeping active: Set<String> = []
    ) -> [JamfCLIProfile] {
        var paired = Set<String>()
        for profile in profiles where hasWorkspace(profile.name, under: root) {
            let environment = EnvironmentProfiles.read(workspace: profile.name, under: root)
            for name in environment.connectedProfiles where name != profile.name {
                paired.insert(name)
            }
        }
        return profiles.filter { profile in
            if profile.product.isNeverAWorkspace { return false }
            guard paired.contains(profile.name) else { return true }
            return active.contains(profile.name) || hasWorkspace(profile.name, under: root)
        }
    }

    /// True when `name` has a workspace folder under `root` holding a `config.yaml`.
    static func hasWorkspace(_ name: String, under root: URL = workspacesRoot()) -> Bool {
        guard let id = WorkspaceID(name) else { return false }
        let config = WorkspacePaths.workspaceURL(for: id, under: root)
            .appendingPathComponent("config.yaml")
        return FileManager.default.fileExists(atPath: config.path)
    }

    /// Profiles of the workspace folders under `root` (holding a `config.yaml`) that no
    /// jamf-cli profile names. Compared by folder key: on a case-insensitive volume a
    /// folder spelled unlike a profile is still that profile's folder. A folder whose config
    /// names another owner (`EnvironmentProfiles.namedOwner`) is a copy (Finder's `prod copy`),
    /// not a workspace of its own.
    static func localOnlyWorkspaces(under root: URL, cliNames: [String]) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let claimed = Set(cliNames.map(ProfileName.folderKey))
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { folder -> String? in
                let config = folder.appendingPathComponent("config.yaml")
                guard FileManager.default.fileExists(atPath: config.path),
                      let name = ProfileName.name(fromPathComponent: folder.lastPathComponent),
                      isValid(name), !claimed.contains(ProfileName.folderKey(name))
                else { return nil }
                let owner = EnvironmentProfiles.read(configURL: config, workspace: name)
                    .namedOwner
                let namesAnother = owner.map {
                    ProfileName.folderKey($0) != ProfileName.folderKey(name)
                } ?? false
                return namesAnother ? nil : name
            }
    }

    /// Workspaces whose jamf-cli profile does not exist: a setup left part way, or a profile
    /// removed in Terminal. Empty when jamf-cli's list could not be read (`listed` nil), since
    /// "could not ask" must not stop every workspace collecting.
    static func workspacesMissingJamfCLIProfile(
        listed: [String]? = listJamfCLIProfiles(scheduleCounts: [:])?.map(\.name),
        under root: URL = workspacesRoot()
    ) -> Set<String> {
        guard let listed else { return [] }
        return Set(localOnlyWorkspaces(under: root, cliNames: listed))
    }

    /// The profiles a multi-profile run collects: exclusions applied, and the
    /// `.error` ones dropped. Discovery marks a profile the app can't use that way
    /// (unsupported name, or a case variant sharing another's folder); it has no
    /// workspace in which to run, and counting it failed every run of the schedule.
    /// A Protect or Security Cloud login is never run. A Jamf School login or an
    /// organization-level Platform integration is left out until it has a workspace of its
    /// own (which is how it keeps running as before).
    static func runnableProfiles(
        _ profiles: [JamfCLIProfile],
        excluding excluded: Set<String>,
        hasWorkspace: (String) -> Bool = { ProfileService.hasWorkspace($0) }
    ) -> [JamfCLIProfile] {
        applyingExclusions(profiles, excluding: excluded).filter { profile in
            guard profile.status != .error, !profile.product.isNeverAWorkspace else { return false }
            let needsWorkspace = profile.product == .school || profile.isOrganizationLevel
            return !needsWorkspace || hasWorkspace(profile.name)
        }
    }

    // MARK: - Command-line arguments

    /// The `--profile` value of `--scheduled-run`, given as `--profile <name>` or as
    /// `--profile=<name>`, the form a name starting with `-` needs. A separate value starting
    /// with `--` is another flag, not the profile (`--profile --all-profiles`).
    static func profileArgument(in args: [String]) -> String? {
        if let joined = args.first(where: { $0.hasPrefix("--profile=") }) {
            return String(joined.dropFirst("--profile=".count))
        }
        guard let index = args.firstIndex(of: "--profile"), index + 1 < args.count,
              !args[index + 1].hasPrefix("--") else { return nil }
        return args[index + 1]
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
        let url = try confinedWorkspaceFolder(profile: profile)
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            return false
        }
    }

    /// Moves one local workspace folder to the Trash, under the same path checks as
    /// `removeLocalWorkspace`. False when there is no folder.
    @discardableResult
    static func trashLocalWorkspace(
        profile: String,
        trash: (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) throws -> Bool {
        let url = try confinedWorkspaceFolder(profile: profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try trash(url)
        return true
    }

    /// `profile`'s workspace folder, refused unless it resolves to a direct child of the root.
    private static func confinedWorkspaceFolder(profile: String) throws -> URL {
        guard let id = WorkspaceID(profile) else {
            throw CleanupError.invalidProfile(profile)
        }
        let url = WorkspacePaths.workspaceURL(for: id)
        let root = workspacesRoot().resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let expected = WorkspacePaths.workspaceURL(for: id, under: root)
        guard resolved.path == expected.path else {
            throw CleanupError.outsideWorkspaceRoot(url)
        }
        guard resolved.deletingLastPathComponent().standardizedFileURL.path == root.path else {
            throw CleanupError.outsideWorkspaceRoot(url)
        }
        return url
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
        _testBinaryOverride: URL? = nil,
        _testTimeout: TimeInterval = JamfCLIProbe.defaultTimeout,
        _testConfigURL: URL? = nil
    ) -> [JamfCLIProfile] {
        listJamfCLIProfiles(
            scheduleCounts: scheduleCounts, _testBinaryOverride: _testBinaryOverride,
            _testTimeout: _testTimeout, _testConfigURL: _testConfigURL) ?? []
    }

    /// `discoverJamfCLIProfiles`, but nil when neither `config list` nor jamf-cli's config file
    /// could be read: "could not ask", which is not the same answer as "has no profiles". A
    /// caller that acts on a profile being absent (Start over's "was this profile new?") must
    /// treat nil as unknown.
    static func listJamfCLIProfiles(
        scheduleCounts: [String: Int],
        _testBinaryOverride: URL? = nil,
        _testTimeout: TimeInterval = JamfCLIProbe.defaultTimeout,
        _testConfigURL: URL? = nil
    ) -> [JamfCLIProfile]? {
        #if DEBUG
        // A test never reads this Mac's jamf-cli config file, the fallback when no
        // jamf-cli is found; one that checks discovery passes its own binary.
        if _testBinaryOverride == nil, NSClassFromString("XCTestCase") != nil { return nil }
        #endif
        let fallback: () -> [JamfCLIProfile]? = {
            if let url = _testConfigURL {
                return fallbackConfigProfiles(scheduleCounts: scheduleCounts, configURL: url)
            }
            return fallbackConfigProfiles(scheduleCounts: scheduleCounts)
        }
        guard let binary = _testBinaryOverride ?? ExecutableLocator.locate("jamf-cli") else {
            return fallback()
        }

        // M-01: refuse to spawn a tampered jamf-cli even for `config list`.
        // Fall back to reading jamf-cli's config file directly —
        // the same recovery path used when the binary is absent or launch
        // fails. The user still sees their profiles; nothing un-trusted runs.
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return fallback()
        }

        // SF-10/B-13: JamfCLIProbe pins a minimal environment so DYLD_*, SSL_CERT_FILE,
        // JAMF_CLI_* etc. inherited from the parent can't alter how jamf-cli resolves its
        // config or validates TLS. It also drains both pipes, gives the child no stdin and
        // stops it at the deadline; a wedged `config list` must not freeze the sidebar load.
        guard let output = JamfCLIProbe.run(
            executable: binary,
            arguments: CLICommand.configList.argv,
            timeout: _testTimeout
        ), output.exitCode == 0 else {
            return fallback()
        }
        let data = output.stdout

        guard let decoded = try? JSONDecoder().decode([JamfCLIConfigProfile].self, from: data) else {
            return fallback()
        }
        // `config list` leaves out the `product:` key; the file has it.
        let fromFile = readConfigFile(at: _testConfigURL ?? defaultConfigFileURL)
        return rows(
            for: merging(listed: decoded, fromFile: fromFile),
            scheduleCounts: scheduleCounts, configFileRead: fromFile != nil)
    }

    /// Profiles Jamf Reports can't use stay listed, marked `.error` with the
    /// reason, so the user can see why they do nothing (SettingsView greys them
    /// out, the setup screen won't initialize them, WorkspaceStore never makes one
    /// active, multi-profile runs and catch-up skip them).
    private static func rows(
        for configured: [JamfCLIConfigProfile],
        scheduleCounts: [String: Int],
        configFileRead: Bool
    ) -> [JamfCLIProfile] {
        let unusable = unusableProfiles(in: configured.map(\.name))
        return configured.map { item in
            if let reason = unusable[item.name] {
                return JamfCLIProfile(
                    name: item.name,
                    url: displayURL(item.url),
                    schedules: 0,
                    status: .error,
                    authMethod: item.authMethod ?? "",
                    isDefault: false,
                    unusableReason: reason.label
                )
            }
            return JamfCLIProfile(
                name: item.name,
                url: displayURL(item.url),
                schedules: scheduleCounts[item.name] ?? 0,
                status: item.isDefault ? .ok : .idle,
                authMethod: item.authMethod ?? "",
                isDefault: item.isDefault,
                product: derivedProduct(
                    configProduct: item.product, authMethod: item.authMethod,
                    url: item.url, configFileRead: configFileRead),
                platformLevel: item.platformLevel
            )
        }
    }

    // MARK: - Product

    /// The product a profile logs in to, first answer wins: (a) the `product:` key in jamf-cli's
    /// config file (`pro`, `protect`, `school`, `security`, which is Jamf Pro on a `platform`
    /// profile; a value this build does not know is `.unknown`, never Pro); (b) the auth method, where `apikey` is Jamf School (`school
    /// setup`), `security` is Security Cloud (`security setup`) and `platform` is Jamf Pro;
    /// (c) the host, where `*.protect.jamfcloud.com` is Protect and `*.jamfschool.com` is Jamf
    /// School. Protect's `protect setup` writes plain `oauth2`, so only (a) and (c) can tell it
    /// from Jamf Pro. Nothing says: Jamf Pro when the file was read, since jamf-cli treats an
    /// absent `product:` as `pro`; otherwise `.unknown`, which is handled like Jamf Pro.
    static func derivedProduct(
        configProduct: String?, authMethod: String?, url: String?, configFileRead: Bool
    ) -> JamfCLIProduct {
        explicitProduct(configProduct: configProduct, authMethod: authMethod, url: url)
            ?? (configFileRead ? .pro : .unknown)
    }

    /// The product an explicit signal names, or nil when nothing does and `derivedProduct`
    /// falls back to its default: (a) to (c) above.
    static func explicitProduct(
        configProduct: String?, authMethod: String?, url: String?
    ) -> JamfCLIProduct? {
        switch configProduct?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" {
        case "": break
        case "pro": return .pro
        case "protect": return .protect
        case "school": return .school
        case "security":
            // `security setup` on a Platform API profile keeps `platform`: jamf-cli still
            // serves `pro` through the gateway, so the merged login is a Jamf Pro workspace.
            return JamfCLIAuthMethod(raw: authMethod) == .platform ? .pro : .securityCloud
        default: return .unknown
        }
        switch JamfCLIAuthMethod(raw: authMethod) {
        case .apiKey: return .school
        case .security: return .securityCloud
        case .platform: return .pro
        default: break
        }
        if let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) {
            if host.hasSuffix(".protect.jamfcloud.com") { return .protect }
            if host.hasSuffix(".jamfschool.com") { return .school }
        }
        return nil
    }

    /// `listed` (from `config list`) with each profile's `product:` key from the config file. A
    /// list row without a scope ID reads as organization level, the one answer that blocks a
    /// profile, so it is confirmed against the file whenever the file holds the profile: jamf-cli
    /// versions that print no ID in `config list` must not turn every platform profile into one.
    static func merging(
        listed: [JamfCLIConfigProfile], fromFile: [JamfCLIConfigProfile]?
    ) -> [JamfCLIConfigProfile] {
        guard let fromFile else { return listed }
        let byName = Dictionary(
            fromFile.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return listed.map { item in
            guard let entry = byName[item.name] else { return item }
            var merged = item
            merged.product = entry.product
            if item.platformLevel == .organization, let level = entry.platformLevel {
                merged.platformLevel = level
            }
            return merged
        }
    }

    /// `XDG_CONFIG_HOME` when `environment` sets it to an absolute path; jamf-cli ignores a
    /// relative one, so the app does too.
    nonisolated static func absoluteXDGConfigHome(in environment: [String: String]) -> String? {
        guard let value = environment["XDG_CONFIG_HOME"], value.hasPrefix("/") else { return nil }
        return value
    }

    /// The one place jamf-cli's config file path is built: `$XDG_CONFIG_HOME/jamf-cli/config.yaml`
    /// when that variable is absolute, else `~/.config/jamf-cli/config.yaml`. The app passes the
    /// variable to jamf-cli (`CLIBridge.environmentForJamfCLI`), so both read the same file.
    nonisolated static func jamfCLIConfigFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = absoluteXDGConfigHome(in: environment).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("jamf-cli/config.yaml")
    }

    /// jamf-cli's config file (see `jamfCLIConfigFileURL`). nil in a test process, which never
    /// reads the real file.
    static var defaultConfigFileURL: URL? {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { return nil }
        #endif
        return jamfCLIConfigFileURL()
    }

    /// The file is credentials-adjacent: it holds keychain references, and a user may have
    /// pasted a literal secret into it. Read at most this many bytes, and keep only the keys
    /// `parseConfigFile` names.
    static let maxConfigFileBytes = 1_048_576

    /// The text of jamf-cli's config file, or nil when it is missing, not a regular file, over
    /// `maxConfigFileBytes` or not UTF-8. The one reader: `$XDG_CONFIG_HOME` can point it at a
    /// folder anyone can write, so no caller reads the file unbounded.
    nonisolated static func readConfigFileText(at url: URL?) -> String? {
        guard let url, let data = try? BoundedFile.read(url, limit: maxConfigFileBytes)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The profiles in jamf-cli's config file, or nil when `readConfigFileText` gives none.
    static func readConfigFile(at url: URL?) -> [JamfCLIConfigProfile]? {
        readConfigFileText(at: url).map(parseConfigFile)
    }

    /// Reads profiles straight from jamf-cli's config file when `config list` can't run; nil
    /// when the file can't be read. `configURL` is a test seam; production callers omit it.
    static func fallbackConfigProfiles(
        scheduleCounts: [String: Int],
        configURL: URL = ProfileService.jamfCLIConfigFileURL()
    ) -> [JamfCLIProfile]? {
        guard let configured = readConfigFile(at: configURL) else { return nil }
        return rows(for: configured, scheduleCounts: scheduleCounts, configFileRead: true)
    }

    /// The `profiles:` of jamf-cli's config file: name, url, auth-method, product and scope
    /// level, and the file's `default-profile`. Indentation is relative (jamf-cli writes four
    /// spaces, its wiki shows two), and keys nested under a profile are skipped. Only the
    /// keys above are kept; a credential key is never stored.
    static func parseConfigFile(_ text: String) -> [JamfCLIConfigProfile] {
        struct Pending {
            var name: String
            var values: [String: String] = [:]
        }
        let defaultProfile = firstScalar("default-profile", in: text)
        let kept: Set<String> = ["url", "auth-method", "product", "environment-id", "tenant-id"]
        var configured: [JamfCLIConfigProfile] = []
        var pending: Pending?
        var nameIndent: Int?
        var keyIndent: Int?
        var inProfiles = false

        func flush() {
            guard let item = pending else { return }
            let auth = item.values["auth-method"]
            configured.append(JamfCLIConfigProfile(
                name: item.name, url: item.values["url"], authMethod: auth,
                isDefault: item.name == defaultProfile, product: item.values["product"],
                platformLevel: JamfCLIConfigProfile.level(
                    authMethod: auth, environmentID: item.values["environment-id"],
                    tenantID: item.values["tenant-id"])))
            pending = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "profiles:" {
                inProfiles = true
                continue
            }
            guard inProfiles, !line.isEmpty, !line.hasPrefix("#") else { continue }
            let indent = rawLine.prefix { $0 == " " }.count
            if indent == 0 { break }
            if nameIndent == nil { nameIndent = indent }
            if indent == nameIndent, line.hasSuffix(":") {
                flush()
                pending = Pending(name: unquotedYAMLKey(String(line.dropLast())))
                keyIndent = nil
            } else if indent > (nameIndent ?? indent), pending != nil,
                      let colon = line.firstIndex(of: ":") {
                if keyIndent == nil { keyIndent = indent }
                guard indent == keyIndent else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard kept.contains(key) else { continue }
                pending?.values[key] = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        flush()
        return configured
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
