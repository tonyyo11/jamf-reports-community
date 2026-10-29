import Foundation
import Synchronization

/// Finds an oauth2 profile that reaches the same Jamf Pro instance as a Platform API profile.
///
/// jamf-cli's wiki tells a gateway user to keep an oauth2 profile beside the platform one, for
/// the commands the gateway refuses. Both then look like workspaces, and a fleet is collected
/// and rolled up twice. A platform profile's URL is the gateway, so the instance is learned from
/// Jamf Pro itself (`pro jamf-pro-server-url get`, which the gateway serves, privilege
/// `jss-url:read`) and compared by host with the oauth2 profile's URL.
enum PlatformTwin {

    /// The oauth2 profiles in `profiles` whose host is `jamfProHost`: candidates for the twin
    /// of a platform profile that reaches that instance. Only oauth2 or token profiles that can
    /// be Jamf Pro workspaces count; a platform, School, Protect or unusable profile never does.
    static func twins(
        reaching jamfProHost: String, among profiles: [JamfCLIProfile]
    ) -> [JamfCLIProfile] {
        let wanted = jamfProHost.lowercased()
        return profiles.filter { isCandidate($0) && host(of: $0.url) == wanted }
    }

    /// A profile that could be the oauth2 side of a pair.
    private static func isCandidate(_ profile: JamfCLIProfile) -> Bool {
        let method = profile.auth
        return profile.status != .error && profile.product.canBeProWorkspace
            && (method == .oauth2 || method == .other("token"))
    }

    /// The lowercase host of a profile URL, which may be a bare host as discovery shows it.
    static func host(of url: String?) -> String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let parsed = URL(string: raw.contains("://") ? raw : "https://\(raw)")
        guard let host = parsed?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// The Jamf Pro server URL in `pro jamf-pro-server-url get --output json`
    /// (`{"url":"https://acme.jamfcloud.com"}`). nil for anything else.
    static func jamfProURL(inServerURLOutput data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = (object["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              host(of: url) != nil else { return nil }
        return url
    }

    private static let cache = Mutex<[String: String]>([:])

    /// Asks Jamf Pro, through `profile`'s gateway credential, for its own URL. Blocks, so call it
    /// off the main actor. nil on any failure (no jamf-cli, the probe failed or timed out, a
    /// missing `jss-url:read` privilege, an unreadable answer): a twin is then simply not
    /// found. Successes are cached for the process; failures are not.
    static func learnJamfProURL(
        profile: String,
        binary: URL? = ExecutableLocator.locate("jamf-cli"),
        timeout: TimeInterval = JamfCLIProbe.defaultTimeout
    ) -> String? {
        let cached = cache.withLock { $0[profile] }
        if let cached { return cached }
        guard let binary,
              CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) == nil,
              let output = JamfCLIProbe.run(
                executable: binary,
                arguments: serverURLArguments(profile: profile),
                timeout: timeout),
              output.exitCode == 0,
              let url = jamfProURL(inServerURLOutput: output.stdout) else { return nil }
        cache.withLock { $0[profile] = url }
        return url
    }

    static func serverURLArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "jamf-pro-server-url", "get", "--output", "json", "--no-input"]
    }

    static func invalidateCache() {
        cache.withLock { $0.removeAll() }
    }

    /// The oauth2 twins of one platform profile, from its learned Jamf Pro URL.
    static func twins(
        ofPlatformProfile platform: JamfCLIProfile,
        among profiles: [JamfCLIProfile],
        learn: (String) -> String?
    ) -> (url: String, twins: [JamfCLIProfile])? {
        let others = profiles.filter { $0.name != platform.name }
        // Jamf Pro is asked only when there is an oauth2 profile it could match.
        guard platform.auth?.isPlatform == true, !platform.isOrganizationLevel,
              others.contains(where: isCandidate),
              let url = learn(platform.name), let host = host(of: url) else { return nil }
        let found = twins(reaching: host, among: others)
        return found.isEmpty ? nil : (url, found)
    }
}
