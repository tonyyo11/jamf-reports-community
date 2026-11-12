import Foundation

/// Which products each demo workspace holds, as a `profiles:` block would name them. The tabs,
/// the Environment card, the Protect screen, Trends and Fleet Overview all read these, so the
/// workspace picked in demo mode changes them as a live environment would. Reads no disk.
extension DemoData {

    /// meridian-prod: Jamf Pro, the Platform API and Jamf Protect. meridianedu: Jamf School.
    /// meridian-sandbox: Jamf Pro. meridian-msp: Jamf Pro and Jamf Protect. A name that is not a
    /// demo workspace reads as meridian-prod, which every other demo screen describes.
    static func environmentProfiles(for workspace: String) -> EnvironmentProfiles {
        var profiles = EnvironmentProfiles()
        profiles.source = .profilesBlock
        switch workspace {
        case "meridianedu":
            profiles.jamfSchool = workspace
        case "meridian-sandbox":
            profiles.jamfPro = workspace
        case "meridian-msp":
            profiles.jamfPro = workspace
            profiles.protect = "\(workspace)-protect"
        default:
            profiles.jamfPro = org.profile
            profiles.platform = "\(org.profile)-platform"
            profiles.protect = "\(org.profile)-protect"
        }
        profiles.namedOwner = profiles.mdm
        return profiles
    }

    /// meridian-prod and meridianedu hold Macs and mobile devices; the two smaller Jamf Pro
    /// servers hold Macs only.
    static func composition(for workspace: String) -> EnvironmentComposition {
        ["meridian-sandbox", "meridian-msp"].contains(workspace) ? .macsOnly : composition
    }

    static func environmentProducts(for workspace: String) -> EnvironmentProducts {
        EnvironmentProducts.from(
            environmentProfiles(for: workspace), composition: composition(for: workspace),
            legacyPlatformAuth: false)
    }

    /// What jamf-cli would report a profile logs in to, for `cliProfiles` and the connection.
    static func product(for workspace: String) -> JamfCLIProduct {
        environmentProfiles(for: workspace).isSchool ? .school : .pro
    }

    /// The Data Sources Environment card, built by the live builder from the slots above. A
    /// slot's newest snapshot is the newest run that collected for that workspace.
    static func environmentCard(for workspace: String) -> EnvironmentCardState {
        let environment = environmentProfiles(for: workspace)
        return EnvironmentCardState.build(
            workspace: workspace, environment: environment,
            resolve: { resolved($0, in: environment) },
            newest: { slot in
                cacheDate(for: EnvironmentCardState.kinds(for: slot), profile: workspace)
            },
            drifted: { _ in false })
    }

    /// The Data Sources command list for the workspace's products, through the live planner;
    /// the Platform API kinds skip on a workspace with no Platform API profile, as live.
    static func sourcesPlan(for workspace: String) -> CollectSourcesPlan {
        let environment = environmentProfiles(for: workspace)
        let product: ProfileProductType = environment.isSchool ? .jamfSchool : .jamfPro
        let workspaceAuth = resolved(workspace, in: environment)
        let routed = CollectSourcesPlan.routedAuth(
            product: product,
            route: environment.platformRoute(workspace: workspace, platformPinAllows: true),
            workspace: workspace, workspaceAuth: workspaceAuth,
            resolve: { resolved($0, in: environment) })
        return CollectSourcesPlan.build(.init(
            product: product, profile: workspace, protectProfile: environment.protect,
            authMethod: routed.auth?.authMethod, hasTenantID: environment.isSchool,
            platformUnavailable: routed.unavailable))
    }

    /// What `config list` would say of a demo login: the Platform slot logs in with the
    /// Platform API at environment level, Jamf School with an API key, the rest with OAuth.
    private static func resolved(
        _ name: String, in environment: EnvironmentProfiles
    ) -> ProfileAuthMethod.Resolved {
        let school = name == environment.jamfSchool
        return ProfileAuthMethod.Resolved(
            authMethod: name == environment.platform ? "platform" : school ? "apikey" : "oauth2",
            isTenantLevel: false, hasTenantID: school,
            product: school ? .school : name == environment.protect ? .protect : .pro)
    }
}
