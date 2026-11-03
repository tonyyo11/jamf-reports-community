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
    @State private var checks: [String: String] = [:]
    @State private var checking: Set<String> = []
    @State private var actionError: String?

    private var demo: Bool { workspace.demoMode }

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(state.rows) { row in rowView(row) }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(Theme.Colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(
            L("Remove from this environment?"), isPresented: removalBinding,
            presenting: pendingRemoval
        ) { row in
            Button(L("Remove"), role: .destructive) { remove(row) }
        } message: { row in
            Text(L("The jamf-cli profile \(row.profile ?? "") and its snapshots stay."))
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
            HStack(spacing: 8) {
                pills(row)
                Spacer(minLength: 0)
                actions(row)
            }
            if let verdict = checks[row.id] {
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
        if row.profile != nil {
            PNPButton(title: L("Check"), icon: "stethoscope", style: .ghost, size: .sm) {
                check(row)
            }
            .disabled(demo || checking.contains(row.id)).help(help)
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

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func add(_ row: EnvironmentCardState.Row) {
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
        checking.insert(row.id)
        let service = CLIDoctorService(executor: DefaultCLIExecutor(bridge: CLIBridge()))
        Task {
            let outcome = await service.run(profile: profile)
            checking.remove(row.id)
            switch outcome {
            case .notInstalled: checks[row.id] = L("jamf-cli is not installed.")
            case .failed(let reason): checks[row.id] = reason
            case .report(let report):
                checks[row.id] = SourcesView.healthPill(report.health).label + " · "
                    + SourcesView.connectivitySummary(report.connectivity)
            }
        }
    }

    private func remove(_ row: EnvironmentCardState.Row) {
        let profile = state.workspace
        Task {
            do {
                try await Task.detached {
                    try ProfilesConfigWriter.save(row.slot, to: nil, workspace: profile)
                }.value
                actionError = nil
                onChanged()
            } catch {
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
        authMethod: slot == .platform ? "platform" : "oauth2", level: level,
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

#Preview("Environment card") {
    EnvironmentCard(state: previewState, onAddProtect: {}, onChanged: {})
        .environment(WorkspaceStore(demoMode: false))
        .padding(16)
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
        .preferredColorScheme(.dark)
}
#endif
