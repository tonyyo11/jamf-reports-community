import Foundation

/// What the Data Sources Connection card shows for the active profile.
enum ConnectionCardState: Equatable {
    case member(Connection)
    /// A Platform API profile in no connection; the card offers to start one.
    case canStart
    case hidden

    static func resolve(
        profile: String, authMethod: String, connections: [Connection]
    ) -> ConnectionCardState {
        if let connection = connections.first(where: {
            $0.members.contains { $0.profile == profile }
        }) {
            return .member(connection)
        }
        return ReauthenticateSheet.prefersPlatformGateway(authMethod: authMethod)
            ? .canStart : .hidden
    }
}

/// Starts a Connection from a Platform API profile that is in none.
enum ConnectionStarter {
    static var jamfCLIConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jamf-cli/config.yaml")
    }

    /// Records `profile` as the first member of a connection named after it. The region comes
    /// from the profile's server (`storedURL`, as the profile list shows it) and the ID and
    /// level from jamf-cli's config text when it holds them; otherwise the ID stays blank, the
    /// level is environment, and Update credentials for all skips the member.
    @discardableResult
    static func start(
        profile: String, storedURL: String, configText: String?, store: ConnectionStore
    ) throws -> Connection {
        let region = GatewayRegion.startingURL(fromStored: storedURL)
            .map { Connection.Region.region(forGatewayURL: $0) } ?? .other
        let scope = configText.flatMap {
            DiagnosticBundleService.platformScope(profile: profile, inConfig: $0)
        }
        return try store.recordMember(
            profile: profile, scopeID: scope?.id ?? "", product: .unknown,
            region: region, level: scope?.level ?? .environment)
    }
}
