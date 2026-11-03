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

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let name), .invalidSlotProfile(let name):
                ProfileName.invalidMessage(name)
            case .mdmIsTheWorkspace:
                L("The Jamf Pro or Jamf School slot always names this workspace's own profile")
            }
        }
    }

    /// Sets (`name`) or clears (nil) one slot. On a file without `profiles:`, first writes the
    /// slots `EnvironmentProfiles` derives from the old keys, so the run that follows uses the
    /// same profiles; the old keys are left in place (D14).
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

    /// The block a file without one starts from: the slots the old keys give today.
    private static func seeded(from derived: EnvironmentProfiles) -> YAMLCodec.YAMLMapping {
        var block = YAMLCodec.YAMLMapping(entries: [])
        let slots: [(Slot, String?)] = [
            (.jamfPro, derived.jamfPro), (.jamfSchool, derived.jamfSchool),
            (.protect, derived.protect),
        ]
        for case let (slot, value?) in slots {
            block.set(slot.rawValue, value: .scalar(.string(value)))
        }
        return block
    }

    @discardableResult
    static func save(
        _ slot: Slot, to name: String?, workspace profile: String,
        appSupport: URL = AppSupport.directory()
    ) throws -> ConfigSaveReport {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        if slot == .jamfPro || slot == .jamfSchool, name != profile {
            throw WriteError.mdmIsTheWorkspace
        }
        if let name, !ProfileService.isValid(name) { throw WriteError.invalidSlotProfile(name) }
        let config = ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        let derived = EnvironmentProfiles.resolve(config: config, workspace: profile)
        let report = try ConfigService.saveBlock(key: "profiles", profile: profile) {
            apply(slot, to: name, derived: derived, root: &$0)
        }.report
        // The operator's own act: confirm what it wrote, so the next run does not read it as drift.
        let keys: Set<SharedConfigPin.Key> = switch slot {
        case .platform: [.platformProfile]
        case .protect: [.protectProfile]
        default: []
        }
        if !keys.isEmpty {
            SharedConfigPin.confirmBestEffort(profile: profile, keys: keys, appSupport: appSupport)
        }
        return report
    }
}
