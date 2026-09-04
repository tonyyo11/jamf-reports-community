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

    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// The profile's auth method (lowercased), or nil when it cannot be
    /// determined — no jamf-cli, the probe failed, or the profile is not in
    /// jamf-cli's config. Resolved values are cached for the process lifetime;
    /// unknowns are never cached, so a transient probe failure cannot freeze
    /// the app on "unknown" until relaunch.
    static func resolve(
        profile: String,
        binary: URL? = ExecutableLocator.locate("jamf-cli")
    ) -> String? {
        cacheLock.lock()
        let cached = cache[profile]
        cacheLock.unlock()
        if let cached { return cached }

        guard let binary, let data = configList(binary: binary),
              let method = PlatformCapabilityService.authMethod(data: data, profile: profile)
        else { return nil }

        cacheLock.lock()
        cache[profile] = method
        cacheLock.unlock()
        return method
    }

    /// Drops the cache. Called when profile configuration changes (and by
    /// tests), mirroring `PlatformCapabilityService.refresh()`.
    static func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    /// Runs `config list --output json`, returning nil on any failure. The
    /// pinned environment and codesign gate match every other jamf-cli spawn.
    private static func configList(binary: URL) -> Data? {
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return nil
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["config", "list", "--output", "json"]
        process.environment = CLIBridge.environmentForJamfCLI()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
