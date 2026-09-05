import SwiftUI
import TipKit

/// Routes the Automation tab between its two modes. Managed automation
/// (`isManaged`) is the "set policy, not cron jobs" editor (`AutomationView`);
/// when it is off the operator manages hand-built LaunchAgents directly
/// (`SchedulesView`). The master toggle lives in BOTH screens so switching modes
/// is always reachable — flipping it here re-routes and reconciles.
struct AutomationTab: View {
    @Environment(WorkspaceStore.self) private var workspace
    @AppStorage(AutomationPolicy.storageKey) private var policyRaw: String = ""

    var body: some View {
        Group {
            if AutomationPolicy.parse(policyRaw).isManaged {
                AutomationView()
            } else {
                SchedulesView()
            }
        }
        // Reconcile on every settled policy change HERE, on the stable parent —
        // toggling managed off swaps the child view, so a reconcile owned by
        // AutomationView would be cancelled mid-debounce before the teardown
        // (managed-agent removal) ran. AutomationTab is never unmounted by the
        // toggle, so the reconcile always completes. (Relocated from 6101086.)
        .task(id: policyRaw) { await reconcileOnPolicyChange() }
    }

    /// Debounce, then reconcile the managed LaunchAgents and toast the result.
    private func reconcileOnPolicyChange() async {
        guard !workspace.demoMode else { return }
        do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
        let outcomes = await workspace.reconcileManagedAutomation()
        guard !outcomes.isEmpty else { return }
        // Reflect the install/remove in any visible schedule list (the manual
        // SchedulesView table reads workspace.schedules) so the table doesn't
        // show agents the reconcile just added or removed until a manual refresh.
        workspace.reloadFromDisk()

        let succeeded = outcomes.filter(\.succeeded)
        let failed = outcomes.filter { !$0.succeeded }
        let installs = succeeded.filter(\.isInstall).count
        let removes = succeeded.count - installs

        var parts: [String] = []
        if installs > 0 { parts.append("\(installs) installed") }
        if removes > 0 { parts.append("\(removes) removed") }

        if failed.isEmpty {
            workspace.toast = Toast(
                message: "Automation applied — \(parts.joined(separator: ", "))", style: .success
            )
        } else {
            let suffix = parts.isEmpty ? "" : "\(parts.joined(separator: ", ")), "
            workspace.toast = Toast(
                message: "Automation applied — \(suffix)\(failed.count) failed — see log",
                style: .danger
            )
            for outcome in failed {
                let label: String
                switch outcome.action {
                case .install(let sched): label = sched.launchAgentLabel ?? sched.name
                case .remove(let lbl): label = lbl
                }
                let reason = outcome.failureReason ?? "unknown error"
                AppLogger.schedule.error(
                    "Reconcile failure for \(label, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
    }
}

/// v2.2.0 Phase 5 — the "set policy, not cron jobs" Automation screen.
///
/// Edits the single app-level `AutomationPolicy` (@AppStorage). When "Manage
/// automation" is on, `ManagedAutomation.reconcile` (run at launch) installs the
/// daily-freshness / weekly-scan / reports / backup all-profiles agents from
/// this policy; turning it off tears them down. Report groups drive the
/// consolidated fleet report.
struct AutomationView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @AppStorage(AutomationPolicy.storageKey) private var policyRaw: String = ""

    // Decoded once per policyRaw change (not on every body pass). `update` still
    // reads/writes `policyRaw`; the `.onChange(of: policyRaw)` below round-trips
    // the new raw back into this @State so bindings and gates read the fresh
    // value. Writing the same value assigns an identical struct (no re-write to
    // policyRaw), so there is no feedback loop.
    @State private var policy: AutomationPolicy = .init()

    // Discovered profiles for the exclusions checklist and new-group form.
    // `ProfileService.discoverLocal()` spawns a jamf-cli subprocess and scans
    // directories, so it runs off-main once per profile switch rather than on
    // every body evaluation.
    @State private var discoveredProfiles: [String] = []

    // Consolidation (retire hand-built agents the managed policy now duplicates).
    @State private var consolidationCandidates: [ScheduleConsolidation.Candidate] = []
    @State private var selectedForRemoval: Set<String> = []
    @State private var showRemovalConfirm = false

    var body: some View {
        PageScaffold(spacing: 16) {
            PageHeader(
                kicker: "Automation",
                title: "Automation Policy",
                subtitle: "Set how often data refreshes and reports generate — it applies to "
                    + "every profile automatically, adjusting as profiles are added or removed."
            )
            if workspace.demoMode {
                Card { Text("Automation is unavailable in demo mode.")
                    .foregroundStyle(Theme.Colors.fgMuted) }
            } else {
                if let warning = ManagedAutomation.bundleLocationWarning() {
                    InlineBanner(icon: "exclamationmark.triangle", tone: .warn) {
                        Text(warning).font(.callout)
                    }
                }
                masterCard
                if !workspace.automationHealthIssues.isEmpty || policy.isManaged {
                    HealthCard(issues: workspace.automationHealthIssues)
                }
                // Notifications apply to any scheduled run — hand-built or managed —
                // so this card shows regardless of `isManaged`.
                NotificationsCard(profile: workspace.profile)
                if policy.isManaged {
                    freshnessCard
                    reportsCard
                    backupsCard
                    scheduleCard
                    exclusionsCard
                    GroupsCard(
                        reportGroups: policy.reportGroups,
                        discoveredProfiles: discoveredProfiles,
                        existingGroupNames: policy.reportGroups.map(\.name),
                        onRemove: removeGroup,
                        onAdd: addGroup
                    )
                    if !consolidationCandidates.isEmpty {
                        ConsolidationCard(
                            candidates: consolidationCandidates,
                            selectedForRemoval: $selectedForRemoval,
                            showRemovalConfirm: $showRemovalConfirm,
                            onConfirmRemoval: { Task { await removeSelectedAgents() } }
                        )
                    }
                }
            }
        }
        // Apply policy edits without a relaunch: `.task(id:)` re-runs (cancelling
        // the prior) on every change, so rapid edits debounce and only the
        // settled state reconciles the managed agents.
        .task(id: policyRaw) { await applyPolicyChange() }
        // Keep the decoded `policy` @State in step with the persisted raw so
        // bindings and visibility gates read the fresh value after any write.
        .onChange(of: policyRaw) { _, newValue in
            policy = AutomationPolicy.parse(newValue)
        }
        // Seed the decoded policy on first appearance (onChange only fires on
        // subsequent edits).
        .task { policy = AutomationPolicy.parse(policyRaw) }
        // Discover profiles off-main once per profile switch (subprocess + I/O).
        .task(id: workspace.profile) { await loadDiscoveredProfiles() }
    }

    /// Refresh the consolidation candidates after a policy edit. The managed-
    /// agent reconcile + toast is owned by `AutomationTab` (the stable parent),
    /// so this view only recomputes what it displays. Candidate detection is a
    /// pure label comparison (`ManagedAutomation.owns`), independent of whether
    /// reconcile has physically (re)installed the managed agents yet, so the two
    /// tasks need no ordering.
    private func applyPolicyChange() async {
        guard !workspace.demoMode else { return }
        do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
        refreshConsolidationCandidates()
    }

    /// Load the discovered profiles off the main actor (subprocess + directory
    /// scan) and assign on main. Reset to empty in demo mode.
    private func loadDiscoveredProfiles() async {
        guard !workspace.demoMode else {
            discoveredProfiles = []
            return
        }
        let names = await Task.detached {
            ProfileService.discoverLocal().map(\.name)
        }.value
        discoveredProfiles = names
    }

    /// Recompute the hand-built agents the active policy duplicates. Reads the
    /// installed agents once (synchronous directory I/O) per call.
    private func refreshConsolidationCandidates() {
        guard !workspace.demoMode, policy.isManaged else {
            consolidationCandidates = []
            selectedForRemoval = []
            return
        }
        let installed = LaunchAgentService.list()
        consolidationCandidates = ScheduleConsolidation.candidates(installed: installed, policy: policy)
        // Drop selections that no longer correspond to a live candidate.
        let live = Set(consolidationCandidates.map(\.label))
        selectedForRemoval = selectedForRemoval.intersection(live)
    }

    /// Archive + remove the user-confirmed hand-built agents, then refresh.
    private func removeSelectedAgents() async {
        let labels = Array(selectedForRemoval)
        guard !labels.isEmpty else { return }
        let result = await Task.detached { LaunchAgentService.archiveAndRemove(labels: labels) }.value
        await MainActor.run {
            refreshConsolidationCandidates()
            let n = result.removed.count
            let suffix = result.rejected.isEmpty ? "" : " (\(result.rejected.count) skipped)"
            workspace.toast = Toast(
                message: "Retired \(n) hand-built schedule\(n == 1 ? "" : "s")\(suffix) — "
                    + "archived under _archived-launchagents",
                style: result.rejected.isEmpty ? .success : .danger
            )
        }
    }

    // MARK: - Master

    private var masterCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: binding(\.isManaged)) {
                    Text("Manage automation").font(.headline)
                }
                .toggleStyle(.switch)
                Text("When on, the app keeps every profile's jamf-cli data fresh and generates "
                    + "reports on the cadence below — no hand-built schedules. When off, the app "
                    + "installs nothing and removes any managed agents.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    // MARK: - Data freshness

    private var freshnessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Data Freshness")
                Toggle("Keep data fresh daily", isOn: binding(\.freshnessEnabled))
                    .toggleStyle(.switch)
                Text("A daily collect (everything except the two heavy per-device scans) so "
                    + "Trends and reports stay current.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                Divider().background(Theme.Colors.hairline)
                Toggle("Weekly deep scan", isOn: binding(\.scanEnabled))
                    .toggleStyle(.switch)
                if policy.scanEnabled {
                    weekdayPicker("Scan day", binding(\.scanWeekday))
                }
                Text("The two per-device --scan-failures queries (patch + update failures) that "
                    + "can stall on-prem Jamf Pro — run weekly, never daily.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    // MARK: - Reports

    private var reportsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Reports")
                Picker("Generate reports", selection: binding(\.reportsCadence)) {
                    Text("Off").tag(AutomationPolicy.ReportsCadence.off)
                    Text("Daily").tag(AutomationPolicy.ReportsCadence.daily)
                    Text("Weekly").tag(AutomationPolicy.ReportsCadence.weekly)
                    Text("Monthly").tag(AutomationPolicy.ReportsCadence.monthly)
                }
                .pickerStyle(.segmented)
                switch policy.reportsCadence {
                case .weekly:
                    weekdayPicker("Report day", binding(\.reportsWeekday))
                case .monthly:
                    Stepper("Day of month: \(policy.reportsDayOfMonth)",
                            value: binding(\.reportsDayOfMonth), in: 1...28)
                case .daily, .off:
                    EmptyView()
                }
                Text("Reports generate from the already-fresh cache for every profile.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    // MARK: - Backups

    private var backupsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Configuration Backups")
                Toggle("Weekly configuration backup", isOn: binding(\.backupsEnabled))
                    .toggleStyle(.switch)
                if policy.backupsEnabled {
                    weekdayPicker("Backup day", binding(\.backupsWeekday))
                }
            }
        }
    }

    // MARK: - Schedule time

    private var scheduleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Run Time")
                HStack {
                    Text("Run automation at")
                    TextField("06:00", text: binding(\.runTime))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Shared base time (24-hour HH:mm). Freshness, scan, reports, and backup are "
                    + "staggered a few minutes apart so on-prem Jamf Pro isn't hit all at once.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    // MARK: - Exclusions

    private var exclusionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Excluded Profiles")
                if discoveredProfiles.isEmpty {
                    Text("No profiles discovered.").font(.footnote)
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    ForEach(discoveredProfiles, id: \.self) { profile in
                        Toggle(profile, isOn: exclusionBinding(profile))
                            .toggleStyle(.checkbox)
                    }
                    Text("Excluded profiles are skipped by all managed automation (e.g. a "
                        + "dummy/test tenant).")
                        .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                }
            }
        }
    }

