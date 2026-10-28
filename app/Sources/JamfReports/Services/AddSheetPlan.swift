import Foundation

/// What the Add sheet offers (environment spec 5.1, first slice): a new workspace for Jamf Pro,
/// the Platform API or Jamf School, Jamf Protect added to the current workspace, and the jamf-cli
/// profiles no workspace uses. Pure; `AddSheetDiscovery.load` supplies the disk and jamf-cli facts.
enum AddSheetPlan {
    /// What the sheet says once Set up workspace finished for `name`: the workspace exists, so
    /// the row leaves the list, and a first collect that failed must be said here instead.
    static func adoptionOutcome(
        name: String, status: ExistingCLISetupFlow.ProfileStatus?
    ) -> (message: String?, error: String?) {
        if case .failed(let reason) = status {
            return (nil, "\(name)'s workspace was created, but its first collect failed "
                + "(\(reason)). Fix the cause, then collect from that workspace.")
        }
        return ("\(name) is set up. Switch to it from the workspace menu.", nil)
    }

    /// Why the Add sheet stays closed, or nil. Replacing a setup that has already registered a
    /// jamf-cli profile or created a workspace would drop it without its Start over cleanup and
    /// leave that profile behind as unassigned.
    static func addRefusal(onboardingRunHasWork: Bool) -> String? {
        onboardingRunHasWork
            ? "Finish the setup in progress before adding another connection. It has already "
                + "saved a jamf-cli profile or workspace folder."
            : nil
    }

    enum Choice: Equatable, Sendable {
        case newWorkspace
        case addToCurrent
    }

    /// A product a new workspace is set up for, each through its onboarding path.
    enum NewProduct: String, CaseIterable, Identifiable, Sendable {
        case jamfPro, platformAPI, jamfSchool
        var id: String { rawValue }
    }

    struct UnassignedProfile: Identifiable, Equatable, Sendable {
        enum Use: Equatable, Sendable {
            /// A Jamf Pro, Platform API or Jamf School login: set up as a workspace of its own.
            case newWorkspace
            /// A Jamf Protect login: added to the current Jamf Pro or Jamf School workspace.
            case addToCurrent
            /// Nothing the app can do with it today, and why.
            case unavailable(String)
        }

        let name: String
        let product: JamfCLIProduct
        let url: String
        let use: Use
        /// Kept so adoption runs the Platform connection check (`ExistingCLISetupFlow`).
        var authMethod = ""
        var platformLevel: PlatformScopeLevel?
        var id: String { name }
    }

    /// The profile `ExistingCLISetupFlow` adopts for a row, with what its checks read.
    static func adoptionProfile(for row: UnassignedProfile) -> JamfCLIProfile {
        JamfCLIProfile(
            name: row.name, url: row.url, schedules: 0, status: .idle,
            authMethod: row.authMethod, product: row.product, platformLevel: row.platformLevel)
    }

    /// The current workspace takes Jamf Protect: a live workspace on disk, Jamf Pro or, from
    /// 2.11 (Experimental), Jamf School. Demo mode writes nothing.
    static func currentTakesProtect(
        demoMode: Bool, current: String, initialized: [String]
    ) -> Bool {
        !demoMode && initialized.contains(current)
    }

    /// The jamf-cli profiles no workspace uses: neither a workspace folder of their own nor
    /// named by a workspace's `protect.profile` or `school_cli.profile`. Names compare by
    /// folder key, since a case variant shares its workspace's folder. `unusable` holds
    /// `ProfileService.unusableProfiles` explanations.
    static func unassigned(
        profiles: [JamfCLIProfile],
        workspaces: [String],
        paired: Set<String>,
        unusable: [String: String]
    ) -> [UnassignedProfile] {
        let used = Set((workspaces + Array(paired)).map(ProfileName.folderKey))
        return profiles
            .filter { !used.contains(ProfileName.folderKey($0.name)) }
            .map { profile in
                UnassignedProfile(
                    name: profile.name, product: profile.product, url: profile.url,
                    use: use(of: profile, unusable: unusable[profile.name]),
                    authMethod: profile.authMethod, platformLevel: profile.platformLevel)
            }
    }

