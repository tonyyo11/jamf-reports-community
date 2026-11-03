import Foundation

/// Which jamf-cli profile serves which product in a workspace (one environment). The one reader
/// of config.yaml's `profiles:` block, and of the keys it replaces: a file without the block
/// derives the same slots from the workspace ID, `protect.enabled/profile` and
/// `school_cli.enabled/profile`, so a workspace set up before 2.12 runs exactly as it did. When
/// the block is present the old keys are not read. Nil is a product the environment does not
/// have. Every command takes its `-p` from these slots; folders come from the `WorkspaceID`.
struct EnvironmentProfiles: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case profilesBlock
        case legacyKeys
    }

    /// Old keys: the workspace ID; `jamf_cli.profile` never names the profile commands run as.
    var jamfPro: String?
    var platform: String?
    var jamfSchool: String?
    var protect: String?
    var securityCloud: String?
    /// `protect.enabled: true` with a blank `protect.profile` (old keys only): Protect was asked
    /// for and has no login, which collect and backup say instead of skipping in silence.
    var protectWithoutProfile = false
    /// A School login an earlier build recorded in a Jamf Pro workspace (`school_cli.profile`
    /// naming another profile). Not used there; named so discovery does not offer it.
    var foreignSchool: String?
    /// The MDM profile the file says owns this folder: the block's MDM slot, or a non-blank
    /// `jamf_cli.profile` in an old-shape file. Only the folder checks read it (a case variant
    /// sharing the folder, a copied folder); commands run as `jamfPro` or `jamfSchool`.
    var namedOwner: String?
    var source = Source.legacyKeys

    static let none = EnvironmentProfiles()

    /// The MDM's profile: Jamf Pro, else Jamf School.
    var mdm: String? { jamfPro ?? jamfSchool }
    /// Jamf School is this environment's MDM.
    var isSchool: Bool { jamfPro == nil && jamfSchool != nil }
    var runsProtect: Bool { protect != nil || protectWithoutProfile }
    /// The key the Protect login was read from, for messages.
    var protectKey: String { source == .profilesBlock ? "profiles.protect" : "protect.profile" }
    /// The logins this workspace names besides its MDM; none of them is a workspace of its own.
    var connectedProfiles: [String] {
        [platform, protect, securityCloud, foreignSchool].compactMap { $0 }
    }

    /// `workspace` is the profile whose config.yaml this is. An old-shape file derives no
    /// `platform` slot (D19): see `platformRoute`.
    static func resolve(config: ReportConfig?, workspace: String) -> EnvironmentProfiles {
        if let block = config?.profiles {
            var environment = EnvironmentProfiles(
                jamfPro: named(block.jamfPro), platform: named(block.platform),
                jamfSchool: named(block.jamfSchool), protect: named(block.protect),
                securityCloud: named(block.securityCloud), source: .profilesBlock)
            environment.namedOwner = environment.mdm
            return environment
        }
        var environment = EnvironmentProfiles()
        environment.namedOwner = named(config?.jamfCli?.profile)
        let recorded = named(workspace)
        let school = config?.schoolCli
        if school?.isPrimary(forWorkspace: workspace) == true {
            environment.jamfSchool = recorded
        } else {
            environment.jamfPro = recorded
            if school?.isForeign(toWorkspace: workspace) == true {
                environment.foreignSchool = named(school?.profile)
            }
        }
        if config?.protect?.isEnabled == true {
            environment.protect = named(config?.protect?.profile)
            environment.protectWithoutProfile = environment.protect == nil
        }
        return environment
    }

    /// Whether Protect is part of this environment (its workbook tabs and report sections), with
    /// or without a usable login.
    static func runsProtect(_ config: ReportConfig?) -> Bool {
        resolve(config: config, workspace: "").runsProtect
    }

    /// Why nothing may run for `workspace` under a `profiles:` block, or nil. Until the slots are
    /// pinned on a shared workspace, the MDM slot must name the workspace's own profile, so a
    /// peer's edit cannot point this Mac's collect at another tenant; the old keys never refuse.
    func refusal(workspace: String) -> String? {
        guard source == .profilesBlock else { return nil }
        let shown = ConfigSchema.displayText
        if jamfPro != nil, jamfSchool != nil {
            return "config.yaml names both profiles.jamf_pro and profiles.jamf_school; one "
                + "environment has one MDM, so nothing runs. Keep one and add the other as a "
                + "workspace of its own."
        }
        guard let mdm else {
            return "config.yaml's profiles block names neither profiles.jamf_pro nor "
                + "profiles.jamf_school, so nothing runs for '\(shown(workspace))'."
        }
        guard mdm == workspace else {
            let key = jamfPro != nil ? "profiles.jamf_pro" : "profiles.jamf_school"
            return "\(key) names '\(shown(mdm))' but this workspace is '\(shown(workspace))', "
                + "so nothing runs. Set \(key) to '\(shown(workspace))'."
        }
        return nil
    }

    /// A config.yaml that is missing or does not decode reads as the old shape with no keys:
    /// Jamf Pro on the workspace's own profile, nothing else.
    static func read(configURL: URL, workspace: String) -> EnvironmentProfiles {
        resolve(config: try? ConfigLoader.load(from: configURL), workspace: workspace)
    }

    static func read(
        workspace: String, under root: URL = ProfileService.workspacesRoot()
    ) -> EnvironmentProfiles {
        guard let id = WorkspaceID(workspace) else {
            return resolve(config: nil, workspace: workspace)
        }
        return read(
            configURL: WorkspacePaths.workspaceURL(for: id, under: root)
                .appendingPathComponent("config.yaml"),
            workspace: workspace)
    }

    private static func named(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        return name
    }
}