    // MARK: - Report group actions

    private func addGroup(name: String, profiles: [String]) {
        update {
            $0.reportGroups.append(ReportGroup(name: name, profiles: profiles))
        }
    }

    private func removeGroup(_ group: ReportGroup) {
        update { $0.reportGroups.removeAll { $0.id == group.id } }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private func weekdayPicker(_ label: String, _ value: Binding<Int>) -> some View {
        Picker(label, selection: value) {
            ForEach(0..<7, id: \.self) { index in
                Text(AutomationCardShared.weekdays[index]).tag(index)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220, alignment: .leading)
    }

    /// Two-way binding into the persisted policy for a single field.
    private func binding<T>(_ keyPath: WritableKeyPath<AutomationPolicy, T>) -> Binding<T> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func exclusionBinding(_ profile: String) -> Binding<Bool> {
        Binding(
            get: { policy.excludedProfiles.contains(profile) },
            set: { excluded in
                update { p in
                    if excluded {
                        if !p.excludedProfiles.contains(profile) { p.excludedProfiles.append(profile) }
                    } else {
                        p.excludedProfiles.removeAll { $0 == profile }
                    }
                }
            }
        )
    }

    private func update(_ mutate: (inout AutomationPolicy) -> Void) {
        var p = AutomationPolicy.parse(policyRaw)
        mutate(&p)
        policyRaw = p.serialize()
    }
}

// MARK: - Shared card constants

private enum AutomationCardShared {
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }
}

// MARK: - Automation health (dead-man switch, 2.6)

/// Overdue / failing scheduled runs — or a quiet "on time" row when managed
/// and everything is healthy. Absence of a run is signal, so the healthy
/// state is explicit rather than blank.
private struct HealthCard: View {
    let issues: [AutomationHealthIssue]

