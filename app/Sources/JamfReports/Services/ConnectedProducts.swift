import Foundation

/// The jamf-cli profiles a workspace's config.yaml names besides its own: the Protect
/// connection (`protect.enabled/profile`) and a School login (`school_cli.enabled/profile`)
/// that names another profile. A Jamf School workspace's own profile is not listed: School
/// is that workspace's product, not a connection. Nil is "none": disabled, no profile named,
/// or a config.yaml that is missing or does not decode.
struct ConnectedProducts: Equatable, Sendable {
    var protectProfile: String?
    /// A School profile recorded in a Jamf Pro workspace. The app does not use it there.
    var foreignSchoolProfile: String?

    static let none = ConnectedProducts(protectProfile: nil, foreignSchoolProfile: nil)

    /// `workspace` is the profile whose config.yaml this is.
    static func read(configURL: URL, workspace: String) -> ConnectedProducts {
        guard let config = try? ConfigLoader.load(from: configURL) else { return .none }
        func named(_ enabled: Bool?, _ profile: String?) -> String? {
            guard enabled == true, let name = profile?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return nil }
            return name
        }
        let foreign = config.schoolCli?.isForeign(toWorkspace: workspace) == true
        return ConnectedProducts(
            protectProfile: named(config.protect?.enabled, config.protect?.profile),
            foreignSchoolProfile: foreign ? named(true, config.schoolCli?.profile) : nil
        )
    }

    static func read(profile: String, under root: URL = ProfileService.workspacesRoot())
        -> ConnectedProducts {
        read(configURL: root.appendingPathComponent(ProfileName.pathComponent(profile))
            .appendingPathComponent("config.yaml"), workspace: profile)
    }
}
