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
        /// The profile names a tenant (any environment): all a Jamf School profile needs, besides
        /// the Platform URL and credentials, to reach the Platform API.
        var hasTenantID = false
        /// The product the profile logs in to (`ProfileService.derivedProduct`); `.unknown` when
        /// nothing says, which runs like Jamf Pro.
        var product: JamfCLIProduct = .unknown
        /// `product` is the "file was read, so Jamf Pro" default, not something the profile
        /// says (`ProfileService.explicitProduct` found nothing).
        var productIsDefaulted = false

        /// Why a Jamf Pro command must not run on this profile, or nil: only a product known
        /// to be another one (School, Protect, Security Cloud) or an organization-level
        /// integration refuses. `.pro` and `.unknown` run.
        func proRefusal(profile: String, operation: String) -> String? {
            let prefix = "\(operation) is a Jamf Pro command; "
                + "'\(ConfigSchema.displayText(profile))' is "
            if !product.canBeProWorkspace { return prefix + "a \(product.displayName) profile" }
            if isOrganizationLevel {
                return prefix + "an organization-level profile. "
                    + PlatformScopeLevel.organizationLevelReason
            }
            return nil
        }

        /// Why this profile cannot be the `protect.profile` login, or nil: only a product an
        /// explicit signal names as another one refuses. `.protect`, `.unknown` and the Jamf Pro
        /// default (a hand-made Protect login has no `product:` key and a plain host) run.
        func protectRefusal(profile: String) -> String? {
            guard product != .protect, product != .unknown, !productIsDefaulted else { return nil }
            return "'\(ConfigSchema.displayText(profile))' is a \(product.displayName) profile, "
                + "not a Jamf Protect profile"
        }
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
        let entry = ProfileService.readConfigFile(at: configFile)?.first { $0.name == profile }
        let resolved = Resolved(
            authMethod: method,
            isTenantLevel: JamfCLIConfigList.isTenantLevel(data: data, profile: profile)
                ?? false,
            isOrganizationLevel: isOrganizationLevel(data: data, profile: profile, entry: entry),
            hasTenantID: JamfCLIConfigList.hasTenantID(data: data, profile: profile) ?? false,
            product: ProfileService.derivedProduct(
                configProduct: entry?.product, authMethod: method, url: entry?.url,
                configFileRead: entry != nil),
            productIsDefaulted: ProfileService.explicitProduct(
                configProduct: entry?.product, authMethod: method, url: entry?.url) == nil
        )

        cacheLock.lock()
        cache[profile] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// True only when `config list` was read and does not name `profile`: a workspace left by a
    /// setup that never saved its jamf-cli profile, or a profile removed in Terminal. False when
    /// it is listed or jamf-cli could not be asked, which keeps collecting. Collect asks only
    /// after `resolve` came back nil.
    static func isAbsent(
        profile: String,
        binary: URL? = ExecutableLocator.locate("jamf-cli"),
        timeout: TimeInterval = JamfCLIProbe.defaultTimeout
    ) -> Bool {
        guard let binary, let data = configList(binary: binary, timeout: timeout),
              let names = JamfCLIConfigList.names(data: data) else { return false }
        return !names.contains(profile)
    }

    /// `config list` shows no ID for the profile, and the config file, when it holds the profile,
    /// agrees. The file is the second look because this answer blocks the profile: a jamf-cli
    /// that leaves the ID out of `config list` must not make every platform profile organization
    /// level.
    private static func isOrganizationLevel(
        data: Data, profile: String, entry: ProfileService.JamfCLIConfigProfile?
    ) -> Bool {
        guard JamfCLIConfigList.scopeLevel(data: data, profile: profile) == .organization
        else { return false }
        return entry?.platformLevel.map { $0 == .organization } ?? true
    }

    /// The refusal for running a Jamf Pro command on `profile`, or nil to run it. Nil too when
    /// the profile could not be resolved: "could not ask" never blocks (see `resolve`). It runs
    /// `config list` on a cache miss, so callers on the main actor go through `Task.detached`.
    static func refusal(profile: String, operation: String) -> String? {
        resolve(profile: profile)?.proRefusal(profile: profile, operation: operation)
    }

    /// `Resolved.protectRefusal` for `profile`, nil too when it could not be resolved. Resolving
    /// can run `config list`, so it runs detached: callers are often on the main actor.
    static func protectRefusal(
        profile: String,
        resolved: @escaping @Sendable (String) -> Resolved? = { resolve(profile: $0) }
    ) async -> String? {
        await Task.detached { resolved(profile)?.protectRefusal(profile: profile) }.value
    }

    /// Whether `pro auth token` has no meaning for `profile`: API-key auth (Jamf School) or a
    /// product known to be another one. When `config list` cannot be read, a School workspace
    /// (`school_cli` in its config.yaml) or an `apikey` entry in jamf-cli's config file decides;
    /// otherwise the profile is probed as before.
    static func skipsProAuthProbe(
        profile: String, configFile: URL? = ProfileService.defaultConfigFileURL
    ) -> Bool {
        guard let resolved = resolve(profile: profile, configFile: configFile) else {
            let entry = ProfileService.readConfigFile(at: configFile)?.first { $0.name == profile }
            return JamfCLIAuthMethod(raw: entry?.authMethod) == .apiKey
                || ProfileProductType.detect(
                    from: collectRoutingConfig(profile: profile), profile: profile
                ).type == .jamfSchool
        }
        return resolved.method == .apiKey || !resolved.product.canBeProWorkspace
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
            arguments: CLICommand.configList.argv,
            timeout: timeout
        ), output.exitCode == 0 else { return nil }
        return output.stdout
    }
}
