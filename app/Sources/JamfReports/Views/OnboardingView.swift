import AppKit
import SwiftUI
import TipKit

struct OnboardingView: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var flow = OnboardingFlow()
    @State private var confirmingStartOver = false
    @State private var isStartingOver = false
    /// Set on first launch only: returns to the chooser, where the path was picked.
    var onStartOver: (() -> Void)?

    /// The profile name as the commands on this screen show it.
    private var shellProfile: String { ProfileName.shellWord(flow.profileName.trimmedForView) }
    private var profileOption: String { ProfileName.profileOption(flow.profileName.trimmedForView) }

    /// One profile holds one environment ID; an integration scoped to several needs one profile
    /// each, with the same client ID and secret.
    static let platformProfileNote = L("A profile holds one environment. To report on more environments from the same integration, use Add environments in Data Sources after setup; they reuse this client ID and secret. jamf-cli's Jamf Pro and Classic commands that the gateway refuses need a separate Jamf Pro OAuth profile; Jamf Reports runs none of them.")

    /// The privileges for the commands a collect runs, each labelled with its source; the 1.31.1
    /// list until the installed jamf-cli's catalog has been read.
    @State private var privileges = CommandCatalog.bundledCollectPrivileges

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                progressStrip
                stepHeader
                currentStepBody
                errorBanner
                navigationButtons
            }
            .padding(EdgeInsets(top: 40, leading: 60, bottom: 40, trailing: 60))
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.winBG)
        // The jamf-cli probe waits on child processes, so it starts here and runs off the main
        // actor, never from `OnboardingFlow.init()` while this view is being built.
        .task { await flow.refreshJamfCLIStatus() }
        // The flow goes with the view (the Add sheet starting a new onboarding, a tab switch),
        // so its typed secrets are wiped first.
        .onDisappear { [flow, workspaceStore] in
            flow.clearAllSecrets()
            workspaceStore.onboardingRunHasWork = false
        }
        .onChange(of: flow.startOverRemovesSomething) { _, hasWork in
            workspaceStore.onboardingRunHasWork = hasWork
        }
        .confirmationDialog(
            "Start over?", isPresented: $confirmingStartOver, titleVisibility: .visible
        ) {
            Button("Start over", role: .destructive) { performStartOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(flow.startOverMessage)
        }
    }

    private var progressStrip: some View {
        let sequence = flow.stepSequence
        let currentIndex = sequence.firstIndex(of: flow.currentStep) ?? 0
        // The named Pro strip is the widest and falls to the compact row first; the shorter
        // School strip stays named on a wide window.
        return ViewThatFits(in: .horizontal) {
            stepRow(sequence, currentIndex: currentIndex, compact: false)
            stepRow(sequence, currentIndex: currentIndex, compact: true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    stepRow(sequence, currentIndex: currentIndex, compact: true)
                }
                .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
                .onChange(of: currentIndex) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Step \(flow.stepPosition) of \(flow.stepCount): \(flow.currentStep.label)"
        )
    }

    private func stepRow(
        _ sequence: [OnboardingFlow.Step], currentIndex: Int, compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            ForEach(Array(sequence.enumerated()), id: \.element.id) { idx, step in
                stepPill(step, index: idx, currentIndex: currentIndex, compact: compact)
                    .id(idx)
                if idx < sequence.count - 1 {
                    Rectangle().fill(Theme.Colors.hairlineStrong).frame(width: 10, height: 0.5)
                }
            }
        }
    }

    private func stepPill(
        _ step: OnboardingFlow.Step, index: Int, currentIndex: Int, compact: Bool
    ) -> some View {
        let done = index < currentIndex
        let current = index == currentIndex

        return HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Chart.tealLight)
            } else {
                Text("\(index + 1)")
                    .font(Theme.Fonts.mono(10, weight: .semibold))
                    .foregroundStyle(current ? Theme.Colors.goldBright : Theme.Text.tertiary(contrast))
            }
            if !compact || current {
                Text(step.label)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(current ? Theme.Colors.fg :
                                     done ? Theme.Colors.fg2 : Theme.Text.tertiary(contrast))
            }
        }
        .padding(.horizontal, compact && !current ? 10 : 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(
                current ? Theme.Colors.gold.opacity(0.18) :
                done ? Theme.Colors.teal.opacity(0.20) : Color.white.opacity(0.04)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                current ? Theme.Colors.gold.opacity(0.5) :
                done ? Theme.Colors.teal.opacity(0.4) : Theme.Colors.hairline,
                lineWidth: 0.5
            )
        )
        .help(step.label)
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(
                text: L("Step \(flow.stepPosition) of \(flow.stepCount) - \(flow.currentStep.label)"),
                tone: .gold
            )
            Text(headerTitle)
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .accessibilityAddTraits(.isHeader)
            Text(headerSubtitle)
                .font(.body)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(maxWidth: 650, alignment: .leading)
        }
    }

    private var headerTitle: String {
        switch flow.currentStep {
        case .welcome: L("Build your Jamf Reports workspace.")
        case .installCLI: L("Install the Jamf CLI.")
        case .workspace: L("Name the workspace.")
        case .authenticate:
            flow.proConnectionType == .platformGateway
                ? L("Connect with Jamf Account.")
                : L("Connect to Jamf Pro.")
        case .validate: L("Validate the profile.")
        case .addProducts: L("Add more products.")
        case .firstReport:
            flow.productPath == .school
                ? L("Generate the first report.")
                : L("Collect and generate the first report.")
        case .schoolConnect: L("Connect Jamf School.")
        }
    }

    private var headerSubtitle: String {
        switch flow.currentStep {
        case .welcome:
            L("This wizard creates the workspace folders, registers a jamf-cli profile, writes config.yaml and runs the first report.")
        case .installCLI:
            L("The app detects jamf-cli locally. Installation stays under your control; copy the Homebrew command if it is missing.")
        case .workspace:
            L("The profile name becomes both the jamf-cli profile id and the folder under \(WorkspaceRootStore.displayRoot).")
        case .authenticate:
            flow.proConnectionType == .platformGateway
                ? L("Registers a jamf-cli profile with Platform API auth. Secrets are passed over stdin and cleared immediately.")
                : L("Jamf Reports passes the client secret to jamf-cli over stdin and clears it as soon as jamf-cli has saved the profile.")
        case .validate:
            L("jamf-cli validates the saved profile before report setup continues.")
        case .addProducts:
            L("Optionally connect Jamf Protect. It is skippable — you can add it later from Data Sources. Jamf School uses its own workspace.")
        case .firstReport:
            flow.productPath == .school
                ? L("The final step runs generate for the new profile and streams output here.")
                : L("Collects a snapshot, then generates the first report. The per-device scans run later on their schedule, or via Collect now on Overview.")
        case .schoolConnect:
            L("Registers a jamf-cli Jamf School profile with your Network ID and API key over stdin, then sets this workspace to report on Jamf School.")
        }
    }

    @ViewBuilder
    private var currentStepBody: some View {
        switch flow.currentStep {
        case .welcome:
            welcomeStep
        case .installCLI:
            installStep
        case .workspace:
            workspaceStep
        case .authenticate:
            authenticateStep
        case .validate:
            validateStep
        case .addProducts:
            addProductsStep
        case .firstReport:
            firstReportStep
        case .schoolConnect:
            schoolConnectStep
        }
    }

    private var validateStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 18) {
                HStack(spacing: 12) {
                    Image(systemName: flow.connectionValidated ? "checkmark.circle.fill" : "network.badge.shield.half.filled")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(flow.connectionValidated ? Theme.Colors.ok : Theme.Colors.goldBright)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Validate profile \(flow.profileName.trimmedForView)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                        Mono(text: "jamf-cli -p \(shellProfile) config validate", size: 11.5)
                    }
                    Spacer()
                    if let exit = flow.validationExitCode {
                        Pill(text: L("EXIT \(exit)"), tone: exit == 0 ? .teal : .danger)
                    }
                }
            }

            if let check = flow.connectionCheck {
                ConnectionCheckBanner(
                    verdict: check, onSetUpSchool: startSchoolWorkspace,
                    tenantLevel: flow.platformScope == .tenant)
            }

            if flow.offersContinueWithoutValidating {
                HStack(spacing: 10) {
                    Text("The profile is saved even though validation failed. Fix the URL, client ID, or secret later from Data Sources, or continue now.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    PNPButton(title: L("Continue without validating")) {
                        flow.nextStep()
                    }
                }
            }

            logViewer(
                title: flow.isValidatingConnection ? L("jamf-cli validate running") : L("jamf-cli validate output"),
                lines: flow.validationOutput,
                exitCode: flow.validationExitCode
            )
        }
    }

    private var welcomeStep: some View {
        Card(padding: 24) {
            HStack(alignment: .top, spacing: 22) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Theme.Colors.goldBright)
                    .frame(width: 72, height: 72)
                    .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 12) {
                    Text("A workspace is a local, per-Jamf-instance home for config, snapshots, generated reports, and automation logs.")
                        .font(.title3)
                        .foregroundStyle(Theme.Colors.fg2)
                        .frame(maxWidth: 640, alignment: .leading)
                    // Wraps: one row of these pills is wider than the setup column opened
                    // from Settings, and it pushed the sidebar off the window.
                    FlowLayout(spacing: 8) {
                        Pill(text: L("Owner-only folders"), tone: .teal, icon: "lock.fill")
                        Pill(text: L("Secret never stored by the app"), tone: .gold, icon: "key.fill")
                        Pill(text: L("No Terminal needed"), tone: .muted, icon: "terminal")
                    }
                }
            }
        }
    }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 20) {
                HStack(alignment: .center, spacing: 14) {
                    cliStatusIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cliStatusTitle)
                            .font(.headline)
                            .foregroundStyle(Theme.Colors.fg)
                        Mono(
                            text: flow.jamfCLIVersion.map { L("Version \($0)") } ?? L("Search paths: /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin"),
                            size: 11.5
                        )
                    }
                    Spacer()
                    PNPButton(title: L("Re-check"), icon: "arrow.clockwise") {
                        Task { await flow.refreshJamfCLIStatus() }
                    }
                    .disabled(flow.isCheckingJamfCLI)
                }
            }

            // Setup is the way out of demo mode, so it checks the real jamf-cli rather than
            // showing a demo one; say so, since the title bar still reads demo.
            if workspaceStore.demoMode {
                Text("Demo mode is on. Setup checks the jamf-cli on this Mac because it creates a real profile, and demo mode ends when setup finishes.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(padding: 0) {
                HStack(spacing: 10) {
                    Mono(text: flow.brewCommand, size: 12, color: Theme.Colors.fg2)
                    Spacer()
                    PNPButton(title: L("Copy"), icon: "doc.on.doc", size: .sm) {
                        SystemActions.copyToClipboard(flow.brewCommand)
                    }
                }
                .padding(14)
                .background(Theme.Colors.codeBG)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("No Homebrew? Download the installer package (.pkg) from the jamf-cli GitHub releases page, run it, then click Re-check above.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                Link("Open GitHub releases", destination: JamfCLIInstaller.githubReleasesURL)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var cliStatusIcon: some View {
        if flow.isCheckingJamfCLI {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking for jamf-cli")
                .frame(width: 34)
        } else {
            statusIcon(ok: flow.jamfCLIInstalled)
        }
    }

    private var cliStatusTitle: String {
        if flow.isCheckingJamfCLI { return L("Checking for jamf-cli\u{2026}") }
        return flow.jamfCLIInstalled ? L("jamf-cli detected") : L("jamf-cli not detected")
    }

    private var workspaceStep: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: L("Profile name"), trailing: "required")
                    PNPTextField(value: binding(\.profileName), placeholder: "my-tenant", mono: true)
                    HStack(spacing: 6) {
                        switch OnboardingFlow.feedback(
                            for: flow.profileName, isValid: flow.isProfileNameValid
                        ) {
                        case .hint:
                            EmptyView()
                        case .valid:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Colors.ok)
                        case .invalid:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.Colors.danger)
                        }
                        FieldHelp(text: L("Any name without line breaks or spaces at either end."))
                    }
                }

                Divider().background(Theme.Colors.hairline)

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(label: L("Workspace folder"))
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.Colors.goldBright)
                        Mono(text: flow.workspacePreviewPath, size: 12.5, color: Theme.Colors.fg2)
                    }
                    if flow.workspaceCreated {
                        Pill(text: L("CREATED"), tone: .teal, icon: "checkmark")
                    }
                }

            }
        }
    }

    private var authenticateStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The first-launch chooser already picked the connection; Start over changes it.
            if onStartOver == nil {
                connectionTypePicker
            }

            if flow.proConnectionType == .oauth2 {
                oauth2Form
            } else {
                platformGatewayForm
            }
        }
    }

    private var connectionTypePicker: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(label: L("Connection type"))
                Picker("", selection: Binding(
                    get: { flow.proConnectionType },
                    set: { flow.proConnectionType = $0 }
                )) {
                    ForEach(OnboardingFlow.ProConnectionType.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                TipView(OnboardingTips.connectionType)
            }
        }
    }

    private var oauth2Form: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: L("Jamf Pro URL"))
                    PNPTextField(value: binding(\.jamfURL), placeholder: "https://example.jamfcloud.com")
                    validationLine(
                        value: flow.jamfURL, ok: flow.isJamfURLValid,
                        text: L("Must use https:// and include a host")
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: L("Client ID"))
                        PNPTextField(
                            value: binding(\.clientID), placeholder: L("OAuth client ID"), mono: true)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: L("Client Secret"))
                        SecureSecretField(
                            placeholder: L("OAuth client secret"),
                            onTextChange: { flow.secretFieldHasText = $0 }
                        ) { data in
                            flow.setClientSecret(data)
                        }
                        .frame(height: 28)
                        TipView(OnboardingTips.secretField)
                    }
                    .frame(maxWidth: .infinity)
                }

                privilegesBox

                if flow.profileRegistered {
                    Pill(text: L("PROFILE REGISTERED"), tone: .teal, icon: "checkmark")
                } else if flow.isRegisteringProfile {
                    Pill(text: L("SAVING PROFILE"), tone: .gold, icon: "arrow.clockwise")
                }
            }
        }
    }

    private var platformGatewayForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Before continuing info box
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Theme.Colors.goldBright)
                        Text("Before continuing:")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. In account.jamf.com, open Integrations → Create integration")
                        Text("2. Scope level: Platform environment (recommended), choosing the environment that holds your Jamf Pro tenant. Tenant level is legacy and cannot reach Compliance Benchmarks or Blueprints")
                        Text("3. Permissions: Read only, for the report areas you want")
                        Text("4. Copy the client ID and the client secret (shown only once)")
                        Text("5. Copy the environment ID: open the integration and click the environment pill")
                        Text("6. Integrations are valid for six months")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg2)
                    Text(OnboardingView.platformProfileNote)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    GatewayRegionPicker(flow: flow)

                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel(label: L("Platform API scope"))
                        SegmentedControl(
                            selection: Binding(
                                get: { flow.platformScope },
                                set: { flow.platformScope = $0 }
                            ),
                            options: OnboardingFlow.PlatformScope.allCases.map {
                                ($0, $0.label, nil)
                            }
                        )
                        Text(OnboardingFlow.PlatformScope.caption)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.fg2)
                        FieldLabel(label: flow.platformScope.idFieldLabel)
                        PNPTextField(
                            value: binding(\.platformScopeID),
                            placeholder: flow.platformScope == .environment
                                ? "your-environment-id" : "your-tenant-id",
                            mono: true
                        )
                        if let problem = flow.platformScopeIDProblem {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.danger)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: L("Client ID"))
                            PNPTextField(
                                value: binding(\.platformClientID),
                                placeholder: L("Platform client ID"), mono: true)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: L("Client Secret"))
                            SecureSecretField(
                                placeholder: L("Platform client secret"),
                                onTextChange: { flow.platformSecretFieldHasText = $0 }
                            ) { data in
                                flow.setPlatformClientSecret(data)
                            }
                            .frame(height: 28)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if flow.profileRegistered {
                        Pill(text: L("PROFILE REGISTERED"), tone: .teal, icon: "checkmark")
                    } else if flow.isRegisteringProfile {
                        Pill(text: L("SAVING PROFILE"), tone: .gold, icon: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var addProductsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            protectProductCard
            Text("Jamf School uses its own workspace. Add one later with Settings › Add connection, or Add workspace or product in the sidebar's workspace menu.")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What recording a connection in config.yaml did not keep, under its CONNECTED pill.
    @ViewBuilder
    private func configNote(_ note: String?) -> some View {
        if let note {
            Text(note)
                .font(.caption)
                .foregroundStyle(Theme.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protectProductCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.goldBright)
                        .frame(width: 38, height: 38)
                        .background(
                            Theme.Colors.gold.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Jamf Protect")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                        Text("Endpoint detection, analytics, and compliance signals.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    if flow.protectConnected {
                        Pill(text: L("CONNECTED"), tone: .teal, icon: "checkmark")
                    }
                }

                configNote(flow.protectConfigNote)

                if !flow.protectConnected {
                    Divider().background(Theme.Colors.hairline)

                    Text("""
                        Create API client credentials in your Jamf Protect console under \
                        Administrative → API Clients.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: L("Protect URL"))
                        PNPTextField(
                            value: binding(\.protectURL),
                            placeholder: "https://yourorg.protect.jamfcloud.com"
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: L("Profile name"))
                        PNPTextField(value: binding(\.protectProfileName), placeholder: "protect", mono: true)
                        FieldHelp(text: L("Any name without line breaks or spaces at either end."))
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: L("Client ID"))
                            PNPTextField(value: binding(\.protectClientID), mono: true)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: L("Client Secret"))
                            SecureSecretField(
                                placeholder: L("Protect client secret"),
                                onTextChange: { flow.protectSecretFieldHasText = $0 }
                            ) { data in
                                flow.setProtectClientSecret(data)
                            }
                            .frame(height: 28)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let err = flow.protectConnectionError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        PNPButton(
                            title: flow.isConnectingProtect ? L("Connecting…") : L("Connect Protect"),
                            icon: "shield.lefthalf.filled",
                            style: .gold,
                            size: .sm
                        ) {
                            // Force finalization before reading credentials.
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            Task { await flow.registerProtectProfile() }
                        }
                        .disabled(
                            flow.isConnectingProtect
                            || flow.protectURL.trimmedForView.isEmpty
                            || flow.protectProfileName.trimmedForView.isEmpty
                            || flow.protectClientID.trimmedForView.isEmpty
                            || (!flow.protectConnected && flow.protectClientSecret.isEmpty
                                && !flow.protectSecretFieldHasText)
                        )
                    }
                }
            }
        }
    }

    /// Jamf School-only connect step (School product path).
    ///
    /// Connects School as the workspace's primary product via `connectSchoolAsPrimary`
    /// (the workspace profile name is the School jamf-cli profile; there is no
    /// separate profile-name field here).
    private var schoolConnectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.Colors.goldBright)
                            .frame(width: 38, height: 38)
                            .background(
                                Theme.Colors.gold.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connect Jamf School")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Text("Registers this workspace as a Jamf School profile.")
                                .font(.footnote)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        Spacer()
                        if flow.schoolConnected {
                            Pill(text: L("CONNECTED"), tone: .teal, icon: "checkmark")
                        }
                    }

                    InlineBanner(icon: "info.circle.fill", tone: .info) {
                        Text("If something in Jamf School support looks off, please open an issue or pull request.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    configNote(flow.schoolConfigNote)
                    if flow.schoolConnected, let check = flow.schoolPlatformCheck {
                        SchoolPlatformFields.banner(check)
                    }

                    if !flow.schoolConnected {
                        Divider().background(Theme.Colors.hairline)

                        Text("Find your Network ID at Devices → Enroll Device(s). Generate an API key at Organization → Settings → API.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: L("School URL"))
                            PNPTextField(
                                value: binding(\.schoolURL),
                                placeholder: "https://yourorg.jamfcloud.com"
                            )
                            validationLine(
                                value: flow.schoolURL, ok: flow.isSchoolURLValid,
                                text: L("Must use https:// and include a host")
                            )
                        }

                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                FieldLabel(label: L("Network ID"))
                                PNPTextField(
                                    value: binding(\.schoolNetworkID), placeholder: L("Network ID"),
                                    mono: true)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 5) {
                                FieldLabel(label: L("API Key"))
                                SecureSecretField(
                                    placeholder: L("School API key"),
                                    onTextChange: { flow.schoolAPIKeyFieldHasText = $0 }
                                ) { data in
                                    flow.setSchoolAPIKey(data)
                                }
                                .frame(height: 28)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        SchoolPlatformFields(flow: flow)

                        if let err = flow.schoolConnectionError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            PNPButton(
                                title: flow.isConnectingSchool ? L("Connecting…") : L("Connect School"),
                                icon: "graduationcap.fill",
                                style: .gold,
                                size: .sm
                            ) {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                Task { await flow.connectSchoolAsPrimary() }
                            }
                            .disabled(!flow.canAttemptSchoolConnect)
                        }
                    }
                }
            }
        }
    }

    private var firstReportStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.Colors.goldBright)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Run profile \(flow.profileName.trimmedForView)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                        Mono(text: "generate \(profileOption)", size: 11.5)
                    }
                    Spacer()
                    if let exit = flow.firstReportExitCode {
                        Pill(text: L("EXIT \(exit)"), tone: exit == 0 ? .teal : .danger)
                    }
                }
            }

            automationAndWebhookCard

            skipFinishCard

            logViewer(
                title: flow.isRunningFirstReport ? L("Generate running") : L("Generate output"),
                lines: flow.firstReportOutput,
                exitCode: flow.firstReportExitCode
            )
        }
    }

    /// "Run automatically" (on by default) and the optional webhook, applied when setup
    /// finishes, whether by the first report or by Skip & finish. Open in demo mode too: setup
    /// creates a real profile and finishing it leaves demo mode.
    private var automationAndWebhookCard: some View {
        let locked = flow.isRunningFirstReport
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run automatically").font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
                AutomationChoiceFields(choice: $flow.automation, isLocked: locked)
                Divider().background(Theme.Colors.hairline)
                Text("Webhook (optional)").font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
                Text("Scheduled runs post digests and failure alerts to a Teams or Slack incoming webhook. Leave empty to skip; change it anytime under Automation › Notifications.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Service", selection: $flow.webhookProvider) {
                    ForEach(NotifyConfig.Provider.allCases, id: \.self) { provider in
                        Text(provider == .teams ? "Microsoft Teams" : "Slack").tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
                .disabled(locked)
                // The URL is a bearer secret: anyone holding it can post to the channel.
                SecureField("https://...", text: $flow.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: 420, alignment: .leading)
                    .disabled(locked)
                    .accessibilityLabel("Webhook URL")
                if NotifyConfigWriter.showsInsecureURLWarning(enabled: true, url: flow.webhookURL) {
                    Text("URL must start with https:// — it will not be saved.")
                        .font(.footnote).foregroundStyle(Theme.Colors.warn)
                }
            }
        }
    }

    /// Secondary "Skip & finish setup" affordance on the First Report step.
    ///
    /// Surfaced as a sibling card under the Run card so the user sees an
    /// explicit "safe to skip" message instead of having to abandon the
    /// wizard. The profile is registered and `config.yaml` is on disk, but
    /// the profile may not have validated (Continue without validating).
    private var skipFinishCard: some View {
        Card(padding: 18) {
            HStack(spacing: 12) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fgMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skip the first run?")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text(Self.skipFinishText(validated: flow.connectionValidated))
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PNPButton(
                    title: L("Skip & finish setup"),
                    icon: "checkmark",
                    style: .neutral,
                    size: .md,
                    action: { skipAndFinishOnboarding() }
                )
                .disabled(flow.isRunningFirstReport)
            }
        }
    }

    nonisolated static func skipFinishText(validated: Bool) -> String {
        validated
            ? L("Your workspace is fully set up. Skip if the generate output below looks off — you can run reports later from the Reports tab.")
            : L("Your workspace is saved, but the profile did not validate, so the first run will probably fail. Skip it, fix the connection from Data Sources, then run reports from the Reports tab.")
    }

    /// Dismiss onboarding without running a report.
    ///
    /// Works from all three entry points:
    ///   - First-launch chooser → root OnboardingView: `reloadFromDisk` populates
    ///     `workspace.profiles`, ContentView swaps in the shell, the default
    ///     `tab = .overview` takes effect. The `.navigateToTab` post is a no-op
    ///     here because the shell's listener isn't registered yet.
    ///   - The Add sheet's New workspace → in-shell OnboardingView: the active tab
    ///     is `.onboarding`; the `.navigateToTab(.overview)` post lands the
    ///     user back on Overview where progress is visible.
    /// Restarts this screen on the Jamf School steps, as the Add sheet's Jamf School card
    /// does. The profile saved for the Platform ID stays in jamf-cli.
    private func startSchoolWorkspace() {
        flow.clearAllSecrets()
        OnboardingFlow.pendingProductPath = .school
        flow = OnboardingFlow()
        Task { await flow.refreshJamfCLIStatus() }
    }

    private func skipAndFinishOnboarding() {
        // Leave demo mode, through its cleanup, so the newly created real
        // profile replaces the demo; otherwise reload to pick it up.
        Task {
            await flow.finishSetup(in: workspaceStore)
            NotificationCenter.default.post(
                name: .navigateToTab,
                object: nil,
                userInfo: ["tab": Tab.overview.rawValue]
            )
        }
    }

    private func privilegeLabel(_ privilege: CommandCatalog.Privilege) -> Text {
        let name = Text(privilege.name).foregroundStyle(Theme.Colors.fg2)
        let source = Text(privilege.source.rawValue).foregroundStyle(Theme.Colors.fgMuted)
        return Text("\(name) \(source)")
    }

    private var privilegesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Required Jamf Pro API privileges")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.fg)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                ForEach(privileges, id: \.name) { privilege in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Chart.tealLight)
                        privilegeLabel(privilege).font(.caption)
                    }
                }
            }
            Text("Names marked jamf-cli come from jamf-cli's command list. It lists none for report and Classic commands, so Jamf Reports adds those from its own permissions page.")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.fg2)
        }
        .task {
            let read = await Task.detached {
                CommandCatalog.installed()?.collectPrivileges()
            }.value
            if let read, !read.isEmpty { privileges = read }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = flow.lastError {
            InlineBanner(icon: "exclamationmark.triangle.fill", tone: .warn) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg2)
            }
        }
    }

    private var navigationButtons: some View {
        HStack {
            PNPButton(title: L("Back")) {
                if flow.currentStep == .welcome { requestStartOver() } else { flow.previousStep() }
            }
            .disabled(!backEnabled)
            .opacity(backEnabled ? 1 : 0.45)
            .accessibilityLabel(flow.currentStep == .welcome
                ? "Back to the first screen" : "Back to step \(max(1, flow.stepPosition - 1))")

            if onStartOver != nil && flow.currentStep != .welcome {
                PNPButton(title: L("Start over"), icon: "arrow.uturn.backward") {
                    requestStartOver()
                }
                .disabled(flow.isBusy || isStartingOver)
                .help("Go back to the first screen and choose another way to connect")
            }

            Spacer()

            PNPButton(
                title: primaryButtonTitle,
                icon: primaryButtonIcon,
                style: flow.canAdvance ? .gold : .neutral,
                size: .lg
            ) {
                advance()
            }
            .disabled(!flow.canAdvance)
            .opacity(flow.canAdvance ? 1 : 0.55)
        }
    }

    private var backEnabled: Bool {
        guard !flow.isBusy, !isStartingOver else { return false }
        return flow.currentStep != .welcome || onStartOver != nil
    }

    /// Asks first when setup has created a folder or a jamf-cli profile, else goes straight back.
    private func requestStartOver() {
        if flow.startOverRemovesSomething {
            confirmingStartOver = true
        } else {
            performStartOver()
        }
    }

    /// Leaves for the chooser only when everything setup created is gone; otherwise the error
    /// banner names what is left and how to remove it.
    private func performStartOver() {
        isStartingOver = true
        Task {
            let problems = await flow.startOver()
            isStartingOver = false
            if problems.isEmpty {
                onStartOver?()
            } else {
                flow.lastError = problems.joined(separator: "\n")
            }
        }
    }

    private var primaryButtonTitle: String {
        switch flow.currentStep {
        case .welcome: L("Get started")
        case .installCLI: L("Next")
        case .workspace: L("Create workspace")
        case .authenticate: flow.isRegisteringProfile ? L("Saving") : L("Save & continue")
        case .validate:
            if flow.isValidatingConnection { L("Validating") }
            else { flow.connectionValidated ? L("Continue") : L("Validate") }
        case .addProducts: L("Continue")
        case .firstReport: flow.isRunningFirstReport ? L("Running") : L("Run now")
        case .schoolConnect: flow.schoolConnected ? L("Continue") : L("Connect School to continue")
        }
    }

    private var primaryButtonIcon: String {
        switch flow.currentStep {
        case .welcome: "arrow.right"
        case .installCLI: "checkmark"
        case .workspace: "folder.badge.plus"
        case .authenticate: "checkmark"
        case .validate: flow.connectionValidated ? "arrow.right" : "network.badge.shield.half.filled"
        case .addProducts: "arrow.right"
        case .firstReport: "play.fill"
        case .schoolConnect: flow.schoolConnected ? "arrow.right" : "graduationcap.fill"
        }
    }

    private func advance() {
        switch flow.currentStep {
        case .welcome, .installCLI:
            flow.nextStep()
        case .workspace:
            do {
                try flow.createWorkspace()
                flow.nextStep()
            } catch {
                flow.lastError = error.localizedDescription
            }
        case .authenticate:
            // Force finalization of any focused secure field before the async
            // work reads clientSecret/platformClientSecret. AppKit processes the
            // makeFirstResponder synchronously, so controlTextDidEndEditing fires
            // before the Task body runs.
            NSApp.keyWindow?.makeFirstResponder(nil)
            Task {
                do {
                    try await flow.registerJamfCLIProfile()
                    flow.nextStep()
                } catch {
                    flow.lastError = error.localizedDescription
                }
            }
        case .validate:
            if flow.connectionValidated {
                flow.nextStep()
            } else {
                Task {
                    await flow.validateRegisteredProfile()
                }
            }
        case .addProducts:
            flow.nextStep()
        case .schoolConnect:
            // The connection itself is driven by the in-card Connect button;
            // the primary button only advances once schoolConnected is true
            // (enforced by canAdvance).
            flow.nextStep()
        case .firstReport:
            Task {
                await flow.runFirstReport(workspaceStore: workspaceStore)
            }
        }
    }

    private func statusIcon(ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(ok ? Theme.Colors.ok : Theme.Colors.danger)
            .frame(width: 34)
    }

    private func validationLine(value: String, ok: Bool, text: String) -> some View {
        let feedback = OnboardingFlow.feedback(for: value, isValid: ok)
        return HStack(spacing: 5) {
            if feedback != .hint {
                Image(systemName: feedback == .valid ? "checkmark" : "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(
            feedback == .hint ? Theme.Colors.fgMuted
                : feedback == .valid ? Theme.Chart.tealLight : Theme.Colors.danger
        )
    }

    private func logViewer(title: String, lines: [CLIBridge.LogLine], exitCode: Int32?) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Theme.Colors.gold)
                        .font(.system(size: 13))
                    Mono(text: title, size: 12, color: Theme.Colors.fg2)
                    Spacer()
                    if let exitCode {
                        Pill(text: L("EXIT \(exitCode)"), tone: exitCode == 0 ? .teal : .danger)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().background(Theme.Colors.hairlineStrong)

                VStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty {
                        Text("No output yet.")
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text(line.timestamp, style: .time)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                                    .frame(width: 72, alignment: .leading)
                                Text(line.text)
                                    .foregroundStyle(color(for: line.level))
                            }
                            .font(Theme.Fonts.mono(11.5))
                        }
                    }
                }
                .padding(14)
            }
            .background(Theme.Colors.codeBG)
        }
    }

    private func color(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Colors.fg2
        case .ok: Theme.Colors.ok
        case .warn: Theme.Colors.warn
        case .fail: Theme.Colors.danger
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<OnboardingFlow, String>) -> Binding<String> {
        Binding(
            get: { flow[keyPath: keyPath] },
            set: { flow[keyPath: keyPath] = $0 }
        )
    }
}

private extension String {
    var trimmedForView: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
