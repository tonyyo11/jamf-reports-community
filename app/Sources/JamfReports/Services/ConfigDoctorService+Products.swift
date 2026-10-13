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
}
