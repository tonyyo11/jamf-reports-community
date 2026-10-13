import Foundation

extension ConfigDoctorService {

    /// One `.suggest` row on the Jamf Pro workspace whose `protect.profile` names a Protect (or
    /// Security Cloud) login that also has a workspace folder. 2.9.0 listed that login as a
    /// workspace, so a catch-up, a scheduled run or a click may have made a folder for it. The
    /// app reads nothing in it (the Protect data is in this workspace), and removes nothing.
    static func protectProfileFolderRows(
        profile: String,
        config: ReportConfig,
        discovered: () -> [JamfCLIProfile],
        folderExists: (String) -> Bool = { ProfileService.hasWorkspace($0) }
    ) -> [DoctorRow] {
        guard config.protect?.isEnabled == true,
              let named = config.protect?.resolvedProfile, !named.isEmpty, named != profile,
              discovered().contains(where: { $0.name == named && $0.product.isNeverAWorkspace }),
              folderExists(named) else { return [] }
        let shown = ConfigSchema.displayText(named)
        return [DoctorRow(
            id: "protect.profile_folder",
            severity: .suggest,
            title: "The Jamf Protect login has a workspace folder it does not need",
            detail: "protect.profile names '\(shown)', a Jamf Protect login. It is not a Jamf Pro "
                + "workspace, so the app no longer lists or runs it, and its Protect data is "
                + "collected into this workspace. A folder named for it under the workspace "
                + "root, made by an earlier version, is not read.",
            hint: "Remove the '\(ProfileName.pathComponent(named))' folder from the workspace "
                + "root when you no longer need its history. The app never deletes it."
        )]
    }

    /// `protectProfileFolderRows` for the live `config list`; it asks jamf-cli only for a
    /// workspace that names a Protect profile.
    static func protectProfileFolderRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        protectProfileFolderRows(
            profile: profile, config: config,
            discovered: { ProfileService.discoverJamfCLIProfiles(scheduleCounts: [:]) })
    }

    /// One `.fail` row for a workspace whose profile is an organization-level Platform
    /// integration: it reaches Jamf Account only, and `collect` stops at one `[error]` line.
    static func organizationLevelRows(
        profile: String, auth: ProfileAuthMethod.Resolved?
    ) -> [DoctorRow] {
        guard auth?.isOrganizationLevel == true else { return [] }
        return [DoctorRow(
            id: "platform.organization_level",
            severity: .fail,
            title: "This profile is an organization-level Platform integration",
            detail: "'\(ConfigSchema.displayText(profile))' names no environment ID or tenant "
                + "ID, so its credential reaches only Jamf Account. No Jamf Pro report can be "
                + "collected with it, and collecting stops at once.",
            hint: PlatformScopeLevel.organizationLevelReason
        )]
    }

    /// `organizationLevelRows` for the live profile; nil unless jamf-cli answers `config list`.
    static func organizationLevelRows(profile: String) -> [DoctorRow] {
        organizationLevelRows(profile: profile, auth: ProfileAuthMethod.resolve(profile: profile))
    }

    /// One `.suggest` row on a workspace that has a twin: a platform profile and an oauth2
    /// profile for the same Jamf Pro, each with a workspace of its own. jamf-cli's wiki
    /// recommends keeping the oauth2 profile for commands the gateway refuses, but Jamf Reports
    /// collects one profile per fleet, so collecting both splits history and doubles the
    /// consolidated totals. Nothing is changed for a user who already has both. `learn` gives a
    /// platform profile's Jamf Pro URL (a stored one, else the read-only probe).
    static func platformTwinRows(
        profile: String,
        discovered: [JamfCLIProfile],
        hasWorkspace: (String) -> Bool,
        learn: (String) -> String?
    ) -> [DoctorRow] {
        guard let me = discovered.first(where: { $0.name == profile }) else { return [] }
        let withFolder = discovered.filter { hasWorkspace($0.name) && $0.status != .error }
        let pairs: [(platform: JamfCLIProfile, twin: JamfCLIProfile)]
        if me.auth?.isPlatform == true {
            let found = PlatformTwin.twins(ofPlatformProfile: me, among: withFolder, learn: learn)
            pairs = (found?.twins ?? []).map { (me, $0) }
        } else {
            pairs = withFolder.compactMap { platform in
                PlatformTwin.twins(ofPlatformProfile: platform, among: [me], learn: learn)
                    .map { _ in (platform, me) }
            }
        }
        guard let pair = pairs.first else { return [] }
        let platform = ConfigSchema.displayText(pair.platform.name)
        let twin = ConfigSchema.displayText(pair.twin.name)
        return [DoctorRow(
            id: "platform.twin",
            severity: .suggest,
            title: "Two workspaces collect the same Jamf Pro",
            detail: "'\(platform)' (Platform API) and '\(twin)' (oauth2) reach the same Jamf Pro "
                + "server, and both have a workspace. Jamf Reports collects one profile per "
                + "fleet, so history is split across two folders and a consolidated report "
                + "counts the fleet twice.",
            hint: "Keep '\(platform)' as the workspace and exclude '\(twin)' under Automation > "
                + "Excluded profiles. Keep the oauth2 profile in jamf-cli for the commands the "
                + "gateway refuses. Nothing is changed for you."
        )]
    }

    /// `platformTwinRows` for the live profiles. jamf-cli is asked only when this workspace and
    /// another both have a folder, one profile is platform and another is oauth2.
    static func platformTwinRows(profile: String) -> [DoctorRow] {
        let discovered = ProfileService.discoverJamfCLIProfiles(scheduleCounts: [:])
        let store = ConnectionStore()
        return platformTwinRows(
            profile: profile, discovered: discovered,
            hasWorkspace: { ProfileService.hasWorkspace($0) },
            learn: { store.jamfProURL(profile: $0) ?? PlatformTwin.learnJamfProURL(profile: $0) })
    }
}