    @Environment(WorkspaceStore.self) private var workspace
    // Labels with a kickstart in flight — disables that row's button so a
    // double-click can't fire two overlapping "Run now" requests.
    @State private var runningLabels: Set<String> = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                AutomationCardShared.sectionTitle("Automation Health")
                if issues.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Theme.Colors.ok)
                            .accessibilityHidden(true)
                        Text("All scheduled runs on time.")
                            .font(.callout)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                } else {
                    ForEach(issues) { issue in
                        healthRow(issue)
                        Divider().background(Theme.Colors.hairline)
                    }
                }
            }
        }
    }

    private func healthRow(_ issue: AutomationHealthIssue) -> some View {
        // The buttons sit OUTSIDE the combined-accessibility group below so
        // VoiceOver still exposes each as its own tappable element — nesting a
        // Button inside `.accessibilityElement(children: .combine)` would
        // fold it into the row's summary label and lose its action.
        HStack(alignment: .top, spacing: 8) {
            healthSummary(issue)
            // Only a MANAGED row is eligible — a hand-built agent's own
            // "Run now" lives on the Schedules screen, not here.
            if issue.isManagedAgent {
                runNowButton(issue)
            }
            // A failing row now has somewhere to GO: the run log that explains
            // the failure. Overdue rows have no log to read (nothing ran).
            if issue.kind == .failing {
                runHistoryButton
            }
        }
    }

    /// Secondary action on a failing row — jumps to Run History via the app's
    /// `.navigateToTab` notification (same shape the other views post).
    private var runHistoryButton: some View {
        PNPButton(
            title: "Run History",
            icon: "list.bullet.rectangle",
            style: .ghost,
            size: .sm
        ) {
            NotificationCenter.default.post(
                name: .navigateToTab,
                object: nil,
                userInfo: ["tab": Tab.runs.rawValue]
            )
        }
        .help("Open Run History to read this schedule's run log.")
    }

    private func healthSummary(_ issue: AutomationHealthIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.kind == .overdue ? "clock.badge.xmark" : "xmark.octagon")
                .foregroundStyle(Theme.Colors.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.displayName).font(.callout.weight(.semibold))
                // The detail string is now multi-sentence (cause + remediation),
                // so let it wrap onto as many lines as it needs instead of being
                // squeezed by the trailing status label and buttons.
                Text(healthDetail(issue))
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(issue.kind == .overdue ? "Overdue" : "Failing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.warn)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(healthAccessibilityLabel(issue))
    }

    private func runNowButton(_ issue: AutomationHealthIssue) -> some View {
        let isRunning = runningLabels.contains(issue.label)
        return PNPButton(
            title: isRunning ? "Running…" : "Run now",
            icon: isRunning ? "hourglass" : "play.fill",
            size: .sm
        ) {
            Task { await runNow(issue) }
        }
        .disabled(isRunning)
        .help("Immediately re-run this schedule's own LaunchAgent job.")
    }

    private func runNow(_ issue: AutomationHealthIssue) async {
        guard !runningLabels.contains(issue.label) else { return }
        runningLabels.insert(issue.label)
        defer { runningLabels.remove(issue.label) }
        let started = await workspace.runNowFromHealthRow(label: issue.label)
        workspace.toast = Toast(
            message: started
                ? "Run started for \(issue.displayName) — health updates when it finishes."
                : "Couldn't start \(issue.displayName) — see Console for details.",
            style: started ? .success : .danger
        )
    }

    private func healthAccessibilityLabel(_ issue: AutomationHealthIssue) -> String {
        let status = issue.kind == .overdue ? "Overdue" : "Failing"
        return "\(issue.displayName), \(status). \(healthDetail(issue))"
    }

    private func healthDetail(_ issue: AutomationHealthIssue) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let last = issue.lastRunFinishedAt.map {
            "last run \(formatter.localizedString(for: $0, relativeTo: Date()))"
        } ?? "no run recorded"
        switch issue.kind {
        case .overdue:
            let when = issue.expectedFire.map {
                formatter.localizedString(for: $0, relativeTo: Date())
            } ?? "on schedule"
            return "Should have run \(when) — \(last)."
        case .failing:
            // Name the CAUSE when the run recorded an exit code (#213: the row
            // could previously only ever say "reported failure", leaving the
            // operator with nowhere to go). Falls back to the original wording
            // for status records written without a numeric code.
            let cause = issue.lastRunExitCode.map {
                "\(CLIBridge.explainExit($0, operation: "Last run")) (\(last))."
            } ?? "Last run reported failure — \(last)."
            return cause + managedRerunHint(issue)
        }
    }

    /// One sentence for a MANAGED failing row: a manual backup/report run from
    /// another screen writes no status artifact under this schedule's label, so
    /// it deliberately does not clear the failing state (that anti-masking
    /// behavior is correct). Users try it anyway — point them at "Run now".
    /// Omitted for hand-built agents, whose "Run now" lives on Schedules.
    private func managedRerunHint(_ issue: AutomationHealthIssue) -> String {
        guard issue.isManagedAgent else { return "" }
        return " Use Run now here — a manual run from another screen won't clear this."
    }
}

