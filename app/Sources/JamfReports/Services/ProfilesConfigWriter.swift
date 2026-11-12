import Foundation

/// The one writer of config.yaml's `profiles:` block (spec 3.4). A scoped `saveBlock` like
/// `ChartsConfigWriter`: other blocks and the comments outside this one stay, and a dropped
/// comment is copied out first. The old keys are never removed (D14).
enum ProfilesConfigWriter {
    enum Slot: String, CaseIterable, Sendable {
        case jamfPro = "jamf_pro", platform, jamfSchool = "jamf_school", protect
        case securityCloud = "security_cloud"
    }

    enum WriteError: Error, LocalizedError, Equatable {
        case invalidProfile(String)
        case invalidSlotProfile(String)
        case mdmIsTheWorkspace
        case configDoesNotLoad(String)
        case protectHasNoProfile

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let name), .invalidSlotProfile(let name):
                ProfileName.invalidMessage(name)
            case .mdmIsTheWorkspace:
                L("The Jamf Pro or Jamf School slot always names this workspace's own profile")
            case .configDoesNotLoad(let reason):
                L("config.yaml does not load, so the profiles block was not written: \(reason)")
            case .protectHasNoProfile:
                L("Protect is on but has no profile; set protect.profile or disconnect Protect first")
            }
        }
    }

    /// Sets (`name`) or clears (nil) one slot. On a file without `profiles:`, first writes the
    /// slots `EnvironmentProfiles` derives from the old keys, plus `platform: <workspace>` when
    /// the workspace's own profile is a Platform one or its auth is unknown (an old-shape file
    /// routes the Platform kinds to the workspace's profile; the block must keep that), so the
    /// run that follows collects the same kinds; the old keys are left in place (D14). `save`
    /// never writes the MDM slots (D17): only this seed does. On a file with
    /// `protect.enabled: false` and a `protect.profile`, the seed moves the `protect.profile`
    /// pin token to "" (the block has no protect slot); this Mac confirms that, so only a peer
    /// sharing the folder sees one Config Doctor drift row until it confirms; this fails safe.
    static func apply(
        _ slot: Slot, to name: String?, derived: EnvironmentProfiles,
        root: inout YAMLCodec.YAMLMapping
    ) {
        var block = root.value(for: "profiles")?.mapping ?? seeded(from: derived)
        if let name {
            block.set(slot.rawValue, value: .scalar(.string(name)))
        } else {
            block.entries.removeAll { $0.key == slot.rawValue }
        }
        root.set("profiles", value: .mapping(block))
    }

    /// What a new workspace's own profile is, for the block it starts with (D3).
    struct NewWorkspace: Equatable, Sendable {
        var school = false
        /// A Platform API profile also collects the Platform kinds, so it fills `platform` too.
        var platform = false

        /// From jamf-cli's record of the profile. One it cannot read is Jamf Pro with the
        /// `platform` slot, as the block seed does, so a Platform workspace keeps its kinds.
        static func of(
            _ profile: String,
            resolve: (String) -> ProfileAuthMethod.Resolved? = {
                ProfileAuthMethod.resolve(profile: $0)
            }
        ) -> NewWorkspace {
            guard let resolved = resolve(profile) else { return NewWorkspace(platform: true) }
            if resolved.product == .school { return NewWorkspace(school: true) }
            return NewWorkspace(platform: resolved.method?.isPlatform == true)
        }
    }

    /// The `profiles:` block a new workspace starts with (D3): its own profile in the MDM slot,
    /// and in `platform` too for a Platform API profile.
    static func newWorkspaceBlock(workspace: String, _ kind: NewWorkspace) -> String {
        let own = "\"\(ScaffoldService.yamlEscape(workspace))\""
        var block = "\nprofiles:\n  \((kind.school ? Slot.jamfSchool : Slot.jamfPro).rawValue): \(own)\n"
        if kind.platform, !kind.school { block += "  \(Slot.platform.rawValue): \(own)\n" }
        return block
    }

    /// The School setup's write for the workspace's own profile, on a block that names the
    /// workspace as Jamf Pro (a setup that began on the Jamf Pro path, or a login jamf-cli could
    /// not place): the MDM slot becomes `jamf_school`, as `school_cli` did on an old-shape file,
    /// and a `platform` slot naming the workspace itself goes with it. Nil when the block does
    /// not name the workspace as Jamf Pro.
    static func schoolTakesTheMDMSlot(
        workspace: String, appSupport: URL = AppSupport.directory()
    ) throws -> ConfigSaveReport? {
        guard hasProfilesBlock(workspace: workspace) else { return nil }
        var droppedPlatform = false
        var moved = false
        let report = try ConfigService.saveBlock(key: "profiles", profile: workspace) { root in
            guard var block = root.value(for: "profiles")?.mapping,
                  block.value(for: Slot.jamfPro.rawValue)?.stringValue == workspace,
                  block.value(for: Slot.jamfSchool.rawValue) == nil else { return }
            droppedPlatform = block.value(for: Slot.platform.rawValue)?.stringValue == workspace
            let drop: Set = droppedPlatform
                ? [Slot.jamfPro.rawValue, Slot.platform.rawValue] : [Slot.jamfPro.rawValue]
            block.entries.removeAll { drop.contains($0.key) }
            block.set(Slot.jamfSchool.rawValue, value: .scalar(.string(workspace)))
            root.set("profiles", value: .mapping(block))
            moved = true
        }.report
        guard moved else { return nil }
        if droppedPlatform {
            SharedConfigPin.confirmWritten(
                "", key: .platformProfile, profile: workspace, appSupport: appSupport)
        }
        return report
    }

    /// The `profiles:` block of a Protect-only environment: the one slot, no MDM slot.
    static func protectOnlyBlock(login: String) -> String {
        "\nprofiles:\n  \(Slot.protect.rawValue): \"\(ScaffoldService.yamlEscape(login))\"\n"
    }

    /// The block a file without one starts from: the slots the old keys give today.
    private static func seeded(from derived: EnvironmentProfiles) -> YAMLCodec.YAMLMapping {
        var block = YAMLCodec.YAMLMapping(entries: [])
        let slots: [(Slot, String?)] = [
            (.jamfPro, derived.jamfPro), (.platform, derived.platform),
            (.jamfSchool, derived.jamfSchool), (.protect, derived.protect),
        ]
        for case let (slot, value?) in slots {
            block.set(slot.rawValue, value: .scalar(.string(value)))
        }
        return block
    }

    /// Whether the workspace's config.yaml has a `profiles:` mapping, read from the raw YAML and
    /// not the decoder: an old-shape file that does not decode must stay editable by the
    /// old-key writers (Disconnect is a recovery), while one with a `profiles` mapping goes to
    /// the block writer, which reports that the file does not load.
    static func hasProfilesBlock(workspace profile: String) -> Bool {
        guard let url = ProfileService.workspaceURL(for: profile)?
            .appendingPathComponent("config.yaml"),
            let text = try? ConfigLoader.readText(at: url),
            let root = try? ConfigLoader.rawMapping(fromYAML: text) else { return false }
        return root["profiles"] is [String: Any]
    }

    @discardableResult
    static func save(
        _ slot: Slot, to name: String?, workspace profile: String,
        appSupport: URL = AppSupport.directory(),
        workspaceAuth: (String) -> ProfileAuthMethod.Resolved? = {
            ProfileAuthMethod.resolve(profile: $0)
        }
    ) throws -> ConfigSaveReport {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        if slot == .jamfPro || slot == .jamfSchool { throw WriteError.mdmIsTheWorkspace }
        if let name, !ProfileService.isValid(name) { throw WriteError.invalidSlotProfile(name) }
        var config: ReportConfig?
        if let url = ProfileService.workspaceURL(for: profile)?
            .appendingPathComponent("config.yaml"),
            FileManager.default.fileExists(atPath: url.path) {
            do { config = try ConfigLoader.load(from: url) } catch {
                throw WriteError.configDoesNotLoad(error.localizedDescription)
            }
        }
        var derived = EnvironmentProfiles.resolve(config: config, workspace: profile)
        let seeding = config?.profiles == nil
        if seeding, derived.protectWithoutProfile { throw WriteError.protectHasNoProfile }
        // Unknown auth fails toward collecting: a slot equal to the workspace reads its own auth.
        if seeding, derived.jamfPro != nil,
           workspaceAuth(profile).map({ $0.method?.isPlatform == true }) ?? true {
            derived.platform = profile
        }
        let report = try ConfigService.saveBlock(key: "profiles", profile: profile) {
            apply(slot, to: name, derived: derived, root: &$0)
        }.report
        // The operator's own act: confirm the token this write put there, not whatever the file
        // holds by now (a peer's copy synced in between stays drift). A cleared slot reads "".
        let key: SharedConfigPin.Key? = switch slot {
        case .platform: .platformProfile
        case .protect: .protectProfile
        case .securityCloud: .securityCloudProfile
        default: nil
        }
        if let key {
            SharedConfigPin.confirmWritten(
                name ?? "", key: key, profile: profile, appSupport: appSupport)
        }
        if seeding {
            // The seed moved these tokens too; the operator's write confirms them on this Mac.
            if slot != .platform, let seeded = derived.platform {
                SharedConfigPin.confirmWritten(
                    seeded, key: .platformProfile, profile: profile, appSupport: appSupport)
            }
            if slot != .protect, derived.protect == nil, config?.protect?.profile != nil {
                SharedConfigPin.confirmWritten(
                    "", key: .protectProfile, profile: profile, appSupport: appSupport)
            }
        }
        return report
    }
}
