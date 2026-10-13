import Foundation

/// The Protect and Jamf School connections a workspace's config.yaml records
/// (`protect.enabled/profile`, `school_cli.enabled/profile`). Nil is "not connected":
/// disabled, no profile named, or a config.yaml that is missing or does not decode.
struct ConnectedProducts: Equatable, Sendable {
    var protectProfile: String?
    var schoolProfile: String?

    static let none = ConnectedProducts(protectProfile: nil, schoolProfile: nil)

    static func read(configURL: URL) -> ConnectedProducts {
        guard let config = try? ConfigLoader.load(from: configURL) else { return .none }
        func named(_ enabled: Bool?, _ profile: String?) -> String? {
            guard enabled == true, let name = profile?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return nil }
            return name
        }
        return ConnectedProducts(
            protectProfile: named(config.protect?.enabled, config.protect?.profile),
            schoolProfile: named(config.schoolCli?.enabled, config.schoolCli?.profile)
        )
    }

    static func read(profile: String, under root: URL = ProfileService.workspacesRoot())
        -> ConnectedProducts {
        read(configURL: root.appendingPathComponent(ProfileName.pathComponent(profile))
            .appendingPathComponent("config.yaml"))
    }
}
