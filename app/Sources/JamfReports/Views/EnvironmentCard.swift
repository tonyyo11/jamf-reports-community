import SwiftUI

/// Data Sources' Environment card (spec 6, D23): one row per product slot, with Check and
/// Remove. Add and Change go through the Add sheet until P5 and P6.
struct EnvironmentCard: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    let state: EnvironmentCardState
    let onAddProtect: () -> Void
    let onChanged: () -> Void
    @State private var pendingRemoval: EnvironmentCardState.Row?
    /// Check verdicts by jamf-cli profile name: two slots can name one profile.
    @State private var checks: [String: String] = [:]
    @State private var checking: Set<String> = []
    @State private var actionError: String?
    @State private var backupNote: String?
    @State private var pendingMerge: WorkspaceMergeJournal?
    @State private var mergeSession: MergeSession?

    private struct MergeSession: Identifiable {
        let id = UUID()
        let model: WorkspaceMergeModel
        let resumes: Bool
    }

    private var demo: Bool { workspace.demoMode }

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(state.rows) { row in rowView(row) }
                mergeSection
                if let backupNote {
                    Text(backupNote).font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(Theme.Colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: state.workspace) { await reloadPendingMerge() }
        .sheet(item: $mergeSession, onDismiss: { Task { await reloadPendingMerge() } }) { session in
            WorkspaceMergeSheet(
                model: session.model, candidates: mergeCandidates, resumes: session.resumes,
                onFinished: mergeFinished, onFailed: { Task { await reloadPendingMerge() } })
        }
        .confirmationDialog(
            pendingRemoval.map { $0.slot == .protect
                ? L("Remove Jamf Protect from this environment?")
                : L("Remove Platform API from this environment?") }
                ?? L("Remove from this environment?"),
            isPresented: removalBinding,
            presenting: pendingRemoval
        ) { row in
            Button(L("Remove"), role: .destructive) { remove(row) }
        } message: { row in
            Text(L("The jamf-cli profile \(ConfigSchema.displayText(row.profile ?? "")) and its snapshots stay."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Theme.Colors.goldBright).font(.system(size: 16))
                SectionHeader(title: L("Environment"))
                Spacer()
                Text(ConfigSchema.displayText(state.workspace))
                    .font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
            }
            if !state.fromBlock {
                Text(L("From this workspace's settings. The first change writes a profiles block to config.yaml."))
                    .font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rowView(_ row: EnvironmentCardState.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.product).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text(row.profile.map(ConfigSchema.displayText) ?? L("Not set"))
                    .font(.subheadline).foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            WrappingRow { pills(row) }
            WrappingRow { actions(row) }
            if let verdict = row.profile.flatMap({ checks[$0] }) {
                Text(verdict).font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func pills(_ row: EnvironmentCardState.Row) -> some View {
        if let auth = row.authMethod {
            Pill(text: ConfigSchema.displayText(auth), tone: .muted)
        }
        if let level = row.level {
            if level == .organization {
                Pill(text: L("Cannot serve Platform reports"), tone: .warn,
                     icon: "exclamationmark.triangle")
                    .help(EnvironmentProfiles.organizationLevelPlatformReason)
            } else {
                Pill(text: level.displayName, tone: .teal)
            }
        }
        if let date = row.newestSnapshot {
            Text(L("Newest snapshot \(Self.relative.localizedString(for: date, relativeTo: Date()))"))
                .font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
        }
        if row.pinNeedsConfirming {
            Pill(text: L("Confirm in Config Doctor"), tone: .warn)
        }
    }

    @ViewBuilder
    private func actions(_ row: EnvironmentCardState.Row) -> some View {
        let help = demo ? DemoData.liveOnlyHelp : ""
        if let profile = row.profile {
            PNPButton(title: L("Check"), icon: "stethoscope", style: .ghost, size: .sm) {
                check(row)
            }
            .disabled(demo || checking.contains(profile) || row.level == .organization)
            .help(row.level == .organization && !demo
                  ? EnvironmentProfiles.organizationLevelPlatformReason : help)
        }
        if row.slot == .platform || row.slot == .protect {
            PNPButton(title: row.profile == nil ? L("Add") : L("Change"),
                      icon: row.profile == nil ? "plus" : "arrow.triangle.2.circlepath",
                      style: .ghost, size: .sm) { add(row) }
                .disabled(demo).help(help)
        }
        if row.canRemove {
            PNPButton(title: L("Remove"), icon: "xmark.circle", style: .ghost, size: .sm) {
                pendingRemoval = row
            }
            .disabled(demo).help(help)
        }
    }

    private var mergeCandidates: [String] {
        guard !demo else { return [] }
        return WorkspaceMergeCandidates.list(
            target: state.workspace,
            targetPlatformSlot: state.rows.first { $0.slot == .platform }?.profile,
            profiles: workspace.profiles,
            hasWorkspace: { ProfileService.hasWorkspace($0) })
    }

    @ViewBuilder
    private var mergeSection: some View {
        if pendingMerge != nil {
            MergeResumeBanner { startMerge(resumes: true) }
        }
        if !mergeCandidates.isEmpty {
            WrappingRow {
                PNPButton(title: L("Merge another workspace into this one"),
                          icon: "arrow.triangle.merge", style: .ghost, size: .sm) {
                    startMerge(resumes: false)
                }
            }
        }
    }

    private func reloadPendingMerge() async {
        let target = state.workspace
        let journal = demo ? nil : await Task.detached {
            WorkspaceMergeJournal.pending(target: target)
        }.value
        guard target == state.workspace else { return }
        pendingMerge = journal
    }

    private func startMerge(resumes: Bool) {
        let store = workspace
        let deps = WorkspaceMergeModel.Dependencies.live { from, to in
            await MainActor.run {
                let policy = AutomationPolicy.current().replacingWorkspace(from, with: to)
                UserDefaults.standard.set(policy.serialize(), forKey: AutomationPolicy.storageKey)
            }
            await store.applyAutomationPolicy()
        }
        mergeSession = MergeSession(
            model: WorkspaceMergeModel(target: state.workspace, deps: deps),
            resumes: resumes)
    }

    /// Discovery, the sidebar and the active profile (P5's owner switch) read the new layout.
    private func mergeFinished(_ folder: String) {
        pendingMerge = nil
        workspace.toast = Toast(
            message: L("Merge finished. The source folder is in \(ConfigSchema.fullDisplayText(folder).text)."),
            style: .success)
        workspace.credentialsChanged()
        onChanged()
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func add(_ row: EnvironmentCardState.Row) {
        actionError = nil
        if row.slot == .protect {
            onAddProtect()
        } else {
            NotificationCenter.default.post(
                name: .showAddSheet, object: nil,
                userInfo: ["product": AddSheetPlan.NewProduct.platformAPI.rawValue])
        }
    }

    private func check(_ row: EnvironmentCardState.Row) {
        guard let profile = row.profile else { return }
        actionError = nil
        checking.insert(profile)
        let started = state.workspace
        let service = CLIDoctorService(executor: DefaultCLIExecutor(bridge: CLIBridge()))
        Task {
            let outcome = await service.run(profile: profile)
            // A switch to another workspace rebuilt this view's state; its result is not ours.
            guard started == state.workspace else { return }
            checking.remove(profile)
            switch outcome {
            case .notInstalled: checks[profile] = L("jamf-cli is not installed.")
            case .failed(let reason): checks[profile] = ConfigSchema.displayText(reason)
            case .report(let report):
                checks[profile] = SourcesView.healthPill(report.health).label + " · "
                    + SourcesView.connectivitySummary(report.connectivity)
            }
        }
    }

    private func remove(_ row: EnvironmentCardState.Row) {
        let started = state.workspace
        actionError = nil
        backupNote = nil
        Task {
            do {
                // Protect goes through its own disconnect, which writes the old keys on a file
                // without a block and the slot under one.
                let report = try await Task.detached {
                    row.slot == .protect
                        ? try ProtectConnection.disconnect(workspace: started)
                        : try ProfilesConfigWriter.save(row.slot, to: nil, workspace: started)
                }.value
                guard started == state.workspace else { return }
                if let profile = row.profile { checks[profile] = nil }
                backupNote = report.backupName.map {
                    L("A copy of config.yaml is in \($0).")
                }
                onChanged()
            } catch {
                guard started == state.workspace else { return }
                actionError = error.localizedDescription
            }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()
}

/// Shown on the Environment card while a merge's journal is pending.
struct MergeResumeBanner: View {
    var onResume: () -> Void

    var body: some View {
        InlineBanner(
            icon: "exclamationmark.triangle.fill", tone: .warn,
            action: .init(label: L("Resume"), icon: "play.fill", handler: onResume)
        ) { Text(L("A merge into this workspace did not finish.")) }
    }
}

extension EnvironmentCardState {
    /// Demo mode reads no workspace: one Jamf Pro and one Protect row.
    static func demo(workspace: String) -> EnvironmentCardState {
        EnvironmentCardState(workspace: workspace, fromBlock: true, rows: [
            Row(slot: .jamfPro, product: L("Jamf Pro"), profile: workspace,
                authMethod: "oauth2", level: nil, newestSnapshot: DemoData.referenceDate,
                pinNeedsConfirming: false),
            Row(slot: .protect, product: L("Jamf Protect"), profile: "\(workspace)-protect",
                authMethod: "oauth2", level: nil, newestSnapshot: DemoData.referenceDate,
                pinNeedsConfirming: false),
        ])
    }
}

#if DEBUG
private func previewRow(
    _ slot: ProfilesConfigWriter.Slot, _ product: String, _ profile: String?,
    level: PlatformScopeLevel? = nil, pin: Bool = false
) -> EnvironmentCardState.Row {
    EnvironmentCardState.Row(
        slot: slot, product: product, profile: profile,
        authMethod: profile == nil ? nil : slot == .platform ? "platform" : "oauth2", level: level,
        newestSnapshot: profile == nil ? nil : Date().addingTimeInterval(-7200),
        pinNeedsConfirming: pin)
}

private let previewState = EnvironmentCardState(
    workspace: "acme", fromBlock: false,
    rows: [
        previewRow(.jamfPro, "Jamf Pro", "acme"),
        previewRow(.platform, "Platform API", "acme-platform", level: .organization, pin: true),
        previewRow(.protect, "Jamf Protect", nil),
    ])

#Preview("Merge resume banner") {
    Card(padding: 18) { MergeResumeBanner {} }
        .padding(16)
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
        .preferredColorScheme(.dark)
}

#Preview("Environment card") {
    EnvironmentCard(state: previewState, onAddProtect: {}, onChanged: {})
        .environment(WorkspaceStore(demoMode: false))
        .padding(16)
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
        .preferredColorScheme(.dark)
}
#endif
