import Foundation

extension ConfigDoctorService {

    /// `.fail` when the `profiles:` block names two MDMs; collect refuses it
    /// (`EnvironmentProfiles.refusal`), so the row says why before a run does.
    static func twoMDMRows(environment: EnvironmentProfiles) -> [DoctorRow] {
        guard environment.source == .profilesBlock,
              environment.jamfPro != nil, environment.jamfSchool != nil else { return [] }
        return [DoctorRow(
            id: "environment.two_mdms",
            severity: .fail,
            title: L("One environment has one MDM"),
            detail: L("profiles names both jamf_pro and jamf_school, so collect refuses to run. Keep one and add the other as a workspace of its own."),
            hint: L("Delete `profiles.jamf_pro` or `profiles.jamf_school` in config.yaml.")
        )]
    }

    /// `.suggest` for old profile keys left beside a `profiles:` block, where nothing reads them.
    /// Without the block they are live, so there is no row.
    static func oldKeyRows(environment: EnvironmentProfiles, config: ReportConfig) -> [DoctorRow] {
        guard environment.source == .profilesBlock else { return [] }
        let present: [(String, Bool)] = [
            ("jamf_cli.profile", config.jamfCli?.profile != nil),
            ("protect.enabled", config.protect?.enabled != nil),
            ("protect.profile", config.protect?.profile != nil),
            ("school_cli.enabled", config.schoolCli?.enabled != nil),
            ("school_cli.profile", config.schoolCli?.profile != nil)
        ]
        let keys = present.filter(\.1).map(\.0)
        guard !keys.isEmpty else { return [] }
        let list = keys.joined(separator: ", ")
        return [DoctorRow(
            id: "environment.old_keys",
            severity: .suggest,
            title: L("Old profile keys are not read"),
            detail: L("While profiles is set these keys are not read: \(list). Delete the lines when every Mac sharing this workspace runs this version."),
            hint: L("Nothing is changed for you.")
        )]
    }

    /// `.warn` for a filled `platform` or `protect` slot whose profile jamf-cli does not list.
    /// `listed` is nil when jamf-cli could not be asked, which is no answer, not an empty list.
    static func unknownSlotProfileRows(
        environment: EnvironmentProfiles, listed: [String]?
    ) -> [DoctorRow] {
        guard environment.source == .profilesBlock, let listed else { return [] }
        let slots: [(key: String, name: String?, detail: (String) -> String)] = [
            ("platform", environment.platform, { name in
                L("'\(name)' is not in jamf-cli's profiles, so Platform API reports fail on every run.")
            }),
            ("protect", environment.protect, { name in
                L("'\(name)' is not in jamf-cli's profiles, so Jamf Protect fails on every run.")
            })
        ]
        return slots.compactMap { slot in
            guard let name = slot.name, !listed.contains(name) else { return nil }
            return DoctorRow(
                id: "environment.unknown_profile",
                severity: .warn,
                title: L("profiles.\(slot.key) names a profile jamf-cli does not have"),
                detail: slot.detail(ConfigSchema.displayText(name)),
                hint: L("Run `jamf-cli config list`, then set profiles.\(slot.key) to a profile it shows.")
            )
        }
    }

    /// `.fail` when another workspace on this Mac names the same profile in an add-on slot.
    /// Doctor only: collect does not refuse (spec 3.1), but every rollup counts that tenant twice.
    static func profileSharedRows(
        profile: String, environment: EnvironmentProfiles,
        others: [(workspace: String, environment: EnvironmentProfiles)]
    ) -> [DoctorRow] {
        func slots(_ e: EnvironmentProfiles) -> [(key: String, name: String)] {
            [("platform", e.platform), ("protect", e.protect), ("security_cloud", e.securityCloud)]
                .compactMap { pair in pair.1.map { (pair.0, $0) } }
        }
        for mine in slots(environment) {
            for other in others where other.workspace != profile
                && slots(other.environment).contains(where: { $0.name == mine.name }) {
                let name = ConfigSchema.displayText(mine.name)
                let otherName = ConfigSchema.displayText(other.workspace)
                return [DoctorRow(
                    id: "environment.profile_shared",
                    severity: .fail,
                    title: L("Two environments collect one tenant"),
                    detail: L("'\(name)' is profiles.\(mine.key) here and in '\(otherName)'. Every rollup counts that tenant twice."),
                    hint: L("Keep the profile in one workspace and clear it in the other.")
                )]
            }
        }
        return []
    }

    /// `.warn` when a separate `platform` profile reaches another Jamf Pro than `jamf_pro`. The
    /// hosts are shown here only, in the Doctor on this Mac. Unknown hosts give no row.
    static func platformHostRows(
        profile: String, environment: EnvironmentProfiles,
        hosts: (jamfPro: String?, platform: String?)?
    ) -> [DoctorRow] {
        guard let hosts, let platform = environment.platform,
              platform != (environment.jamfPro ?? profile),
              case let .different(jamfProHostRaw, platformHostRaw) = PlatformHostCheck.verdict(
                jamfProURL: hosts.jamfPro, platformJamfProURL: hosts.platform)
        else { return [] }
        let jamfPro = ConfigSchema.displayText(environment.jamfPro ?? profile)
        let jamfProHost = ConfigSchema.displayText(jamfProHostRaw)
        let platformHost = ConfigSchema.displayText(platformHostRaw)
        let platformName = ConfigSchema.displayText(platform)
        return [DoctorRow(
            id: "environment.platform_host",
            severity: .warn,
            title: L("profiles.platform reaches a different Jamf Pro"),
            detail: L("'\(platformName)' reaches \(platformHost) and '\(jamfPro)' reaches \(jamfProHost), so Platform API reports are skipped. Choose the Platform profile for this Jamf Pro."),
            hint: L("Set profiles.platform to the Platform API profile of this Jamf Pro, or clear it.")
        )]
    }

