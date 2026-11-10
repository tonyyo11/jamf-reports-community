import SwiftUI
import AppKit

/// Secondary onboarding (#181 follow-on) — shown instead of the main shell on
/// first launch when jamf-cli is already configured (profiles exist, so the
/// connection onboarding never runs) but no profile has an app workspace yet.
///
/// One guided page, in `FirstLaunchChooserView`'s visual language: pick the
/// profiles to set up, choose the automated-scan policy, then run workspace
/// init + the first collection so dashboards populate and Trends gets its
/// starting data point. Skipping is always available — everything here stays
/// reachable later (Overview "Collect now", Automation tab).
struct ExistingCLISetupView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(ExistingCLISetupFlow.outcomeKey) private var outcomeRaw = ""
    @State private var flow: ExistingCLISetupFlow
    @State private var isFinishing = false
    @State private var pendingSharedRoot: URL?
    @State private var existingRootMessage: String?
    /// Protect pickers the user changed, which ends "Suggested by name".
    @State private var touchedProtect: Set<String> = []

    init(profiles: [JamfCLIProfile]) {
        _flow = State(initialValue: ExistingCLISetupFlow(profiles: profiles))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                existingWorkspaceCard
                profilesCard
                automationCard
                runCard
                // The run card already offers Skip after a run that created no workspace.
                if !flow.canRetry { skipFootnote }
            }
            .padding(EdgeInsets(top: 56, leading: 60, bottom: 40, trailing: 60))
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.winBG)
        .sharedFolderConsent(pending: $pendingSharedRoot) { applyExistingRoot($0) }
        .task { await flow.resolveProposal() }
    }

    // MARK: - Existing workspace

    /// A rebuilt Mac or a second Mac on a team folder already has a workspace;
    /// initializing a new one beside it is the wrong first step and, before
    /// this card existed, the only step offered. Pointing at the folder is what
    /// Settings › Workspace location does — same picker, same consent.
    private var existingWorkspaceCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Already have a workspace folder?")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.fg)
                Text("If your reporting workspace already exists — a synced team folder, or a folder from a previous install — point the app at it and skip the steps below. Pick the folder that contains the profile folders.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                PNPButton(title: L("Choose workspace folder…"), icon: "folder", size: .sm) {
                    chooseExistingRoot()
                }
                .disabled(isLocked || isFinishing)
                .help("Use a folder that already holds \(WorkspaceRootStore.displayRoot)-style profile workspaces.")
                if let existingRootMessage {
                    Text(existingRootMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.warnSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chooseExistingRoot() {
        guard let url = WorkspaceFolderPicker.choose() else { return }
        // Same gate as Settings: a synced folder widens who can read raw fleet
        // data, and that is a call the operator makes knowingly, right here.
        if CloudStorage.isSharedStorage(url) {
            pendingSharedRoot = url
            return
        }
        applyExistingRoot(url)
    }

    /// Point the app at `url`. When at least one configured profile has a
    /// workspace there, `ContentView`'s `shouldOffer` turns false on the reload
    /// and the shell appears; the outcome is recorded `.completed` so a later
    /// wipe re-offers setup, exactly as a finished initialization would. When
    /// nothing is found the root still changes (it is what the operator asked
    /// for) but the screen stays, saying what it looked for.
    private func applyExistingRoot(_ url: URL) {
        if let message = workspace.adoptExistingRoot(url) {
            existingRootMessage = message
            return
        }
        existingRootMessage = nil
        outcomeRaw = ExistingCLISetupFlow.SetupOutcome.completed.rawValue
    }

    // MARK: - Header

    private var headerSubtitle: String {
        let count = flow.proposal.environments.count
        return count == 1
            ? L("Found 1 environment to set up. Three steps and the app is live: create its reporting workspace, choose how often data refreshes automatically, and run a first collection so the dashboards and trend history have a starting point.")
            : L("Found \(count) environments to set up. Three steps and the app is live: create a reporting workspace for each environment, choose how often data refreshes automatically, and run a first collection so the dashboards and trend history have a starting point.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: L("First launch"), tone: .gold)
            Text("jamf-cli is already set up.")
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .accessibilityAddTraits(.isHeader)
            Text(headerSubtitle)
                .font(.body)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(maxWidth: 700, alignment: .leading)
        }
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                stepTitle(number: 1, title: L("Environments to set up"))
                ForEach(flow.proposal.environments) { environmentCard($0) }
                if !flow.proposal.protectChoices.isEmpty { protectPickers }
                notSetUp
                Text(
                    "Each environment gets its own workspace under \(WorkspaceRootStore.displayRoot)/ — config, cached snapshots, and generated reports stay per-tenant."
                )
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    private func environmentCard(_ env: EnvironmentProposal.Environment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(profileTitle(env.workspace), isOn: selectionBinding(env.workspace))
                .toggleStyle(.checkbox)
                .disabled(isLocked)
            slotRow(env.isSchool ? L("Jamf School") : L("Jamf Pro"), env.workspace)
            if let platform = env.platform, !flow.removedPlatform.contains(platform) {
                HStack {
                    slotRow(L("Platform API"), platform)
                    PNPButton(title: L("Remove"), size: .sm) {
                        flow.removePlatform(from: env.workspace)
                    }
                    .disabled(isLocked || !flow.selected.contains(env.workspace))
                    .accessibilityLabel(L("Remove Platform API profile \(platform)"))
                }
            }
            ForEach(protectLogins(in: env.workspace), id: \.self) {
                slotRow(L("Jamf Protect"), $0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Colors.fgMuted.opacity(0.3)))
    }

    private func slotRow(_ product: String, _ profile: String) -> some View {
        Text(verbatim: "\(product) · \(profile)")
            .font(.callout)
            .foregroundStyle(Theme.Colors.fgMuted)
            .padding(.leading, 20)
    }

    private func protectLogins(in workspace: String) -> [String] {
        flow.proposal.protectChoices.map(\.profile)
            .filter { assignedEnvironment($0) == workspace }
    }

    /// An assignment to an unticked environment reads as "Not now"; the flow keeps it so
    /// ticking the environment again restores it.
    private func assignedEnvironment(_ login: String) -> String? {
        (flow.protectAssignment[login] ?? nil).flatMap { flow.selected.contains($0) ? $0 : nil }
    }

    private var protectPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: L("Jamf Protect logins"), tone: .gold)
            ForEach(flow.proposal.protectChoices) { choice in
                VStack(alignment: .leading, spacing: 2) {
                    Picker(choice.profile, selection: protectBinding(choice.profile)) {
                        Text("Not now").tag(String?.none)
                        ForEach(protectTargets(for: choice.profile), id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                    .disabled(isLocked)
                    if assignedEnvironment(choice.profile) == choice.suggested,
                       choice.suggested != nil, !touchedProtect.contains(choice.profile) {
                        Text("Suggested by name")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
            }
        }
    }

    /// The ticked environments `login` can go to: one Protect login each, so an environment
    /// another login holds is left out.
    private func protectTargets(for login: String) -> [String] {
        let held = Set(flow.proposal.protectChoices.map(\.profile)
            .filter { $0 != login }.compactMap(assignedEnvironment))
        return flow.proposal.environments.map(\.workspace)
            .filter { flow.selected.contains($0) && !held.contains($0) }
    }

    @ViewBuilder
    private var notSetUp: some View {
        let removed = flow.proposal.environments.compactMap(\.platform)
            .filter(flow.removedPlatform.contains)
        let rows = flow.proposal.unassigned.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
            + removed.map { ($0, L("Removed from its environment.")) }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(text: L("Not set up"), tone: .gold)
                ForEach(rows, id: \.0) { profileNote("\($0.0): \($0.1)") }
            }
        }
    }

    private func protectBinding(_ login: String) -> Binding<String?> {
        Binding(
            get: { assignedEnvironment(login) },
            set: {
                touchedProtect.insert(login)
                flow.protectAssignment[login] = .some($0)
            }
        )
    }

    private func profileTitle(_ name: String) -> String {
        let isSchool = flow.proposal.environments.first { $0.workspace == name }?.isSchool == true
        return isSchool ? L("\(name) (Jamf School)") : name
    }

    private func profileNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.Colors.warnSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Automation

    private var automationCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                stepTitle(number: 2, title: L("Automated scans"))
                AutomationChoiceFields(choice: automationChoice, isLocked: isLocked)
            }
        }
    }

    private var automationChoice: Binding<AutomationSetupChoice> {
        Binding(
            get: {
                AutomationSetupChoice(
                    enabled: flow.enableAutomation, scanWeekday: flow.scanWeekday,
                    reportsCadence: flow.reportsCadence, runTime: flow.runTime)
            },
            set: {
                flow.enableAutomation = $0.enabled
                flow.scanWeekday = $0.scanWeekday
                flow.reportsCadence = $0.reportsCadence
                flow.runTime = $0.runTime
            }
        )
    }

    // MARK: - Run

    private var runCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                stepTitle(number: 3, title: L("First collection"))
                Text("Initializes each workspace, then fetches live jamf-cli data. A few minutes per profile on on-prem servers; faster on cloud.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)

                if flow.isRunning || flow.didComplete {
                    ForEach(flow.profileNames.filter(flow.selected.contains), id: \.self) { name in
                        statusRow(name)
                    }
                    if !flow.kindStatuses.isEmpty {
                        kindDetailDisclosure
                    }
                }

                if flow.didComplete {
                    completionSummary
                }
                if flow.canContinue {
                    PNPButton(
                        title: isFinishing ? L("Finishing…") : L("Continue to dashboard"),
                        icon: "arrow.right", style: .gold, size: .lg
                    ) { finish() }
                    .disabled(isFinishing)
                } else {
                    PNPButton(
                        title: flow.isRunning ? L("Collecting…")
                            : (flow.canRetry ? L("Try again") : L("Initialize & run first collection")),
                        icon: flow.isRunning ? "hourglass" : "play.fill",
                        style: .gold, size: .lg
                    ) {
                        guard !flow.isRunning, !flow.selected.isEmpty, flow.proposalResolved
                        else { return }
                        Task { await flow.run() }
                    }
                    .disabled(flow.isRunning || flow.selected.isEmpty || !flow.proposalResolved)
                    if !flow.proposalResolved {
                        Text("Checking which profiles reach the same Jamf Pro…")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    if flow.canRetry {
                        PNPButton(
                            title: L("Skip — set up later"), icon: "arrow.right",
                            style: .ghost, size: .lg
                        ) { skip() }
                    }
                }
            }
        }
    }

    private func statusRow(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIcon(flow.statuses[name] ?? .pending)
                Text(name).font(.callout)
                if case .failed(let reason) = flow.statuses[name] {
                    Text("— \(reason)")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.dangerSoft)
                }
                if let summary = flow.kindSummaries[name],
                   flow.statuses[name] != .collecting {
                    Text("· \(summary.summary)")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                Spacer(minLength: 0)
            }
            if let note = flow.connectionNotes[name] {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .padding(.leading, 28)
            }
            // Live tally while this profile collects — the first collection
            // walks ~30 jamf-cli commands and can run for minutes; without
            // motion users assume it hung (#181 field feedback).
            if flow.statuses[name] == .collecting {
                Text(collectingCaption)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .padding(.leading, 28)
            }
        }
    }

    @State private var kindDetailExpanded = false

    private var kindDetailDisclosure: some View {
        DisclosureGroup(isExpanded: $kindDetailExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(flow.kindStatuses) { entry in
                    HStack(spacing: 6) {
                        Pill(text: entry.outcome.rawValue, tone: entry.outcome.pillTone)
                        Text(entry.kind)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text("Collection detail")
                .font(.caption)
                .foregroundStyle(Theme.Colors.fgMuted)
        }
    }

    private var collectingCaption: String {
        var caption = flow.progress.summary
        if let kind = flow.progress.currentKind {
            caption += L(" · fetching \(kind)…")
        }
        return caption
    }

    @ViewBuilder
    private func statusIcon(_ status: ExistingCLISetupFlow.ProfileStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.Colors.fgMuted)
        case .initializing, .collecting:
            ProgressView().controlSize(.small)
                .accessibilityLabel(status == .initializing ? "Setting up" : "Collecting data")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.ok)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.danger)
        }
    }

    private var completionSummary: some View {
        Text(flow.completionText)
            .font(.footnote)
            .foregroundStyle(
                flow.selectionSummary.failed == 0 ? Theme.Colors.ok : Theme.Colors.warnSoft
            )
    }

    private var skipFootnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.Colors.fgMuted)
            Text("Not now?")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Button("Skip — set up later from the dashboard") { skip() }
                .buttonStyle(.link)
                .font(.footnote)
                .disabled(flow.isRunning || isFinishing)
            Text(verbatim: "·")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            // Records no outcome, so leaving demo mode brings this screen back.
            Button(L("Use demo data")) { workspace.setDemoMode(true) }
                .buttonStyle(.link)
                .font(.footnote)
                .disabled(flow.isRunning || isFinishing)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func stepTitle(number: Int, title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.Colors.winBG)
                .frame(width: 20, height: 20)
                .background(Theme.Colors.goldBright, in: Circle())
            Text(title).font(.headline).foregroundStyle(Theme.Colors.fg)
        }
    }

    private func selectionBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { flow.selected.contains(name) },
            set: { flow.setSelected(name, $0) }
        )
    }

    /// Choices settle while a run is going and once one has created a workspace. After a run
    /// that created none they stay open: another folder or profile choice is the likely fix.
    private var isLocked: Bool { flow.isRunning || flow.canContinue }

    private func skip() {
        outcomeRaw = ExistingCLISetupFlow.SetupOutcome.skipped.rawValue
    }

    /// Persist the automation policy (when enabled), apply it (registers the
    /// ticker), and only then record the completed outcome that re-routes
    /// ContentView to the shell — an unawaited apply would race the view
    /// swap (see the AutomationTab relocation note, 6101086).
    private func finish() {
        guard flow.canContinue, !isFinishing else { return }
        isFinishing = true
        Task {
            flow.recordLearnedURLs()
            if flow.enableAutomation {
                UserDefaults.standard.set(
                    flow.configuredPolicy().serialize(), forKey: AutomationPolicy.storageKey
                )
                await workspace.applyAutomationPolicy()
                workspace.warnIfTickerNeedsApproval()
            }
            workspace.reloadFromDisk()
            isFinishing = false
            outcomeRaw = ExistingCLISetupFlow.SetupOutcome.completed.rawValue
        }
    }
}

// MARK: - CollectKindStatus.Outcome + Pill

private extension ExistingCLISetupFlow.CollectKindStatus.Outcome {
    /// Maps collect outcomes to the matching Pill tone.
    var pillTone: Pill.Tone {
        switch self {
        case .ok:   .teal
        case .warn: .warn
        case .skip: .muted
        }
    }
}

#if DEBUG
private func previewProfile(
    _ name: String, _ product: JamfCLIProduct, auth: String = "oauth2"
) -> JamfCLIProfile {
    var profile = JamfCLIProfile(name: name, url: "", schedules: 0, status: .idle)
    profile.product = product
    profile.authMethod = auth
    return profile
}

private let previewProfiles: [JamfCLIProfile] = [
    previewProfile("Example", .pro),
    previewProfile("Example-API", .pro, auth: "platform"),
    previewProfile("Example-Dev", .pro),
    previewProfile("Example-School", .school, auth: "apikey"),
    previewProfile("Example-Protect", .protect),
    previewProfile("Example-Cloud", .securityCloud, auth: "security"),
]

#Preview {
    ExistingCLISetupView(profiles: previewProfiles)
        .environment(WorkspaceStore(demoMode: false))
        .preferredColorScheme(.dark)
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
}
#endif