// MARK: - Report groups

/// Lists the configured report groups and hosts the add-group form. Group
/// mutation flows back to the parent's persisted policy via the callbacks.
private struct GroupsCard: View {
    let reportGroups: [ReportGroup]
    let discoveredProfiles: [String]
    let existingGroupNames: [String]
    let onRemove: (ReportGroup) -> Void
    let onAdd: (String, [String]) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                AutomationCardShared.sectionTitle("Report Groups")
                Text("Each group's profiles roll up into one consolidated fleet report; profiles "
                    + "in no group get a per-profile report. Combine prod/dev/sandbox into one "
                    + "fleet, or make one group per customer.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)

                ForEach(reportGroups) { group in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.callout.weight(.semibold))
                            Text(group.profiles.joined(separator: ", "))
                                .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                        Button(role: .destructive) { onRemove(group) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove group \(group.name)")
                        .help("Remove this report group.")
                    }
                    Divider().background(Theme.Colors.hairline)
                }

                AddGroupForm(
                    discoveredProfiles: discoveredProfiles,
                    existingGroupNames: existingGroupNames,
                    onAdd: onAdd
                )
            }
        }
    }
}

/// The "new group" entry form. Owns the in-progress name/selection @State so a
/// keystroke here invalidates only this subtree, not the whole screen.
private struct AddGroupForm: View {
    let discoveredProfiles: [String]
    let existingGroupNames: [String]
    let onAdd: (String, [String]) -> Void

