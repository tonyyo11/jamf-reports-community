import Foundation

/// What the Data Sources "Environment" card shows for one workspace: one row per product slot the
/// environment can hold. Pure, so the view only draws it (environment spec section 6).
struct EnvironmentCardState: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let slot: ProfilesConfigWriter.Slot
        let product: String
        let profile: String?
        let authMethod: String?
        /// "environment" or "tenant" for a Platform API profile, else nil.
        let level: String?
        let newestSnapshot: Date?
        let pinNeedsConfirming: Bool

        /// The MDM slot is the workspace itself; only the others can be disconnected.
        var canRemove: Bool { profile != nil && slot != .jamfPro && slot != .jamfSchool }
        var id: String { slot.rawValue }
    }

    let workspace: String
    /// False: the slots were derived from the old keys, no `profiles:` block exists.
    let fromBlock: Bool
    let rows: [Row]

    static func build(
        workspace: String, environment: EnvironmentProfiles,
        resolve: (String) -> ProfileAuthMethod.Resolved?,
        newest: (ProfilesConfigWriter.Slot) -> Date?,
        drifted: (SharedConfigPin.Key) -> Bool
    ) -> EnvironmentCardState {
        func row(
            _ slot: ProfilesConfigWriter.Slot, _ product: String, _ profile: String?,
            pin: SharedConfigPin.Key? = nil
        ) -> Row {
            let resolved = profile.flatMap(resolve)
            let isPlatform = resolved?.method == .platform
            let level = isPlatform && resolved?.isOrganizationLevel == false
                ? (resolved?.isTenantLevel == true ? "tenant" : "environment") : nil
            return Row(
                slot: slot, product: product, profile: profile,
                authMethod: resolved?.authMethod, level: level,
                newestSnapshot: profile == nil ? nil : newest(slot),
                pinNeedsConfirming: pin.map(drifted) ?? false)
        }
        var rows: [Row] = []
        if environment.isSchool {
            rows.append(row(.jamfSchool, L("Jamf School"), environment.jamfSchool))
        } else {
            rows.append(row(.jamfPro, L("Jamf Pro"), environment.jamfPro))
            rows.append(row(.platform, L("Platform API"), environment.platform,
                            pin: .platformProfile))
        }
        // protectWithoutProfile: Protect is on but names no login, so the row stays empty.
        rows.append(row(.protect, L("Jamf Protect"), environment.protect, pin: .protectProfile))
        return EnvironmentCardState(
            workspace: workspace, fromBlock: environment.source == .profilesBlock, rows: rows)
    }
}
