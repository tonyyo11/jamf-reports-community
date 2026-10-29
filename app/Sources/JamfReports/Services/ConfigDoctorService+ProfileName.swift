import Foundation

extension ConfigDoctorService {

    /// One row when config.yaml names a profile other than the workspace's own as the folder's
    /// owner (`EnvironmentProfiles.namedOwner`). `.fail` for a `profiles:` block's MDM slot, which
    /// stops every run (`EnvironmentProfiles.refusal`). An old-shape `jamf_cli.profile` naming
    /// any other profile, a case variant included, is a `.warn`: since 2.12 commands run as the
    /// workspace and the folder's own name decides its owner, but a copied or renamed workspace
    /// keeps the old name there.
    static func profileOwnerRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        guard let named = environment.namedOwner, named != profile else { return [] }
        let key = switch environment.source {
        case .legacyKeys: "jamf_cli.profile"
        case .profilesBlock:
            environment.jamfPro != nil ? "profiles.jamf_pro" : "profiles.jamf_school"
        }
        let shownNamed = ConfigSchema.displayText(named)
        let shownProfile = ConfigSchema.displayText(profile)
        let caseOnly = ProfileService.isCaseVariant(named, of: profile)
        let refused = environment.source == .profilesBlock
        return [DoctorRow(
            id: "config.profile_mismatch",
            severity: refused ? .fail : .warn,
            title: "\(key) names a different profile than this workspace",
            detail: "config.yaml sets \(key) to '\(shownNamed)' but this workspace is "
                + "'\(shownProfile)'" + (caseOnly ? " (the names differ only in case)" : "")
                + (refused
                    ? ". Collecting and backing up refuse to run until they agree."
                    : ". The app runs this workspace as '\(shownProfile)' and ignores the key."),
            hint: "Edit \(key) in config.yaml to read '\(shownProfile)'"
                + (environment.source == .legacyKeys ? ", or remove the line" : "")
                + ". A copied or renamed workspace keeps the old name."
        )]
    }
}
