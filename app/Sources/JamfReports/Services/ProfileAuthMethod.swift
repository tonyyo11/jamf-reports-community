import Foundation

/// Resolves a jamf-cli profile's `auth-method` — the fact that decides whether
/// the Platform API kinds can ever succeed for that profile.
///
/// Tri-state on purpose: `nil` means "unknown", never "not platform": collect and the health
/// strip need the difference between "this profile is oauth2" and "we could not ask", since
/// only the first justifies skipping a kind. The GUI reads the same fact from
/// `WorkspaceStore.profiles` (`JamfCLIProfile.auth`); both parse `config list` through
/// `JamfCLIConfigList` and type it as `JamfCLIAuthMethod`.
enum ProfileAuthMethod {

    struct Resolved: Equatable, Sendable {
        /// As jamf-cli reports it, for example `platform` or `oauth2`, as `[skip]` lines word it.
        let authMethod: String
        /// The typed value; compare this, never `authMethod`.
        var method: JamfCLIAuthMethod? { JamfCLIAuthMethod(raw: authMethod) }
        /// A Platform API profile whose integration is tenant level.
        let isTenantLevel: Bool
        /// A Platform API profile that names neither an environment nor a tenant: it reaches
        /// Jamf Account only, so no Jamf Pro report can come back.
        var isOrganizationLevel = false
    }

    nonisolated(unsafe) private static var cache: [String: Resolved] = [:]
    private static let cacheLock = NSLock()

    /// The profile's auth method and scope level, or nil when they cannot be
    /// determined — no jamf-cli, the probe failed, or the profile is not in
    /// jamf-cli's config. Resolved values are cached for the process lifetime;
    /// unknowns are never cached, so a transient probe failure cannot freeze
    /// the app on "unknown" until relaunch.
    static func resolve(
        profile: String,
        binary: URL? = ExecutableLocator.locate("jamf-cli"),
        timeout: TimeInterval = JamfCLIProbe.defaultTimeout,
        configFile: URL? = ProfileService.defaultConfigFileURL
    ) -> Resolved? {
        cacheLock.lock()
        let cached = cache[profile]
        cacheLock.unlock()
        if let cached { return cached }

        guard let binary, let data = configList(binary: binary, timeout: timeout),
              let method = JamfCLIConfigList.authMethod(data: data, profile: profile)
        else { return nil }
        let resolved = Resolved(
            authMethod: method,
            isTenantLevel: JamfCLIConfigList.isTenantLevel(data: data, profile: profile)
                ?? false,
            isOrganizationLevel: isOrganizationLevel(
                data: data, profile: profile, configFile: configFile)
        )

        cacheLock.lock()
        cache[profile] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// `config list` shows no ID for the profile, and the config file, when it holds the profile,
    /// agrees. The file is the second look because this answer blocks the profile: a jamf-cli
    /// that leaves the ID out of `config list` must not make every platform profile organization
    /// level.
    private static func isOrganizationLevel(data: Data, profile: String, configFile: URL?) -> Bool {
        guard JamfCLIConfigList.scopeLevel(data: data, profile: profile) == .organization
        else { return false }
        let entry = ProfileService.readConfigFile(at: configFile)?.first { $0.name == profile }
        return entry?.platformLevel.map { $0 == .organization } ?? true
    }

    /// Drops the cache. Called when profile configuration changes (and by
    /// tests), mirroring `JamfCLIConfigList.refresh()`.
    static func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    /// Runs `config list --output json`, returning nil on any failure, including a run that
    /// had to be stopped at `timeout`. The pinned environment and codesign gate match every
    /// other jamf-cli spawn; `JamfCLIProbe` drains both pipes and gives the child no stdin.
    private static func configList(binary: URL, timeout: TimeInterval) -> Data? {
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return nil
        }
        guard let output = JamfCLIProbe.run(
            executable: binary,
            arguments: ["config", "list", "--output", "json"],
            timeout: timeout
        ), output.exitCode == 0 else { return nil }
        return output.stdout
    }
}