    @State private var newGroupName: String = ""
    @State private var newGroupProfiles: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New group").font(.footnote.weight(.semibold))
            TextField("Group name (e.g. Production Fleet)", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
            if !discoveredProfiles.isEmpty {
                ForEach(discoveredProfiles, id: \.self) { profile in
                    Toggle(profile, isOn: newGroupProfileBinding(profile))
                        .toggleStyle(.checkbox)
                }
            }
            PNPButton(title: "Add group", style: .gold, size: .sm) { addGroup() }
                .disabled(!canAddGroup)
        }
    }

    private var canAddGroup: Bool {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && !newGroupProfiles.isEmpty
            && !existingGroupNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func addGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
        guard canAddGroup else { return }
        onAdd(trimmed, discoveredProfiles.filter(newGroupProfiles.contains))
        newGroupName = ""
        newGroupProfiles = []
    }

    private func newGroupProfileBinding(_ profile: String) -> Binding<Bool> {
        Binding(
            get: { newGroupProfiles.contains(profile) },
            set: { on in
                if on { newGroupProfiles.insert(profile) } else { newGroupProfiles.remove(profile) }
            }
        )
    }
}

// MARK: - Consolidation

/// Offers to retire hand-built schedules the managed policy now duplicates.
private struct ConsolidationCard: View {
    let candidates: [ScheduleConsolidation.Candidate]
    @Binding var selectedForRemoval: Set<String>
    @Binding var showRemovalConfirm: Bool
    let onConfirmRemoval: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                AutomationCardShared.sectionTitle("Consolidate Schedules")
                Text("These hand-built schedules do work managed automation now covers for "
                    + "every profile — retiring them stops duplicate collection. Each is "
                    + "archived to _archived-launchagents before removal, so it is recoverable.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)

                ForEach(candidates) { candidate in
                    Toggle(isOn: removalBinding(candidate.label)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.displayName).font(.callout.weight(.semibold))
                            Text("\(candidate.mode.displayTitle) · now covered by \(candidate.coveredBy)")
                                .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Divider().background(Theme.Colors.hairline)
                }

                PNPButton(
                    title: "Retire \(selectedForRemoval.count) selected",
                    style: .danger, size: .sm
                ) { showRemovalConfirm = true }
                .disabled(selectedForRemoval.isEmpty)
            }
        }
        .confirmationDialog(
            "Retire \(selectedForRemoval.count) hand-built schedule"
                + (selectedForRemoval.count == 1 ? "" : "s") + "?",
            isPresented: $showRemovalConfirm, titleVisibility: .visible
        ) {
            Button("Retire & archive", role: .destructive) {
                onConfirmRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each schedule is archived to _archived-launchagents and can be restored by "
                + "copying its plist back to ~/Library/LaunchAgents. Managed agents are never "
                + "affected.")
        }
    }

    private func removalBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { selectedForRemoval.contains(label) },
            set: { isOn in
                if isOn { selectedForRemoval.insert(label) } else { selectedForRemoval.remove(label) }
            }
        )
    }
}
