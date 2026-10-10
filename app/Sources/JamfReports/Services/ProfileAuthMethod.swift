import Foundation

/// Resolves a jamf-cli profile's `auth-method` — the fact that decides whether
/// the Platform API kinds can ever succeed for that profile.
///
/// Tri-state on purpose: `nil` means "unknown", never "not platform".
/// `PlatformCapabilityService` collapses the same probe to a Bool because it
/// only gates a Settings toggle; collect and the health strip need the
/// difference between "this profile is oauth2" and "we could not ask", since
/// only the first justifies skipping a kind.
enum ProfileAuthMethod {

    struct Resolved: Equatable, Sendable {
        /// Lowercased, for example `platform` or `oauth2`.
        let authMethod: String
        /// A Platform API profile whose integration is tenant level.
        let isTenantLevel: Bool
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
        timeout: TimeInterval = JamfCLIProbe.defaultTimeout
    ) -> Resolved? {
        cacheLock.lock()
        let cached = cache[profile]
        cacheLock.unlock()
        if let cached { return cached }

        guard let binary, let data = configList(binary: binary, timeout: timeout),
              let method = PlatformCapabilityService.authMethod(data: data, profile: profile)
        else { return nil }
        let resolved = Resolved(
            authMethod: method,
            isTenantLevel: PlatformCapabilityService.isTenantLevel(data: data, profile: profile)
                ?? false
        )

        cacheLock.lock()
        cache[profile] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Drops the cache. Called when profile configuration changes (and by
    /// tests), mirroring `PlatformCapabilityService.refresh()`.
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
