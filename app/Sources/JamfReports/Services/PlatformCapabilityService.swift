import Foundation

/// Probes `jamf-cli config list --output json` to determine whether a configured
/// profile is using `auth-method: platform` — the prerequisite for v2.1.0's
/// Platform API features (compliance benchmarks, DDM blueprints).
///
/// Results are cached per-profile for the service lifetime. Profile state is
/// invalidated by calling `refresh()`; SettingsView calls that whenever the user
/// changes profile configuration so a freshly-platform-enabled profile gets
/// re-probed rather than stuck on a stale `false`.
///
/// All failure modes return `false` rather than throwing — the probe is a UX
/// hint that gates a toggle in Settings, not a security check. Callers that
/// need a hard "the feature is allowed" decision combine this with the
/// `ExperimentalFeatureService.platformAPI` flag.
@MainActor
@Observable
final class PlatformCapabilityService {
    private var cache: [String: Bool] = [:]
    private let executor: CLIExecutor

    init(executor: CLIExecutor) {
        self.executor = executor
    }

    /// True if the named profile (or the default profile when `profile`
    /// is empty) has `auth-method: platform`. Cached after the first call
    /// per-profile; call `refresh()` to drop the cache.
    func isAvailable(for profile: String) async -> Bool {
        if let cached = cache[profile] {
            return cached
        }
        let result = await Self.probe(profile: profile, executor: executor)
        cache[profile] = result
        return result
    }

    /// Drops the per-profile cache. Call after the user mutates jamf-cli
    /// profile config (e.g. via `jamf-cli config add-profile`).
    func refresh() {
        cache.removeAll()
    }

    // MARK: - Probe

    /// Runs the `config list` command and decides whether the requested
    /// profile reports `auth-method: platform`. Static so unit tests can
    /// exercise the parser without an instance.
    static func probe(profile: String, executor: CLIExecutor) async -> Bool {
        let data: Data
        do {
            data = try await executor.execute(.configList)
        } catch {
            return false
        }
        return parseAuthMethod(data: data, profile: profile)
    }

    /// Decodes the `jamf-cli config list` response and returns true iff the
    /// matching profile uses `auth-method: platform`. When `profile` is empty,
    /// the entry with `default: true` is used. Internal-static for testability.
    static func parseAuthMethod(data: Data, profile: String) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let entries = json as? [[String: Any]] else {
            return false
        }
        for entry in entries {
            let name = (entry["name"] as? String) ?? ""
            let isDefault = (entry["default"] as? Bool) ?? false
            let matches = profile.isEmpty ? isDefault : (name == profile)
            guard matches else { continue }
            let auth = (entry["auth-method"] as? String) ?? ""
            return auth.lowercased() == "platform"
        }
        return false
    }
}
