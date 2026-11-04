import Foundation

/// What the Add sheet offers (environment spec 5.1, first slice): a new workspace for Jamf Pro,
/// the Platform API or Jamf School, Jamf Protect added to the current workspace, and the jamf-cli
/// profiles no workspace uses. Pure; `AddSheetDiscovery.load` supplies the disk and jamf-cli facts.
enum AddSheetPlan {
    /// What the sheet says once Set up workspace finished for `name`: the workspace exists, so
    /// the row leaves the list, and a first collect that failed must be said here instead.
    /// `note` is the connection check's word on a profile it let through (a missing permission,
    /// or no answer): the row that showed it is gone by then, so the message carries it.
    static func adoptionOutcome(
        name: String, status: ExistingCLISetupFlow.ProfileStatus?, note: String? = nil
    ) -> (message: String?, error: String?) {
        if case .failed(let reason) = status {
            return (nil, L("\(name)'s workspace was created, but its first collect failed (\(reason)). Fix the cause, then collect from that workspace."))
        }
        let done = L("\(name) is set up. Switch to it from the workspace menu.")
        return (note.map { done + " " + $0 } ?? done, nil)
    }

    /// Why the Add sheet stays closed, or nil. Replacing a setup that has already registered a
    /// jamf-cli profile or created a workspace would drop it without its Start over cleanup and
    /// leave that profile behind as unassigned.
    static func addRefusal(onboardingRunHasWork: Bool) -> String? {
        onboardingRunHasWork
            ? L("Finish the setup in progress before adding another connection. It has already saved a jamf-cli profile or workspace folder.")
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
            /// A Jamf Protect login (`.protect`) added to the current Jamf Pro or Jamf School
            /// workspace, or a Platform login (`.platform`) added to a Jamf Pro one.
            case addToCurrent(ProfilesConfigWriter.Slot)
            /// Nothing the app can do with it today, and why.
            case unavailable(String)

            var isAddOn: Bool {
                if case .addToCurrent = self { return true }
                return false
            }
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
    /// named by a workspace's config.yaml (`EnvironmentProfiles.connectedProfiles`). Names
    /// compare by folder key, since a case variant shares its workspace's folder. `unusable` holds
    /// `ProfileService.unusableProfiles` explanations.
    static func unassigned(
        profiles: [JamfCLIProfile],
        workspaces: [String],
        paired: Set<String>,
        unusable: [String: String],
        platformSlotOpen: Bool = false,
        platformSuggestedElsewhere: Set<String> = []
    ) -> [UnassignedProfile] {
        let used = Set((workspaces + Array(paired)).map(ProfileName.folderKey))
        return profiles
            .filter { !used.contains(ProfileName.folderKey($0.name)) }
            .map { profile in
                UnassignedProfile(
                    name: profile.name, product: profile.product, url: profile.url,
                    use: use(
                        of: profile, unusable: unusable[profile.name],
                        platformSlotOpen: platformSlotOpen
                            && !platformSuggestedElsewhere.contains(profile.name)),
                    authMethod: profile.authMethod, platformLevel: profile.platformLevel)
            }
    }

    private static func use(
        of profile: JamfCLIProfile, unusable: String?, platformSlotOpen: Bool
    ) -> UnassignedProfile.Use {
        if let unusable { return .unavailable(unusable) }
        if let reason = ExistingCLISetupFlow.scopeRefusal(for: profile) {
            return .unavailable(reason)
        }
        // A Protect login is added to the current workspace; the flow refuses it only as a
        // workspace of its own.
        if profile.product == .protect { return .addToCurrent(.protect) }
        if let reason = ExistingCLISetupFlow.refusal(for: profile) { return .unavailable(reason) }
        // D24: a Platform login becomes a slot of the current environment, not a workspace.
        if platformSlotOpen, profile.auth?.isPlatform == true { return .addToCurrent(.platform) }
        return .newWorkspace
    }

    /// The line under an unassigned oauth2 profile that reaches the same Jamf Pro as a Platform
    /// workspace, keyed by the unassigned profile's name (R3: under D17 the Platform workspace's
    /// MDM slot cannot take it, so joining the two is P7's merge). A free Platform profile beside
    /// an oauth2 workspace is a suggestion instead (`EnvironmentProposal`). `learn` gives a
    /// platform profile's Jamf Pro URL, and nil finds nothing.
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
            guard profile.auth?.isPlatform != true, let other = workspaces.first(where: {
                PlatformTwin.twins(ofPlatformProfile: $0, among: [profile], learn: learn) != nil
            })?.name else { continue }
            notes[profile.name] = sameJamfProNote(other)
        }
        return notes
    }

    private static func sameJamfProNote(_ other: String) -> String {
        L("Same Jamf Pro as \(other), which has a workspace. A second workspace collects the fleet twice, so history is split and fleet totals count it twice. Set it up only to collect it anyway.")
    }

    /// The note for each Platform profile `EnvironmentProposal` suggests for a workspace, whichever
    /// workspace that is: where it is not an add row (it is suggested for another one), New
    /// workspace would otherwise offer a second workspace for a fleet that already has one.
    static func suggestionNotes(
        _ suggestions: [EnvironmentProposal.Extension]
    ) -> [String: String] {
        Dictionary(
            suggestions.map { ($0.profile, sameJamfProNote($0.workspace)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The add-on rows the workspace can take now: a Protect login while no Protect profile is
    /// named, a Platform login while the `platform` slot is open.
    static func addOnRows(
        _ rows: [UnassignedProfile], acceptsProtect: Bool, acceptsPlatform: Bool
    ) -> [UnassignedProfile] {
        rows.filter {
            switch $0.use {
            case .addToCurrent(.protect): acceptsProtect
            case .addToCurrent(.platform): acceptsPlatform
            default: false
            }
        }
    }

    /// The choice the sheet opens on; the user can always change it. A product asked for by
    /// the caller, or an unassigned MDM login (the current workspace already has one), opens
    /// New workspace; a suggestion for the current workspace, or an unassigned Protect or
    /// Platform login it can take, opens Add to current (spec 5.1).
    static func preselection(
        unassigned: [UnassignedProfile],
        currentAcceptsProtect: Bool,
        currentAcceptsPlatform: Bool = false,
        suggestedForCurrent: Bool = false,
        requested: NewProduct?
    ) -> Choice {
        guard requested == nil, currentAcceptsProtect || currentAcceptsPlatform else {
            return .newWorkspace
        }
        if suggestedForCurrent && currentAcceptsPlatform { return .addToCurrent }
        if unassigned.contains(where: { $0.use == .newWorkspace }) { return .newWorkspace }
        let addOns = addOnRows(
            unassigned, acceptsProtect: currentAcceptsProtect,
            acceptsPlatform: currentAcceptsPlatform)
        return addOns.isEmpty ? .newWorkspace : .addToCurrent
    }

    /// The current workspace can take a Protect profile now: it takes Protect at all and
    /// discovery has read its config.yaml without finding one already named.
    static func currentAcceptsProtect(
        takesProtect: Bool, discovery: AddSheetDiscovery?
    ) -> Bool {
        takesProtect && discovery != nil && discovery?.currentProtect == nil
    }

    /// The current workspace can take a Platform profile now: it has a `jamf_pro` slot (a School
    /// workspace's Platform access lives in its School profile) and no `platform` slot.
    static func currentAcceptsPlatform(
        takesProtect: Bool, discovery: AddSheetDiscovery?
    ) -> Bool {
        takesProtect && discovery?.platformSlotOpen == true
    }

    /// The step the sheet shows: Add to current only while the workspace can take add-ons,
    /// else New workspace, whatever was chosen.
    static func step(choice: Choice, takesProtect: Bool) -> Choice {
        takesProtect ? choice : .newWorkspace
    }

    /// The rows the chosen step lists. Add to current lists the Protect and Platform logins the
    /// workspace can still take; New workspace lists everything else, a refused profile
    /// (Security Cloud, organization level, unusable name) included with its reason.
    static func visibleRows(
        choice: Choice, takesProtect: Bool, discovery: AddSheetDiscovery?
    ) -> [UnassignedProfile] {
        let rows = discovery?.unassigned ?? []
        if step(choice: choice, takesProtect: takesProtect) == .addToCurrent {
            return addOnRows(
                rows,
                acceptsProtect: currentAcceptsProtect(
                    takesProtect: takesProtect, discovery: discovery),
                acceptsPlatform: currentAcceptsPlatform(
                    takesProtect: takesProtect, discovery: discovery))
        }
        return rows.filter { !$0.use.isAddOn }
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
            if currentAcceptsPlatform(takesProtect: takesProtect, discovery: discovery) {
                return .empty(L("No profile in jamf-cli is free to add. Connect new above."))
            }
            return .empty(
                currentAcceptsProtect(takesProtect: takesProtect, discovery: discovery)
                    ? L("No Jamf Protect profile in jamf-cli is free to add. Connect new above.")
                    : L("This workspace already has Jamf Protect."))
        }
        return .empty(L("Every jamf-cli profile already has a workspace. Profiles made in Terminal appear here after Re-check."))
    }

    /// The choice after Re-check read `found`. Rows come from `found` alone, so a profile added
    /// since the last read appears and one that gained a workspace leaves. The choice is
    /// preselected again only while the user has not picked one.
    static func recheck(
        found: AddSheetDiscovery, takesProtect: Bool, choice: Choice, choiceTouched: Bool,
        requested: NewProduct?, current: String? = nil
    ) -> Choice {
        guard !choiceTouched else { return choice }
        return preselection(
            unassigned: found.unassigned ?? [],
            currentAcceptsProtect: currentAcceptsProtect(
                takesProtect: takesProtect, discovery: found),
            currentAcceptsPlatform: currentAcceptsPlatform(
                takesProtect: takesProtect, discovery: found),
            suggestedForCurrent: current.map(found.hasSuggestion(for:)) ?? false,
            requested: requested)
    }

    // MARK: - Platform API add-on

    /// Why a Platform profile is not written to a workspace, or nil. Unknown never blocks:
    /// we could not ask (`PlatformHostCheck`).
    static func platformHostRefusal(
        profile: String, verdict: PlatformHostCheck.Verdict
    ) -> String? {
        guard case .different(let jamfPro, let platform) = verdict else { return nil }
        return L("\(profile) reaches \(platform), not this workspace's Jamf Pro (\(jamfPro)). Nothing was changed.")
    }

    static func platformAddedMessage(profile: String, workspace: String) -> String {
        L("Platform API profile \(profile) added to \(workspace). The next collect uses it for the Platform reports.")
    }

    static func suggestionText(_ suggestion: EnvironmentProposal.Extension) -> String {
        L("\(suggestion.profile) reaches the same Jamf Pro as \(suggestion.workspace). Add it?")
    }

    /// The host check on jamf-cli; blocks, so callers run it off the main actor. With no
    /// jamf-cli the answer is unknown.
    static func liveHostVerdict(workspace: String, platform: String) -> PlatformHostCheck.Verdict {
        guard let jamfPro = EnvironmentProfiles.read(workspace: workspace).jamfPro else {
            return .unknown
        }
        guard let binary = ExecutableLocator.locate("jamf-cli") else { return .unknown }
        let urls = PlatformHostCheck.live(jamfPro, platform, binary)
        return PlatformHostCheck.verdict(
            jamfProURL: urls.jamfPro, platformJamfProURL: urls.platform)
    }
}

/// What the Add sheet reads when it opens and on Re-check. `load` runs `jamf-cli config list`,
/// so callers run it off the main actor.
struct AddSheetDiscovery: Sendable {
    /// Nil when jamf-cli's profiles could not be read, which is not the same as "none".
    var unassigned: [AddSheetPlan.UnassignedProfile]?
    /// The Protect profile the current workspace's config.yaml names, if any.
    var currentProtect: String?
    /// The current workspace's `platform` slot, or the workspace itself when its own profile is
    /// a Platform one (it collects the Platform kinds itself).
    var currentPlatform: String?
    /// The current workspace has a `jamf_pro` slot. A School workspace has none.
    var currentHasJamfPro = false
    /// Platform profiles that reach the Jamf Pro of a workspace whose `platform` slot is empty.
    var suggestions: [EnvironmentProposal.Extension] = []
    /// `AddSheetPlan.twinNotes` for the unassigned profiles.
    var twinNotes: [String: String] = [:]

    var platformSlotOpen: Bool { currentHasJamfPro && currentPlatform == nil }

    func hasSuggestion(for workspace: String) -> Bool {
        let key = ProfileName.folderKey(workspace)
        return suggestions.contains { ProfileName.folderKey($0.workspace) == key }
    }

    /// `probeTwins` asks Jamf Pro for a Platform profile's server when no URL is stored; the
    /// sheet loads without it first, so a slow answer never holds the list.
    static func load(currentWorkspace: String?, probeTwins: Bool = false) -> AddSheetDiscovery {
        let root = ProfileService.workspacesRoot()
        let currentRead = currentWorkspace.map {
            EnvironmentProfiles.read(workspace: $0, under: root)
        }
        let currentProtect = currentRead?.protect
        guard let listed = ProfileService.listJamfCLIProfiles(scheduleCounts: [:]) else {
            return AddSheetDiscovery(unassigned: nil, currentProtect: currentProtect)
        }
        let ownIsPlatform = listed.first { $0.name == currentWorkspace }?.auth?.isPlatform == true
        let currentPlatform = currentRead?.platform ?? (ownIsPlatform ? currentWorkspace : nil)
        let currentHasJamfPro = currentRead?.jamfPro != nil
        let names = listed.map(\.name)
        // A Protect or Security Cloud login's own folder (made by 2.9.0) is not a workspace.
        let listedWorkspaces = listed.filter {
            !$0.product.isNeverAWorkspace && ProfileService.hasWorkspace($0.name, under: root)
        }
        let workspaces = listedWorkspaces.map(\.name)
            + ProfileService.localOnlyWorkspaces(under: root, cliNames: names)
        var paired = Set<String>()
        for workspace in workspaces {
            paired.formUnion(
                EnvironmentProfiles.read(workspace: workspace, under: root).connectedProfiles)
        }
        let unusable = ProfileService.unusableProfiles(in: names).mapValues(\.explanation)
        let store = ConnectionStore()
        var learned: [String: String?] = [:]
        func learn(_ name: String) -> String? {
            if let known = learned[name] { return known }
            let url = store.jamfProURL(profile: name)
                ?? (probeTwins && !Task.isCancelled
                    ? PlatformTwin.learnJamfProURL(profile: name) : nil)
            learned[name] = .some(url)
            return url
        }
        var learnedURLs: [String: String] = [:]
        for profile in listed where profile.auth?.isPlatform == true
            && !workspaces.contains(profile.name) {
            learnedURLs[profile.name] = learn(profile.name)
        }
        let proposal = EnvironmentProposal.propose(
            profiles: listed, learnedJamfProURLs: learnedURLs,
            existingWorkspaces: Dictionary(
                workspaces.map { ($0, EnvironmentProfiles.read(workspace: $0, under: root)) },
                uniquingKeysWith: { first, _ in first }),
            unusable: unusable)
        // A profile that reaches another workspace's Jamf Pro is that workspace's suggestion; the
        // host check fails open, so it is never offered as this one's add row.
        let currentKey = currentWorkspace.map(ProfileName.folderKey)
        let elsewhere = Set(proposal.extensions
            .filter { ProfileName.folderKey($0.workspace) != currentKey }.map(\.profile))
        let unassigned = AddSheetPlan.unassigned(
            profiles: listed, workspaces: workspaces, paired: paired, unusable: unusable,
            platformSlotOpen: currentHasJamfPro && currentPlatform == nil,
            platformSuggestedElsewhere: elsewhere)
        let free = Set(unassigned.filter { $0.use == .newWorkspace }.map(\.name))
        let twinNotes = AddSheetPlan.twinNotes(
            unassigned: listed.filter { free.contains($0.name) }, workspaces: listedWorkspaces,
            learn: learn)
        return AddSheetDiscovery(
            unassigned: unassigned, currentProtect: currentProtect,
            currentPlatform: currentPlatform, currentHasJamfPro: currentHasJamfPro,
            suggestions: proposal.extensions,
            twinNotes: twinNotes.merging(
                AddSheetPlan.suggestionNotes(proposal.extensions)) { first, _ in first })
    }
}
