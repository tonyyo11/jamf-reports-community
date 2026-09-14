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

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    init(profileNames: [String]) {
        _flow = State(initialValue: ExistingCLISetupFlow(profileNames: profileNames))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                existingWorkspaceCard
                profilesCard
                automationCard
                runCard
                skipFootnote
            }
            .padding(EdgeInsets(top: 56, leading: 60, bottom: 40, trailing: 60))
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.winBG)
        .sharedFolderConsent(pending: $pendingSharedRoot) { applyExistingRoot($0) }
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
                Text("If your reporting workspace already exists — a synced team folder, or a "
                    + "folder from a previous install — point the app at it and skip the steps "
                    + "below. Pick the folder that contains the profile folders.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                PNPButton(title: "Choose workspace folder…", icon: "folder", size: .sm) {
                    chooseExistingRoot()
                }
                .disabled(flow.isRunning || isFinishing || flow.didComplete)
                .help("Use a folder that already holds \(WorkspaceRootStore.displayRoot)-style "
                    + "profile workspaces.")
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
        if CloudStorage.provider(for: url) != nil {
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
        let count = flow.profileNames.count
        let noun = count == 1 ? "profile" : "profiles"
        return "Found \(count) configured \(noun). Three steps and the app is live: "
            + "create a reporting workspace for each profile, choose how often data "
            + "refreshes automatically, and run a first collection so the dashboards "
            + "and trend history have a starting point."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: "First launch", tone: .gold)
            Text("jamf-cli is already set up.")
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text(headerSubtitle)
                .font(.body)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(maxWidth: 700, alignment: .leading)
        }
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                stepTitle(number: 1, title: "Profiles to set up")
                ForEach(flow.profileNames, id: \.self) { name in
                    Toggle(name, isOn: selectionBinding(name))
                        .toggleStyle(.checkbox)
                        .disabled(flow.isRunning || flow.didComplete)
                }
                Text(
                    "Each profile gets its own workspace under "
                        + "\(WorkspaceRootStore.displayRoot)/ — "
                        + "config, cached snapshots, and generated reports stay per-tenant."
                )
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    // MARK: - Automation

    private var automationCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                stepTitle(number: 2, title: "Automated scans")
                Toggle(isOn: $flow.enableAutomation) {
                    Text("Keep data fresh automatically").font(.callout.weight(.semibold))
                }
                .toggleStyle(.switch)
                .disabled(flow.isRunning || flow.didComplete)
                Text("A daily collect keeps dashboards and Trends current; a weekly deep scan "
                    + "runs the two per-device queries. Adjust anytime from the Automation tab.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
                if flow.enableAutomation {
                    Divider().background(Theme.Colors.hairline)
                    Picker("Deep scan & report day", selection: $flow.scanWeekday) {
                        ForEach(0..<7, id: \.self) { index in
                            Text(Self.weekdays[index]).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                    .disabled(flow.isRunning || flow.didComplete)
                    Picker("Generate reports", selection: $flow.reportsCadence) {
                        Text("Off").tag(AutomationPolicy.ReportsCadence.off)
                        Text("Daily").tag(AutomationPolicy.ReportsCadence.daily)
                        Text("Weekly").tag(AutomationPolicy.ReportsCadence.weekly)
                        Text("Monthly").tag(AutomationPolicy.ReportsCadence.monthly)
                    }
                    .pickerStyle(.segmented)
                    .disabled(flow.isRunning || flow.didComplete)
                    HStack {
                        Text("Run automation at")
                        TextField("06:00", text: $flow.runTime)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .disabled(flow.isRunning || flow.didComplete)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - Run

    private var runCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                stepTitle(number: 3, title: "First collection")
                Text("Initializes each workspace, then fetches live jamf-cli data. "
                    + "A few minutes per profile on on-prem servers; faster on cloud.")
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
                    PNPButton(
                        title: isFinishing ? "Finishing…" : "Continue to dashboard",
                        icon: "arrow.right", style: .gold, size: .lg
                    ) { finish() }
                    .disabled(isFinishing)
                } else {
                    PNPButton(
                        title: flow.isRunning ? "Collecting…" : "Initialize & run first collection",
                        icon: flow.isRunning ? "hourglass" : "play.fill",
                        style: .gold, size: .lg
                    ) {
                        guard !flow.isRunning, !flow.selected.isEmpty else { return }
                        Task { await flow.run() }
                    }
                    .disabled(flow.isRunning || flow.selected.isEmpty)
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
            caption += " · fetching \(kind)…"
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
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.ok)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.danger)
        }
    }

    private var completionSummary: some View {
        let summary = flow.selectionSummary
        let text: String
        if summary.failed == 0 {
            text = "All \(summary.succeeded) profile" + (summary.succeeded == 1 ? "" : "s")
                + " collected — dashboards are populated and the first trend point is saved."
        } else {
            text = "\(summary.succeeded) succeeded, \(summary.failed) failed. Failed profiles "
                + "can re-collect from the Overview banner once jamf-cli auth is fixed "
                + "(Sources page shows connection status)."
        }
        return Text(text)
            .font(.footnote)
            .foregroundStyle(summary.failed == 0 ? Theme.Colors.ok : Theme.Colors.warnSoft)
    }

    private var skipFootnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.Colors.fgMuted)
            Text("Not now?")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Button("Skip — set up later from the dashboard") {
                outcomeRaw = ExistingCLISetupFlow.SetupOutcome.skipped.rawValue
            }
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
            set: { on in
                if on { flow.selected.insert(name) } else { flow.selected.remove(name) }
            }
        )
    }

    /// Persist the automation policy (when enabled), apply it (registers the
    /// ticker), and only then record the completed outcome that re-routes
    /// ContentView to the shell — an unawaited apply would race the view
    /// swap (see the AutomationTab relocation note, 6101086).
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            if flow.enableAutomation {
                UserDefaults.standard.set(
                    flow.configuredPolicy().serialize(), forKey: AutomationPolicy.storageKey
                )
                // The user just opted into automation — a ticker Login Items
                // won't run must not be silently absorbed into "setup complete".
                // Only the two states an operator can act on: `.unavailable` is
                // a dev build with no bundled agent, which is not a problem the
                // Login Items pane can fix.
                await workspace.applyAutomationPolicy()
                if workspace.tickerStatus == .requiresApproval
                    || workspace.tickerStatus == .notRegistered {
                    workspace.toast = Toast(
                        message: "Setup finished — allow JamfReports under Login Items › "
                            + "Allow in the Background to start automation",
                        style: .danger
                    )
                }
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

#Preview {
    ExistingCLISetupView(profileNames: ["acme-prod", "acme-dev"])
        .environment(WorkspaceStore(demoMode: false))
        .frame(width: 960, height: 860)
}
