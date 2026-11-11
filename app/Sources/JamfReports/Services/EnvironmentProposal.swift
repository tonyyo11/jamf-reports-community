import Foundation

/// What first-launch adoption and the Add sheet propose from jamf-cli's profiles: one
/// environment per workspace (D17), a Platform profile folded into the environment whose Jamf Pro
/// it reaches, and each Protect login offered with a name-based suggestion. Pure: every effect
/// (learning a Jamf Pro URL, reading the workspaces) is an argument.
struct EnvironmentProposal: Equatable, Sendable {
    struct Environment: Identifiable, Equatable, Sendable {
        /// The folder and MDM profile (D17).
        var workspace: String
        var isSchool: Bool
        /// A Platform profile other than `workspace`, or nil. A Platform MDM collects its
        /// Platform kinds itself (the writer's seed), so it never appears here.
        var platform: String?
        var learnedJamfProURL: String?
        var id: String { workspace }
    }
    /// A profile to add to a workspace that already exists (rule 7).
    struct Extension: Identifiable, Equatable, Sendable {
        var workspace: String
        var slot: ProfilesConfigWriter.Slot  // .platform in P6
        var profile: String
        var learnedJamfProURL: String?
        var id: String { "\(workspace)/\(profile)" }
    }
    struct ProtectChoice: Identifiable, Equatable, Sendable {
        var profile: String
        /// The environment or workspace that rule 5's prefix suggests (R6), or nil.
        var suggested: String?
        var id: String { profile }
    }
    var environments: [Environment]
    var extensions: [Extension]
    var protectChoices: [ProtectChoice]
    /// Profiles placed nowhere, each with the reason shown beside it.
    var unassigned: [String: String]

    static func propose(
        profiles: [JamfCLIProfile],
        learnedJamfProURLs: [String: String],
        existingWorkspaces: [String: EnvironmentProfiles],
        unusable: [String: String] = [:]
    ) -> EnvironmentProposal {
        var result = EnvironmentProposal(
            environments: [], extensions: [], protectChoices: [], unassigned: [:])
        // Sorted so two keys that share a folder key (case variants) resolve the same way each run.
        let existingKeys = Dictionary(
            existingWorkspaces.sorted { $0.key < $1.key }
                .map { (ProfileName.folderKey($0.key), $0) },
            uniquingKeysWith: { first, _ in first })
        var usedKeys = Set(existingKeys.keys)
        for env in existingWorkspaces.values {
            usedKeys.formUnion(env.connectedProfiles.map(ProfileName.folderKey))
        }
        // Rule 1 drops these from placement; rule 3 still searches the workspaces' MDM profiles.
        let existingMDM = profiles.filter { existingKeys[ProfileName.folderKey($0.name)] != nil }

        var open: [JamfCLIProfile] = []
        for profile in profiles where !usedKeys.contains(ProfileName.folderKey(profile.name)) {
            if let why = unusable[profile.name] ?? ExistingCLISetupFlow.scopeRefusal(for: profile) {
                result.unassigned[profile.name] = why
            } else if profile.product == .securityCloud {
                result.unassigned[profile.name] = ExistingCLISetupFlow.securityCloudReason
            } else {
                open.append(profile)
            }
        }

        let pro = open.filter { $0.product.canBeProWorkspace }
        let platforms = pro.filter { $0.auth?.isPlatform == true }
        let others = pro.filter { $0.auth?.isPlatform != true }
        // Platform profiles placed outside an environment of their own.
        var claimed = Set<String>()
        var paired: [String: String] = [:]  // unassigned twin -> its Platform profile
        let byHost = Dictionary(grouping: platforms) {
            PlatformTwin.host(of: learnedJamfProURLs[$0.name]) ?? ""
        }
        for (host, group) in byHost where !host.isEmpty {
            if group.count > 1 {
                for profile in group {
                    result.unassigned[profile.name] = L(
                        "Two Platform profiles reach the same Jamf Pro (\(host)). Add the one you want from the Add sheet."
                    )
                    claimed.insert(profile.name)
                }
                continue
            }
            guard let platform = group.first,
                  let twin = PlatformTwin.twins(reaching: host, among: others + existingMDM)
                    .min(by: { $0.name < $1.name }) else { continue }
            claimed.insert(platform.name)
            let url = learnedJamfProURLs[platform.name]
            guard let existing = existingKeys[ProfileName.folderKey(twin.name)] else {
                paired[twin.name] = platform.name
                continue
            }
            let workspace = existing.key
            if let have = existing.value.platform {
                result.unassigned[platform.name] =
                    L("\(workspace) already has Platform API profile \(have).")
            } else {
                result.extensions.append(Extension(
                    workspace: workspace, slot: .platform, profile: platform.name,
                    learnedJamfProURL: url))
            }
        }

        for profile in others {
            let platform = paired[profile.name]
            result.environments.append(Environment(
                workspace: profile.name, isSchool: false, platform: platform,
                learnedJamfProURL: platform.flatMap { learnedJamfProURLs[$0] }))
        }
        for profile in platforms where !claimed.contains(profile.name) {
            result.environments.append(Environment(
                workspace: profile.name, isSchool: false, platform: nil,
                learnedJamfProURL: learnedJamfProURLs[profile.name]))
        }
        for profile in open where profile.product == .school {
            result.environments.append(Environment(
                workspace: profile.name, isSchool: true, platform: nil, learnedJamfProURL: nil))
        }
        result.environments.sort { $0.workspace < $1.workspace }
        result.extensions.sort { $0.id < $1.id }

        let targets = result.environments.map(\.workspace)
            + existingWorkspaces.filter { $0.value.protect == nil }.map(\.key)
        result.protectChoices = open.filter {
            // A Protect-only environment's own login is a workspace, never attached elsewhere.
            $0.product == .protect
                && existingKeys[ProfileName.folderKey($0.name)]?.value.isProtectOnly != true
        }.map(\.name).sorted()
            .map { ProtectChoice(profile: $0, suggested: suggestion(for: $0, among: targets)) }
        return result
    }

    /// The longest name that prefixes the login's name and is followed by a character that is
    /// not a letter or digit (R6), compared without case.
    private static func suggestion(for login: String, among names: [String]) -> String? {
        let lower = login.lowercased()
        return names.filter { name in
            let prefix = name.lowercased()
            guard lower.hasPrefix(prefix) else { return false }
            let next = lower[lower.index(lower.startIndex, offsetBy: prefix.count)...].first
            return next.map { !$0.isLetter && !$0.isNumber } ?? false
        }.max(by: { $0.count < $1.count })
    }
}