    private static func use(
        of profile: JamfCLIProfile, unusable: String?
    ) -> UnassignedProfile.Use {
        if let unusable { return .unavailable(unusable) }
        // A Protect login is added to the current workspace; the flow refuses it only as a
        // workspace of its own.
        if profile.product == .protect { return .addToCurrent }
        if let reason = ExistingCLISetupFlow.refusal(for: profile) { return .unavailable(reason) }
        return .newWorkspace
    }

    /// The line under an unassigned profile that reaches the same Jamf Pro as a profile that
    /// already has a workspace, keyed by the unassigned profile's name: an oauth2 profile beside
    /// a platform workspace, or a platform profile beside an oauth2 one. Adoption's rule
    /// (`PlatformTwin`); `learn` gives a platform profile's Jamf Pro URL, and nil finds nothing.
    static func twinNotes(
        unassigned: [JamfCLIProfile],
        workspaces: [JamfCLIProfile],
        learn probe: (String) -> String?
    ) -> [String: String] {
        var notes: [String: String] = [:]
        // One probe per profile: each workspace is compared with every unassigned profile.
        var learned: [String: String?] = [:]
        func learn(_ name: String) -> String? {
            if let known = learned[name] { return known }
            let url = probe(name)
            learned[name] = .some(url)
            return url
        }
        for profile in unassigned {
            let other: String?
            if profile.auth?.isPlatform == true {
                other = PlatformTwin.twins(
                    ofPlatformProfile: profile, among: workspaces, learn: learn)?.twins.first?.name
            } else {
                other = workspaces.first {
                    PlatformTwin.twins(ofPlatformProfile: $0, among: [profile], learn: learn) != nil
                }?.name
            }
            guard let other else { continue }
            notes[profile.name] = "Same Jamf Pro as \(other), which has a workspace. A second "
                + "workspace collects the fleet twice, so history is split and fleet totals count "
                + "it twice. Set it up only to collect it anyway."
        }
        return notes
    }

    /// The choice the sheet opens on; the user can always change it. A product asked for by
    /// the caller, or an unassigned MDM login (the current workspace already has one), opens
    /// New workspace; an unassigned Protect login opens Add to current while the current
    /// workspace can take Jamf Protect.
    static func preselection(
        unassigned: [UnassignedProfile],
        currentAcceptsProtect: Bool,
        requested: NewProduct?
    ) -> Choice {
        guard requested == nil, currentAcceptsProtect else { return .newWorkspace }
        if unassigned.contains(where: { $0.use == .newWorkspace }) { return .newWorkspace }
        if unassigned.contains(where: { $0.use == .addToCurrent }) { return .addToCurrent }
        return .newWorkspace
    }

    /// The current workspace can take a Protect profile now: it takes Protect at all and
    /// discovery has read its config.yaml without finding one already named.
    static func currentAcceptsProtect(
        takesProtect: Bool, discovery: AddSheetDiscovery?
    ) -> Bool {
        takesProtect && discovery != nil && discovery?.currentProtect == nil
    }

    /// The step the sheet shows: Add to current only while the workspace can take Protect,
    /// else New workspace, whatever was chosen.
    static func step(choice: Choice, takesProtect: Bool) -> Choice {
        takesProtect ? choice : .newWorkspace
    }

    /// The rows the chosen step lists. Add to current lists Protect logins only, and none once
    /// the workspace names one; New workspace lists everything else, a refused profile
    /// (Security Cloud, organization level, unusable name) included with its reason.
    static func visibleRows(
        choice: Choice, takesProtect: Bool, discovery: AddSheetDiscovery?
    ) -> [UnassignedProfile] {
        let rows = discovery?.unassigned ?? []
        if step(choice: choice, takesProtect: takesProtect) == .addToCurrent {
            return currentAcceptsProtect(takesProtect: takesProtect, discovery: discovery)
                ? rows.filter { $0.use == .addToCurrent } : []
        }
        return rows.filter { $0.use != .addToCurrent }
    }

    /// What the "Profiles jamf-cli already has" card shows.
    enum Listing: Equatable, Sendable {
        case demo
        case reading
        /// jamf-cli's profiles could not be read, which is not the same as "none".
        case unreadable
        case empty(String)
        case rows([UnassignedProfile])
    }

