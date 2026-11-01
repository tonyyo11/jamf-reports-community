import SwiftUI

/// Opens the Add sheet from anywhere in the shell; `ContentView` presents it. `userInfo["product"]`
/// may name an `AddSheetPlan.NewProduct` raw value to open on.
extension Notification.Name {
    static let showAddSheet = Notification.Name("JamfReports.showAddSheet")
}

struct AddSheetRequest: Identifiable {
    let id = UUID()
    var product: AddSheetPlan.NewProduct?
}

extension AddSheetPlan.NewProduct {
    var title: String {
        switch self {
        case .jamfPro: L("Jamf Pro")
        case .platformAPI: L("Platform API")
        case .jamfSchool: L("Jamf School")
        }
    }

    var icon: String {
        switch self {
        case .jamfPro: "server.rack"
        case .platformAPI: "person.badge.key.fill"
        case .jamfSchool: "graduationcap.fill"
        }
    }

    var summary: String {
        switch self {
        case .jamfPro: L("A Jamf Pro server with an API client (OAuth2): on-prem, GovCloud or cloud.")
        case .platformAPI: L("A Jamf Account integration, recommended for Jamf Cloud.")
        case .jamfSchool: L("A Jamf School network, with its Network ID and API key.")
        }
    }

    /// The onboarding path and connection type this product runs.
    @MainActor var onboarding: (OnboardingFlow.ProductPath, OnboardingFlow.ProConnectionType?) {
        switch self {
        case .jamfPro: (.pro, .oauth2)
        case .platformAPI: (.pro, .platformGateway)
        case .jamfSchool: (.school, nil)
        }
    }
}

/// One Add flow (environment spec 5.1, first slice): Settings › Add connection, the workspace
/// menu's Add item and Data Sources' Jamf School suggestion all open it. New workspace runs the
/// product's onboarding path; Add to current connects Jamf Protect to the active Jamf Pro
/// workspace; the profiles jamf-cli already has that no workspace uses are listed for either.
struct AddSheet: View {
    var requested: AddSheetPlan.NewProduct?
    /// Starts the onboarding path for a new workspace; the sheet has closed by then.
    var onStartOnboarding: (AddSheetPlan.NewProduct) -> Void

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var choice: AddSheetPlan.Choice = .newWorkspace
    @State private var choiceTouched = false
    @State private var discovery: AddSheetDiscovery?
    @State private var isChecking = false
    @State private var adoptFlow: ExistingCLISetupFlow?
    @State private var adoptingName: String?
    @State private var message: String?
    @State private var errorText: String?
    @State private var showingProtectConnect = false
    @State private var twinProbe: Task<AddSheetDiscovery, Never>?

    private var currentTakesProtect: Bool {
        AddSheetPlan.currentTakesProtect(
            demoMode: workspace.demoMode, current: workspace.profile,
            initialized: workspace.initializedProfiles.map(\.name))
    }

