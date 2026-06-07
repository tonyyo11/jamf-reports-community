import SwiftUI

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
        let actions = await workspace.reconcileManagedAutomation()
        guard !actions.isEmpty else { return }
        let installs = actions.filter { if case .install = $0 { return true }; return false }.count
        let removes = actions.count - installs
        var parts: [String] = []
        if installs > 0 { parts.append("\(installs) installed") }
        if removes > 0 { parts.append("\(removes) removed") }
        workspace.toast = Toast(
            message: "Automation applied — \(parts.joined(separator: ", "))", style: .success
        )
    }
}

/// v2.2.0 Phase 5 — the "set policy, not cron jobs" Automation screen (DRAFT,
/// owes visual sign-off at `PageScaffold.minSupportedWidth`).
///
/// Edits the single app-level `AutomationPolicy` (@AppStorage). When "Manage
/// automation" is on, `ManagedAutomation.reconcile` (run at launch) installs the
/// daily-freshness / weekly-scan / reports / backup all-profiles agents from
/// this policy; turning it off tears them down. Report groups drive the
/// consolidated fleet report.
struct AutomationView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @AppStorage(AutomationPolicy.storageKey) private var policyRaw: String = ""

    // Add-group form state.
    @State private var newGroupName: String = ""
    @State private var newGroupProfiles: Set<String> = []

    // Consolidation (retire hand-built agents the managed policy now duplicates).
    @State private var consolidationCandidates: [ScheduleConsolidation.Candidate] = []
    @State private var selectedForRemoval: Set<String> = []
    @State private var showRemovalConfirm = false

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var policy: AutomationPolicy { AutomationPolicy.parse(policyRaw) }

    private var discoveredProfiles: [String] {
        workspace.demoMode ? [] : ProfileService.discoverLocal().map(\.name)
    }

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
                masterCard
                if policy.isManaged {
                    freshnessCard
                    reportsCard
                    backupsCard
                    scheduleCard
                    exclusionsCard
                    groupsCard
                    if !consolidationCandidates.isEmpty {
                        consolidationCard
                    }
                }
            }
        }
        // Apply policy edits without a relaunch: `.task(id:)` re-runs (cancelling
        // the prior) on every change, so rapid edits debounce and only the
        // settled state reconciles the managed agents.
        .task(id: policyRaw) { await applyPolicyChange() }
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

    // MARK: - Report groups

    private var groupsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Report Groups")
                Text("Each group's profiles roll up into one consolidated fleet report; profiles "
                    + "in no group get a per-profile report. Combine prod/dev/sandbox into one "
                    + "fleet, or make one group per customer.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)

                ForEach(policy.reportGroups) { group in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.callout.weight(.semibold))
                            Text(group.profiles.joined(separator: ", "))
                                .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                        Button(role: .destructive) { removeGroup(group) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    Divider().background(Theme.Colors.hairline)
                }

                addGroupForm
            }
        }
    }

    // MARK: - Consolidation (DRAFT — needs visual sign-off at minSupportedWidth)

    private var consolidationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Consolidate Schedules")
                Text("These hand-built schedules do work managed automation now covers for "
                    + "every profile — retiring them stops duplicate collection. Each is "
                    + "archived to _archived-launchagents before removal, so it is recoverable.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)

                ForEach(consolidationCandidates) { candidate in
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
                Task { await removeSelectedAgents() }
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

    private var addGroupForm: some View {
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
            && !policy.reportGroups.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func addGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
        guard canAddGroup else { return }
        update {
            $0.reportGroups.append(
                ReportGroup(name: trimmed, profiles: discoveredProfiles.filter(newGroupProfiles.contains))
            )
        }
        newGroupName = ""
        newGroupProfiles = []
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
                Text(Self.weekdays[index]).tag(index)
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

    private func newGroupProfileBinding(_ profile: String) -> Binding<Bool> {
        Binding(
            get: { newGroupProfiles.contains(profile) },
            set: { on in
                if on { newGroupProfiles.insert(profile) } else { newGroupProfiles.remove(profile) }
            }
        )
    }

    private func update(_ mutate: (inout AutomationPolicy) -> Void) {
        var p = AutomationPolicy.parse(policyRaw)
        mutate(&p)
        policyRaw = p.serialize()
    }
}