    static func listing(
        demoMode: Bool, isChecking: Bool, choice: Choice, takesProtect: Bool,
        discovery: AddSheetDiscovery?
    ) -> Listing {
        if demoMode { return .demo }
        if isChecking && discovery == nil { return .reading }
        if let discovery, discovery.unassigned == nil { return .unreadable }
        let rows = visibleRows(choice: choice, takesProtect: takesProtect, discovery: discovery)
        if !rows.isEmpty { return .rows(rows) }
        if step(choice: choice, takesProtect: takesProtect) == .addToCurrent {
            return .empty(
                currentAcceptsProtect(takesProtect: takesProtect, discovery: discovery)
                    ? "No Jamf Protect profile in jamf-cli is free to add. Connect new above."
                    : "This workspace already has Jamf Protect.")
        }
        return .empty("Every jamf-cli profile already has a workspace. Profiles made in "
            + "Terminal appear here after Re-check.")
    }

    /// The choice after Re-check read `found`. Rows come from `found` alone, so a profile added
    /// since the last read appears and one that gained a workspace leaves. The choice is
    /// preselected again only while the user has not picked one.
    static func recheck(
        found: AddSheetDiscovery, takesProtect: Bool, choice: Choice, choiceTouched: Bool,
        requested: NewProduct?
    ) -> Choice {
        guard !choiceTouched else { return choice }
        return preselection(
            unassigned: found.unassigned ?? [],
            currentAcceptsProtect: currentAcceptsProtect(
                takesProtect: takesProtect, discovery: found),
            requested: requested)
    }
}

/// What the Add sheet reads when it opens and on Re-check. `load` runs `jamf-cli config list`,
/// so callers run it off the main actor.
struct AddSheetDiscovery: Sendable {
    /// Nil when jamf-cli's profiles could not be read, which is not the same as "none".
    var unassigned: [AddSheetPlan.UnassignedProfile]?
    /// The Protect profile the current workspace's config.yaml names, if any.
    var currentProtect: String?
    /// `AddSheetPlan.twinNotes` for the unassigned profiles.
    var twinNotes: [String: String] = [:]

    /// `probeTwins` asks Jamf Pro for a Platform profile's server when no URL is stored; the
    /// sheet loads without it first, so a slow answer never holds the list.
    static func load(currentWorkspace: String?, probeTwins: Bool = false) -> AddSheetDiscovery {
        let root = ProfileService.workspacesRoot()
        let currentProtect = currentWorkspace.flatMap {
            ConnectedProducts.read(profile: $0, under: root).protectProfile
        }
        guard let listed = ProfileService.listJamfCLIProfiles(scheduleCounts: [:]) else {
            return AddSheetDiscovery(unassigned: nil, currentProtect: currentProtect)
        }
        let names = listed.map(\.name)
        // A Protect or Security Cloud login's own folder (made by 2.9.0) is not a workspace.
        let listedWorkspaces = listed.filter {
            !$0.product.isNeverAWorkspace && ProfileService.hasWorkspace($0.name, under: root)
        }
        let workspaces = listedWorkspaces.map(\.name)
            + ProfileService.localOnlyWorkspaces(under: root, cliNames: names)
        var paired = Set<String>()
        for workspace in workspaces {
            let products = ConnectedProducts.read(profile: workspace, under: root)
            paired.formUnion([products.protectProfile, products.foreignSchoolProfile]
                .compactMap { $0 })
        }
        let unassigned = AddSheetPlan.unassigned(
            profiles: listed, workspaces: workspaces, paired: paired,
            unusable: ProfileService.unusableProfiles(in: names).mapValues(\.explanation))
        let store = ConnectionStore()
        let free = Set(unassigned.filter { $0.use == .newWorkspace }.map(\.name))
        let twinNotes = AddSheetPlan.twinNotes(
            unassigned: listed.filter { free.contains($0.name) }, workspaces: listedWorkspaces,
            learn: {
                store.jamfProURL(profile: $0)
                    ?? (probeTwins && !Task.isCancelled
                        ? PlatformTwin.learnJamfProURL(profile: $0) : nil)
            })
        return AddSheetDiscovery(
            unassigned: unassigned, currentProtect: currentProtect, twinNotes: twinNotes)
    }
}
