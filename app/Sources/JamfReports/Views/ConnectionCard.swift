import SwiftUI

/// Data Sources card for a Jamf Platform API Connection: the profiles that share one Jamf
/// Account integration's client ID and secret. Shown when the active profile is a member of one,
/// or uses the Platform API and is in none (then it offers to start one). The app records the
/// grouping per Mac (`ConnectionStore`) and never keeps the secret.
struct ConnectionCard: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sheet: Sheet?
    @State private var pendingRemoval: Connection.Member?
    @State private var actionError: String?

    enum Sheet: String, Identifiable {
        case add, updateAll, rename
        var id: String { rawValue }
    }

    private var activeProfile: JamfCLIProfile? {
        workspace.profiles.first { $0.name == workspace.profile }
    }

    private var state: ConnectionCardState {
        ConnectionCardState.resolve(
            profile: workspace.profile, authMethod: activeProfile?.authMethod ?? "",
            connections: workspace.activeConnections)
    }

    private var liveOnlyHelp: String { workspace.demoMode ? DemoData.liveOnlyHelp : "" }

    var body: some View {
        Group {
            switch state {
            case .member(let connection): memberCard(connection)
            case .canStart: startCard
            case .hidden: EmptyView()
            }
        }
        .sheet(item: $sheet) { sheet in
            if case .member(let connection) = state { sheetContent(sheet, connection) }
        }
    }

    // MARK: - Member card

    private func memberCard(_ connection: Connection) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header(connection)
                Text("These profiles share one Jamf Account integration's client ID and secret. "
                    + "Removing a profile here changes only this grouping.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(connection.members, id: \.profile) { memberRow($0, in: connection) }
                }
                actions
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(Theme.Colors.danger)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Remove \"\(pendingRemoval?.label ?? "")\" from \(connection.name)?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove from connection", role: .destructive) { removePending() }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The jamf-cli profile and its workspace are not deleted. The profile moves out "
                + "of this connection's group.")
        }
    }

    private func header(_ connection: Connection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Theme.Colors.goldBright)
                .font(.system(size: 16))
            SectionHeader(title: "Connection · \(connection.name)")
            Spacer()
            Pill(text: GatewayRegion(rawValue: connection.region.rawValue)?.label ?? "Other region")
            Pill(text: connection.level == .tenant ? "Tenant (legacy)" : "Environment", tone: .gold)
        }
    }

    private func memberRow(_ member: Connection.Member, in connection: Connection) -> some View {
        let hasWorkspace = workspace.initializedProfiles.contains { $0.name == member.profile }
        return HStack(spacing: 8) {
            Text(member.label).font(.callout.weight(.medium)).foregroundStyle(Theme.Colors.fg)
            Mono(text: member.profile, size: 11, color: Theme.Colors.fg2)
            if member.profile == workspace.profile { Pill(text: "Active", tone: .gold) }
            Spacer()
            Pill(text: productLabel(member.product),
                 tone: member.product == .unknown ? .muted : .teal)
            Pill(text: hasWorkspace ? "Workspace" : "No workspace",
                 tone: hasWorkspace ? .teal : .muted)
            PNPButton(title: "Remove", style: .ghost, size: .sm) {
                guard !workspace.demoMode else { return }
                pendingRemoval = member
            }
            .disabled(workspace.demoMode)
            .help(workspace.demoMode
                ? DemoData.liveOnlyHelp
                : "Remove from this connection. The profile and workspace stay.")
        }
    }

    private func productLabel(_ product: Connection.Member.Product) -> String {
        switch product {
        case .pro: "Jamf Pro"
        case .school: "Jamf School"
        case .unknown: "Product unknown"
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionButton("Add environments\u{2026}", icon: "plus", help: "") { sheet = .add }
            actionButton(
                "Update credentials for all\u{2026}", icon: "key.horizontal",
                help: "Re-register every profile in this connection with a new client secret."
            ) { sheet = .updateAll }
            actionButton("Rename\u{2026}", icon: "pencil", help: "") { sheet = .rename }
        }
    }

    private func actionButton(
        _ title: String, icon: String, help: String, action: @escaping () -> Void
    ) -> some View {
        PNPButton(title: title, icon: icon, size: .sm) {
            guard !workspace.demoMode else { return }
            action()
        }
        .disabled(workspace.demoMode)
        .help(workspace.demoMode ? DemoData.liveOnlyHelp : help)
    }

    // MARK: - Start card

    private var startCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Theme.Colors.goldBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "Connection")
                }
                Text("This profile uses the Jamf Platform API but is not part of a connection. "
                    + "Start one to add the other environments of the same Jamf Account "
                    + "integration, each with its own jamf-cli profile.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                PNPButton(title: "Start a connection with \(workspace.profile)", icon: "plus",
                          size: .sm, action: startConnection)
                    .disabled(workspace.demoMode)
                    .help(liveOnlyHelp)
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(Theme.Colors.danger)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet, _ connection: Connection) -> some View {
        switch sheet {
        case .add: credentialsSheet(.addEnvironments, connection)
        case .updateAll: credentialsSheet(.updateAll, connection)
        case .rename:
            ConnectionRenameSheet(
                connection: connection, store: workspace.connectionStore,
                onSaved: { workspace.reloadConnections() })
        }
    }

    private func credentialsSheet(
        _ mode: ConnectionCredentialsModel.Mode, _ connection: Connection
    ) -> some View {
        ConnectionCredentialsSheet(
            model: ConnectionCredentialsModel(
                connection: connection, mode: mode,
                dependencies: ConnectionCredentialsModel.liveDependencies(
                    profiles: { [workspace] in workspace.profiles },
                    store: workspace.connectionStore)),
            onFinished: { changed in
                if changed { workspace.credentialsChanged() }
                workspace.reloadConnections()
            },
            onSetUpSchool: {
                OnboardingFlow.pendingProductPath = .school
                NotificationCenter.default.post(
                    name: .navigateToTab, object: nil,
                    userInfo: ["tab": Tab.onboarding.rawValue])
            })
    }

    // MARK: - Actions

    private func removePending() {
        guard let member = pendingRemoval, !workspace.demoMode else { return }
        pendingRemoval = nil
        do {
            try workspace.connectionStore.removeMember(profile: member.profile)
            actionError = nil
        } catch {
            actionError = "Could not update the connection: \(error.localizedDescription)"
        }
        workspace.reloadConnections()
    }

    private func startConnection() {
        guard !workspace.demoMode else { return }
        let text = try? String(contentsOf: ConnectionStarter.jamfCLIConfigURL, encoding: .utf8)
        do {
            try ConnectionStarter.start(
                profile: workspace.profile, storedURL: activeProfile?.url ?? "",
                configText: text, store: workspace.connectionStore)
            actionError = nil
        } catch {
            actionError = "Could not start the connection: \(error.localizedDescription)"
        }
        workspace.reloadConnections()
    }
}