    /// `.warn` when under half of the identified Protect computers match this environment's
    /// inventory, read from the newest daily summary's pair (`of < 5` is too few to judge).
    /// Counts are compared, never a rounded percentage. No row otherwise, not even a pass.
    static func protectMatchRows(
        environment: EnvironmentProfiles, matched: MobileSummary.Share?
    ) -> [DoctorRow] {
        guard let protect = environment.protect, let mdm = environment.mdm,
              let matched, matched.of >= 5, matched.met * 2 < matched.of else { return [] }
        let name = ConfigSchema.displayText(protect)
        let product = environment.isSchool ? "Jamf School" : "Jamf Pro"
        return [DoctorRow(
            id: "environment.protect_match",
            severity: .warn,
            title: L("Few Jamf Protect computers match this environment"),
            detail: L("\(matched.met) of \(matched.of) identified Jamf Protect computers match this environment's inventory ('\(name)' against \(product))."),
            hint: L("The Protect profile may belong to another environment, Protect may be installed on Macs this \(product) does not manage, or the two products may report different hardware identifiers.")
        )]
    }

    // MARK: - Live wrappers

    /// Every wrapper reads the environment first and does no IO for a workspace without a
    /// `profiles:` block, where none of these rows can apply.
    private static func blockEnvironment(
        _ profile: String, _ config: ReportConfig
    ) -> EnvironmentProfiles? {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        return environment.source == .profilesBlock ? environment : nil
    }

    /// Reads the newest daily summary only; no snapshot decode and no probe.
    static func protectMatchRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        guard environment.protect != nil, environment.mdm != nil,
              let day = SummaryJSONParser.newestSummaryDay(profile: profile),
              let dir = try? WorkspacePaths.summariesDir(for: profile),
              let summary = try? SummaryJSONParser.parse(
                dir.appendingPathComponent("summary_\(day).json"))
        else { return [] }
        return protectMatchRows(environment: environment, matched: summary.protectMatched)
    }

    static func twoMDMRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        blockEnvironment(profile, config).map { twoMDMRows(environment: $0) } ?? []
    }

    static func oldKeyRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        blockEnvironment(profile, config).map { oldKeyRows(environment: $0, config: config) } ?? []
    }

    static func unknownSlotProfileRows(
        profile: String, config: ReportConfig, includeProbes: Bool = true
    ) -> [DoctorRow] {
        guard includeProbes, let environment = blockEnvironment(profile, config),
              environment.platform != nil || environment.protect != nil else { return [] }
        return unknownSlotProfileRows(
            environment: environment,
            listed: ProfileService.listJamfCLIProfiles(scheduleCounts: [:])?.map(\.name))
    }

    static func profileSharedRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        guard let environment = blockEnvironment(profile, config),
              !environment.connectedProfiles.isEmpty else { return [] }
        let root = ProfileService.workspacesRoot()
        let mine = ProfileService.workspaceURL(for: profile)?.resolvingSymlinksInPath()
        let key = ProfileName.folderKey(profile)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        let others = folders.prefix(200).compactMap {
            otherEnvironment(at: $0, mine: mine, myKey: key)
        }
        return profileSharedRows(profile: profile, environment: environment, others: others)
    }

    /// Another workspace's environment, or nil for a folder that is this one (a link or a case
    /// variant), a link, a file, or a config.yaml that does not decode.
    private static func otherEnvironment(
        at folder: URL, mine: URL?, myKey: String
    ) -> (workspace: String, environment: EnvironmentProfiles)? {
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true,
              let name = ProfileName.name(fromPathComponent: folder.lastPathComponent),
              ProfileName.folderKey(name) != myKey,
              folder.resolvingSymlinksInPath() != mine,
              let other = try? ConfigLoader.load(
                  from: folder.appendingPathComponent("config.yaml"))
        else { return nil }
        return (name, EnvironmentProfiles.resolve(config: other, workspace: name))
    }

    static func platformHostRows(
        profile: String, config: ReportConfig, includeProbes: Bool = true
    ) -> [DoctorRow] {
        guard includeProbes, let environment = blockEnvironment(profile, config),
              let platform = environment.platform, let jamfPro = environment.jamfPro,
              platform != profile,
              // The probe sends a request as `platform`: never for a name this Mac has not confirmed.
              SharedConfigPin.platformAllowed(profile: profile, name: platform),
              let bin = ExecutableLocator.locate("jamf-cli") else { return [] }
        return platformHostRows(
            profile: profile, environment: environment,
            hosts: PlatformHostCheck.live(jamfPro, platform, bin))
    }
}