    private var isAdopting: Bool { adoptFlow?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Colors.hairlineStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if currentTakesProtect { choiceRow }
                    productsSection
                    existingProfilesSection
                }
                .padding(20)
            }
            Divider().background(Theme.Colors.hairlineStrong)
            footer
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 560, idealHeight: 640)
        .background(Theme.Colors.winBG)
        .interactiveDismissDisabled(isAdopting)
        .background {
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .task { await recheck() }
        .onDisappear { twinProbe?.cancel() }
        // A banner appears mid-list with no focus change, so VoiceOver would not say it.
        .onChange(of: message) { _, text in announce(text) }
        .onChange(of: errorText) { _, text in announce(text) }
        .sheet(isPresented: $showingProtectConnect, onDismiss: { Task { await recheck() } }) {
            ProductConnectSheetView(profileSlug: workspace.profile)
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text("Set up a new workspace, add Jamf Protect to this one, or use a profile jamf-cli already has.")
                .font(.callout)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))
    }

    private var footer: some View {
        HStack {
            Spacer()
            PNPButton(title: L("Close"), style: .neutral, size: .md, action: close)
                .disabled(isAdopting)
        }
        .padding(16)
    }

    private func announce(_ text: String?) {
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    private func close() {
        guard !isAdopting else { return }
        dismiss()
    }

    // MARK: - Step 1: what are you adding

    private var choiceRow: some View {
        HStack(alignment: .top, spacing: 12) {
            choiceCard(
                .newWorkspace, icon: "folder.badge.plus", title: L("New workspace"),
                body: L("Jamf Pro, the Platform API or Jamf School, in a workspace of its own."))
            choiceCard(
                .addToCurrent, icon: "plus.rectangle.on.rectangle",
                title: L("Add to \(workspace.profile)"),
                body: (workspace.isSchoolWorkspace ? L("Jamf Protect alerts and analytics beside this workspace's Jamf School data.") : L("Jamf Protect alerts and analytics beside this workspace's Jamf Pro data.")))
        }
    }

    private func choiceCard(
        _ value: AddSheetPlan.Choice, icon: String, title: String, body: String
    ) -> some View {
        let selected = choice == value
        return Button {
            choice = value
            choiceTouched = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                productIcon(icon, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Theme.Colors.gold : Theme.Colors.hairlineStrong,
                                  lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func productIcon(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.Colors.goldBright)
            .frame(width: size, height: size)
            .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    // MARK: - Products

    @ViewBuilder
    private var productsSection: some View {
        if AddSheetPlan.step(choice: choice, takesProtect: currentTakesProtect) == .addToCurrent {
            protectCard
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                ForEach(AddSheetPlan.NewProduct.allCases) { productCard($0) }
            }
        }
    }

    private func productCard(_ product: AddSheetPlan.NewProduct) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            productIcon(product.icon, size: 36)
            Text(product.title).font(.headline).foregroundStyle(Theme.Colors.fg)
            Text(product.summary)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PNPButton(title: L("Connect new"), icon: "arrow.right", size: .sm) {
                startOnboarding(product)
            }
            .disabled(isAdopting)
            .accessibilityLabel("Connect new \(product.title) workspace")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Colors.hairlineStrong))
    }

    private func startOnboarding(_ product: AddSheetPlan.NewProduct) {
        guard !isAdopting else { return }
        dismiss()
        onStartOnboarding(product)
    }

    private var protectCard: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                productIcon("shield.lefthalf.filled", size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jamf Protect").font(.headline).foregroundStyle(Theme.Colors.fg)
                    if let connected = discovery?.currentProtect {
                        Text("\(workspace.profile) already uses the Jamf Protect profile \(connected). Change it from Data Sources.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Connect a Jamf Protect tenant with an API client. Its alerts, computers and insights are collected with this workspace.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                        PNPButton(title: L("Connect new"), icon: "arrow.right", size: .sm) {
                            showingProtectConnect = true
                        }
                        .disabled(isAdopting || discovery == nil)
                        .accessibilityLabel("Connect new Jamf Protect profile to \(workspace.profile)")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Step 2: profiles jamf-cli already has

    private var listing: AddSheetPlan.Listing {
        AddSheetPlan.listing(
            demoMode: workspace.demoMode, isChecking: isChecking, choice: choice,
            takesProtect: currentTakesProtect, discovery: discovery)
    }

    private var existingProfilesSection: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Profiles jamf-cli already has")
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    PNPButton(title: L("Re-check"), icon: "arrow.clockwise", size: .sm) {
                        Task { await recheck() }
                    }
                    .disabled(isChecking || isAdopting || workspace.demoMode)
                }
                if let message { banner(message, tone: .info, icon: "checkmark.circle.fill") }
                if let errorText {
                    banner(errorText, tone: .warn, icon: "exclamationmark.triangle.fill")
                }
                existingProfilesBody
            }
        }
    }

    @ViewBuilder
    private var existingProfilesBody: some View {
        switch listing {
        case .demo:
            note(L("Demo mode is on. Profiles jamf-cli already has are listed once a real connection is set up."))
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                note(L("Reading jamf-cli's profiles…"))
            }
        case .unreadable:
            note(L("Could not read jamf-cli's profiles. Check that jamf-cli is installed, then Re-check."))
        case .empty(let text):
            note(text)
        case .rows(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    profileRow(row)
                    if row.id != rows.last?.id {
                        Divider().background(Theme.Hairline.standard)
                    }
                }
            }
        }
    }

    private func profileRow(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            productIcon(icon(for: row.product), size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Mono(text: row.name, size: 12, color: Theme.Colors.fg)
                    Pill(text: row.product.displayName, tone: .muted)
                }
                if !row.url.isEmpty {
                    Text(row.url)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                rowDetail(row)
            }
            Spacer(minLength: 8)
            rowAction(row)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowDetail(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        if case .unavailable(let reason) = row.use {
            note(reason)
        } else {
            if let twin = discovery?.twinNotes[row.name] { note(twin) }
            if row.name == adoptingName, let flow = adoptFlow {
                if let checkNote = flow.connectionNotes[row.name] { note(checkNote) }
                adoptStatus(flow.statuses[row.name] ?? .pending, flow: flow)
            }
        }
    }

    @ViewBuilder
    private func adoptStatus(
        _ status: ExistingCLISetupFlow.ProfileStatus, flow: ExistingCLISetupFlow
    ) -> some View {
        switch status {
        case .pending: EmptyView()
        case .initializing: note(L("Creating the workspace…"))
        case .collecting: note(L("Collecting · \(flow.progress.summary)"))
        case .done:
            note([L("Workspace set up"), flow.kindSummaries[adoptingName ?? ""]?.summary]
                .compactMap { $0 }.joined(separator: " · "))
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(Theme.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func rowAction(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        switch row.use {
        case .newWorkspace:
            if row.name == adoptingName && isAdopting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Setting up \(row.name)")
            } else {
                PNPButton(title: L("Set up workspace"), icon: "folder.badge.plus", size: .sm) {
                    Task { await adopt(row) }
                }
                .disabled(isAdopting || isChecking)
                .accessibilityLabel("Set up workspace for \(row.name)")
            }
        case .addToCurrent:
            PNPButton(title: L("Add to \(workspace.profile)"), icon: "plus", size: .sm) {
                addProtect(row)
            }
            .disabled(isAdopting || isChecking)
            .accessibilityLabel("Add \(row.name) to \(workspace.profile)")
        case .unavailable:
            EmptyView()
        }
    }

    private func icon(for product: JamfCLIProduct) -> String {
        switch product {
        case .pro, .unknown: "server.rack"
        case .school: "graduationcap.fill"
        case .protect: "shield.lefthalf.filled"
        case .securityCloud: "cloud.fill"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func banner(_ text: String, tone: InlineBannerTone, icon: String) -> some View {
        InlineBanner(icon: icon, tone: tone) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// Reads jamf-cli's profiles again (off the main actor), then sets the opening choice once.
    private func recheck() async {
        guard !workspace.demoMode, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let current = currentTakesProtect ? workspace.profile : nil
        let found = await Task.detached { AddSheetDiscovery.load(currentWorkspace: current) }.value
        discovery = found
        choice = AddSheetPlan.recheck(
            found: found, takesProtect: currentTakesProtect, choice: choice,
            choiceTouched: choiceTouched, requested: requested)
        twinProbe?.cancel()
        let probe = Task.detached {
            AddSheetDiscovery.load(currentWorkspace: current, probeTwins: true)
        }
        twinProbe = probe
        let probed = await withTaskCancellationHandler { await probe.value } onCancel: {
            probe.cancel()
        }
        guard !probe.isCancelled else { return }
        discovery?.twinNotes = probed.twinNotes
    }

    /// Sets up a workspace for a profile jamf-cli already has: the setup the first launch runs
    /// for existing profiles (workspace, School routing, first collect), for this one profile.
    private func adopt(_ row: AddSheetPlan.UnassignedProfile) async {
        guard !isAdopting else { return }
        message = nil
        errorText = nil
        let flow = ExistingCLISetupFlow(profiles: [AddSheetPlan.adoptionProfile(for: row)])
        adoptFlow = flow
        adoptingName = row.name
        await flow.run()
        guard flow.canContinue else {
            errorText = flow.completionText
            return
        }
        workspace.reloadFromDisk()
        (message, errorText) = AddSheetPlan.adoptionOutcome(
            name: row.name, status: flow.statuses[row.name],
            note: flow.connectionNotes[row.name])
        await recheck()
    }

    /// Names a Protect profile jamf-cli already has in this workspace's config.yaml.
    private func addProtect(_ row: AddSheetPlan.UnassignedProfile) {
        guard currentTakesProtect else { return }
        message = nil
        errorText = nil
        do {
            let report = try OnboardingFlow.writeProtectConfig(
                profileSlug: workspace.profile, protectProfileName: row.name)
            message = ([L("Jamf Protect profile \(row.name) added to \(workspace.profile). The next collect reads its data.")] + report.notes).joined(separator: " ")
        } catch {
            errorText = L("Could not add \(row.name): \(error.localizedDescription)")
        }
        Task { await recheck() }
    }
}
