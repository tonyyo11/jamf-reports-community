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

    /// One `.warn` row when `protect.profile` names a login jamf-cli knows to be another product
    /// (a Jamf Pro or School profile, say): collect, backup and the dashboard skip Protect for it
    /// rather than send Protect commands to the wrong API. Nothing is asked when `resolved`
    /// cannot tell.
    static func protectProfileProductRows(
        config: ReportConfig,
        resolved: (String) -> ProfileAuthMethod.Resolved?
    ) -> [DoctorRow] {
        guard config.protect?.isEnabled == true,
              let named = config.protect?.resolvedProfile, !named.isEmpty,
              let product = resolved(named)?.product,
              resolved(named)?.protectRefusal(profile: named) != nil else { return [] }
        let shown = ConfigSchema.displayText(named)
        return [DoctorRow(
            id: "protect.profile_product",
            severity: .warn,
            title: "protect.profile is not a Jamf Protect login",
            detail: "protect.profile names '\(shown)', a \(product.displayName) profile. Protect "
                + "commands would go to the wrong API, so Jamf Protect is not collected, backed "
                + "up or added to the dashboard until it names a Jamf Protect login.",
            hint: "Set protect.profile to the profile `jamf-cli protect setup` created, or turn "
                + "protect.enabled off."
        )]
    }

    /// `protectProfileProductRows` for the live `config list`; it asks jamf-cli only for a
    /// workspace that has Protect on.
    static func protectProfileProductRows(config: ReportConfig) -> [DoctorRow] {
        protectProfileProductRows(
            config: config, resolved: { ProfileAuthMethod.resolve(profile: $0) })
    }

    /// One `.suggest` row while backups leave Jamf Protect out because the workspace is on
    /// storage other Macs reach. Whether that storage may hold Protect's configuration is the
    /// organization's call, so this points at the setting rather than warns.
    static func protectSyncedBackupRows(
        _ choice: ProtectBackup.SyncedStorageChoice?
    ) -> [DoctorRow] {
        guard let choice, !choice.allowed else { return [] }
        let key = SharedConfigPin.Key.protectBackupOnSyncedStorage.rawValue
        return [DoctorRow(
            id: "protect.backup_synced_storage",
            severity: .suggest,
            title: "Backups leave Jamf Protect out on this storage",
            detail: "This workspace is \(choice.place). A Protect backup contains action "
                + "configurations with request headers and data-forwarding settings, so backups "
                + "here hold Jamf Pro only.",
            hint: "If your organization's storage and access policy allows it, turn on "
                + "\"Back up Jamf Protect in this folder\" in Backups (\(key))."
        )]
    }

    /// One `.suggest` row while backups skip Jamf Pro, or are about to, because the workspace is
    /// on storage other Macs reach and the choice is not in effect on this Mac. Whether that
    /// storage may hold Jamf Pro's configuration is the organization's call, so this points at
    /// the setting.
    static func proSyncedBackupRows(_ choice: ProBackup.SyncedStorageChoice?) -> [DoctorRow] {
        guard let choice, choice.setting != .allowed,
              choice.setting != .configUnreadable else { return [] }
        let key = SharedConfigPin.Key.proBackupOnSyncedStorage.rawValue
        let secrets = "A Jamf Pro backup contains LDAP, SMTP and API-client configuration and "
            + "scripts that can hold secrets."
        let title: String
        let consequence: String
        let hint: String
        switch choice.setting {
        case .notChosen:
            title = "Jamf Pro backups on this storage need a choice"
            consequence = "Scheduled backups that already ran here continue for "
                + "\(BackupMaintenance.graceRunsBeforeAsking) runs, then skip Jamf Pro and read "
                + "as Partial."
            hint = "If your organization's storage and access policy allows it, turn on "
                + "\"Back up Jamf Pro in this folder\" in Backups (\(key)); otherwise set it to "
                + "false to record that Jamf Pro stays out."
        case .awaitingConfirmation:
            title = "Jamf Pro backups are waiting for confirmation on this Mac"
            consequence = "\(key) is on in config.yaml but not confirmed here, so backups skip "
                + "Jamf Pro and read as Partial."
            hint = "Confirm it in the shared config row, or from the Backups switch."
        default:
            title = "Backups leave Jamf Pro out on this storage"
            consequence = "\(key) is false, so backups here skip Jamf Pro."
            hint = "If your organization's storage and access policy allows it, turn on "
                + "\"Back up Jamf Pro in this folder\" in Backups (\(key))."
        }
        return [DoctorRow(
            id: "backup.pro_synced_storage", severity: .suggest, title: title,
            detail: "This workspace is \(choice.place). \(secrets) \(consequence)", hint: hint)]
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