/// Who collects the Platform-only kinds (`ReportEngine.platformOnlyKinds`), spec 3.2 and D19.
/// The one answer for `collect`, the Data Sources plan and the freshness strip.
enum PlatformRoute: Equatable, Sendable {
    /// No `profiles:` block: the workspace's own profile, skipped by its auth method as before.
    case workspaceProfile
    /// The `platform` slot's profile.
    case profile(String)
    /// The block leaves them out; the text is the `[skip]` and `[plan]` reason.
    case unavailable(String)
}

extension EnvironmentProfiles {
    static let noPlatformReason = "no Platform API profile in this environment"
    static let invalidPlatformReason = "profiles.platform is not a usable profile name"
    static let organizationLevelPlatformReason =
        "profiles.platform names an organization-level profile"
    static let heldPlatformReason =
        "profiles.platform changed in the shared config.yaml and is not confirmed on this Mac"

    /// The auth method that judges the Platform kinds, and why they do not run, for a route:
    /// the one answer `collect`'s screens (freshness strip, Data Sources) share. `resolve` is
    /// asked only for a separate profile, so a slot naming the workspace costs no second probe.
    static func platformInputs(
        route: PlatformRoute, workspace: String, workspaceAuth: ProfileAuthMethod.Resolved?,
        resolve: (String) -> ProfileAuthMethod.Resolved?
    ) -> (auth: ProfileAuthMethod.Resolved?, unavailable: String?) {
        switch route {
        case .workspaceProfile: return (workspaceAuth, nil)
        case .unavailable(let reason): return (workspaceAuth, reason)
        case .profile(let named):
            guard named != workspace else { return (workspaceAuth, nil) }
            let auth = resolve(named)
            // Collect skips these for an organization-level profile (spec 3.1).
            return auth?.isOrganizationLevel == true
                ? (workspaceAuth, Self.organizationLevelPlatformReason) : (auth, nil)
        }
    }

    /// `platformPinAllows` is `SharedConfigPin.platformAllowed`; it matters only under a block,
    /// and only for another profile than the Jamf Pro slot (D18): the writer's seed names the
    /// workspace's own, which cannot point this Mac at another tenant.
    func platformRoute(platformPinAllows: Bool) -> PlatformRoute {
        guard source == .profilesBlock else { return .workspaceProfile }
        guard let platform else { return .unavailable(Self.noPlatformReason) }
        guard ProfileService.isValid(platform) else {
            return .unavailable(Self.invalidPlatformReason)
        }
        guard platformPinAllows || platform == jamfPro else {
            return .unavailable(Self.heldPlatformReason)
        }
        return .profile(platform)
    }
}
