import Foundation

/// Reads `jamf-cli config list --output json`: a profile's `auth-method` and Platform scope
/// level. `ProfileAuthMethod` (headless: collect, tick, the CLI, Config Doctor) parses its probe
/// through these; the GUI reads the same facts from `WorkspaceStore.profiles`, which profile
/// discovery fills from the same command (2.10: this replaced `PlatformCapabilityService`, a
/// second probe of the command that DDM and Compliance Benchmarks ran).
enum JamfCLIConfigList {
    /// The matching profile's `auth-method` (`JamfCLIAuthMethod.rawValue`), or nil when the
    /// response is unreadable, the profile is absent, or the field is empty. `ProfileAuthMethod`
    /// needs that nil: unknown is not the same answer as oauth2, and only the second may be
    /// acted on.
    nonisolated static func authMethod(data: Data, profile: String) -> String? {
        guard let entry = entry(data: data, profile: profile) else { return nil }
        return JamfCLIAuthMethod(raw: field("auth-method", in: entry))?.rawValue
    }

    /// True when the matching profile names a tenant and no environment: a tenant-level Platform
    /// API integration. nil when the response is unreadable or the profile is absent.
    nonisolated static func isTenantLevel(data: Data, profile: String) -> Bool? {
        guard let entry = entry(data: data, profile: profile) else { return nil }
        let tenant = field("tenant-id", in: entry)
        return !tenant.isEmpty && field("environment-id", in: entry).isEmpty
    }

    /// The level of a Platform API profile: environment, tenant, or organization when it names
    /// neither ID (a Jamf Account-only integration, which reaches no Jamf Pro data). nil when
    /// the response is unreadable, the profile is absent, or it is not a platform profile.
    nonisolated static func scopeLevel(data: Data, profile: String) -> PlatformScopeLevel? {
        guard let entry = entry(data: data, profile: profile),
              JamfCLIAuthMethod(raw: field("auth-method", in: entry))?.isPlatform == true
        else { return nil }
        return PlatformScopeLevel.level(
            environmentID: field("environment-id", in: entry),
            tenantID: field("tenant-id", in: entry))
    }

    /// The `config list` row for `profile`, or the `default: true` row when `profile` is empty.
    private nonisolated static func entry(data: Data, profile: String) -> [String: Any]? {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        return entries.first { entry in
            profile.isEmpty
                ? (entry["default"] as? Bool) ?? false
                : (entry["name"] as? String) == profile
        }
    }

    private nonisolated static func field(_ key: String, in entry: [String: Any]) -> String {
        ((entry[key] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }
}
