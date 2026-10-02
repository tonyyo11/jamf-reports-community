import Foundation

/// Best-effort read of a profile's `security_policy:` block. Never throws: a missing
/// workspace or file degrades to `.default`, today's behaviour. Mirrors `ChartsConfigLoader`,
/// except that an undecodable config.yaml is logged: falling back changes the gap counts.
enum SecurityPolicyConfigLoader {
    static func load(profile: String) -> SecurityControlPolicy {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return .default }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            return try ConfigLoader.load(from: url).resolvedSecurityPolicy
        } catch {
            let file = url.lastPathComponent
            let reason = error.localizedDescription
            AppLogger.report.warning("""
                Security policy: could not decode \(file, privacy: .public), using the default \
                policy: \(reason, privacy: .private)
                """)
            return .default
        }
    }
}
