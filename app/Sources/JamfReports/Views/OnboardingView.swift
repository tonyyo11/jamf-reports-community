import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var flow = OnboardingFlow()
    @State private var showingCSVImporter = false

    private let privileges = [
        "Computers: Read", "Mobile Devices: Read", "Mobile Profiles: Read",
        "Computer EAs: Read", "Policies: Read", "Patch Mgmt: Read",
        "Mobile Apps: Read", "Software Updates: Read", "Computer Groups: Read",
    ]

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
        .fileImporter(isPresented: $showingCSVImporter, allowedContentTypes: csvTypes) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                Task {
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                    await flow.scaffoldCSV(from: url)
                }
            case .failure(let error):
                flow.lastError = error.localizedDescription
            }
        }
    }

    private var csvTypes: [UTType] {
        [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
    }

    private var progressStrip: some View {
        let sequence = flow.stepSequence
        let currentIndex = sequence.firstIndex(of: flow.currentStep) ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(sequence.enumerated()), id: \.element.id) { idx, step in
                    stepPill(step, index: idx, currentIndex: currentIndex)
                    if idx < sequence.count - 1 {
                        Rectangle().fill(Theme.Colors.hairlineStrong).frame(width: 10, height: 0.5)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Step \(flow.stepPosition) of \(flow.stepCount): \(flow.currentStep.label)"
        )
    }

    private func stepPill(_ step: OnboardingFlow.Step, index: Int, currentIndex: Int) -> some View {
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
            Text(step.label)
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(current ? Theme.Colors.fg :
                                 done ? Theme.Colors.fg2 : Theme.Text.tertiary(contrast))
        }
        .padding(.horizontal, 12)
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
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(
                text: "Step \(flow.stepPosition) of \(flow.stepCount) - \(flow.currentStep.label)",
                tone: .gold
            )
            Text(headerTitle)
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text(headerSubtitle)
                .font(.body)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(maxWidth: 650, alignment: .leading)
        }
    }

    private var headerTitle: String {
        switch flow.currentStep {
        case .welcome: "Build your Jamf Reports workspace."
        case .installCLI: "Install the Jamf CLI."
        case .workspace: "Name the workspace."
        case .authenticate:
            flow.proConnectionType == .platformGateway
                ? "Connect via Platform Gateway."
                : "Connect to Jamf Pro."
        case .validate: "Validate the profile."
        case .addProducts: "Add more products."
        case .csvMapping: "Map your first CSV export."
        case .firstReport: "Generate the first report."
        case .schoolConnect: "Connect Jamf School."
        }
    }

    private var headerSubtitle: String {
        switch flow.currentStep {
        case .welcome:
            "This wizard creates the local folder structure, registers a jamf-cli profile, scaffolds config.yaml from your export, and runs the first workbook."
        case .installCLI:
            "The app detects jamf-cli locally. Installation stays under your control; copy the Homebrew command if it is missing."
        case .workspace:
            "The profile name becomes both the jamf-cli profile id and the folder under "
            + "\(WorkspaceRootStore.displayRoot)."
        case .authenticate:
            flow.proConnectionType == .platformGateway
                ? "Registers a jamf-cli profile with Platform API auth. Secrets are passed over stdin and cleared immediately."
                : "Jamf Reports passes the API client secret to jamf-cli over stdin and clears the field after the profile add command returns."
        case .validate:
            "jamf-cli validates the saved profile before report setup continues."
        case .addProducts:
            "Optionally connect Jamf Protect and Jamf School. Both products are skippable — you can add them later from Settings."
        case .csvMapping:
            "CSV imports are accepted from ~/Documents, ~/Downloads, or ~/Desktop. The app's scaffold tool reads the CSV headers and writes the workspace config."
        case .firstReport:
            "The final step runs generate for the new profile and streams output here."
        case .schoolConnect:
            "Registers a jamf-cli Jamf School profile with your Network ID and API key over stdin, then wires school_cli into this workspace's config so reports route to the Jamf School engine."
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
        case .csvMapping:
            csvMappingStep
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
                        Mono(text: "jamf-cli -p \(flow.profileName.trimmedForView) config validate", size: 11.5)
                    }
                    Spacer()
                    if let exit = flow.validationExitCode {
                        Pill(text: "EXIT \(exit)", tone: exit == 0 ? .teal : .danger)
                    }
                }
            }

            logViewer(
                title: flow.isValidatingConnection ? "jamf-cli validate running" : "jamf-cli validate output",
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
                    Text("A workspace is a local, per-Jamf-instance home for config, snapshots, generated reports, automation logs, and CSV intake.")
                        .font(.title3)
                        .foregroundStyle(Theme.Colors.fg2)
                        .frame(maxWidth: 640, alignment: .leading)
                    HStack(spacing: 8) {
                        Pill(text: "700 folders", tone: .teal, icon: "lock.fill")
                        Pill(text: "stdin secret", tone: .gold, icon: "key.fill")
                        Pill(text: "no shell install", tone: .muted, icon: "terminal")
                    }
                }
            }
        }
    }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 20) {
                HStack(alignment: .center, spacing: 14) {
                    statusIcon(ok: flow.jamfCLIInstalled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(flow.jamfCLIInstalled ? "jamf-cli detected" : "jamf-cli not detected")
                            .font(.headline)
                            .foregroundStyle(Theme.Colors.fg)
                        Mono(
                            text: flow.jamfCLIVersion.map { "Version \($0)" } ?? "Search paths: /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin",
                            size: 11.5
                        )
                    }
                    Spacer()
                    PNPButton(title: "Re-check", icon: "arrow.clockwise") {
                        flow.refreshJamfCLIStatus()
                    }
                }
            }

            Card(padding: 0) {
                HStack(spacing: 10) {
                    Mono(text: flow.brewCommand, size: 12, color: Theme.Colors.fg2)
                    Spacer()
                    PNPButton(title: "Copy", icon: "doc.on.doc", size: .sm) {
                        SystemActions.copyToClipboard(flow.brewCommand)
                    }
                }
                .padding(14)
                .background(Theme.Colors.codeBG)
            }
        }
    }

    private var workspaceStep: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: "Profile name", trailing: "required")
                    PNPTextField(value: binding(\.profileName), placeholder: "my-tenant", mono: true)
                    HStack(spacing: 6) {
                        Image(systemName: flow.isProfileNameValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(flow.isProfileNameValid ? Theme.Colors.ok : Theme.Colors.danger)
                        FieldHelp(text: "Use lowercase letters, numbers, dots, underscores, or hyphens.")
                    }
                }

                Divider().background(Theme.Colors.hairline)

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(label: "Workspace folder")
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.Colors.goldBright)
                        Mono(text: flow.workspacePreviewPath, size: 12.5, color: Theme.Colors.fg2)
                    }
                    if flow.workspaceCreated {
                        Pill(text: "CREATED", tone: .teal, icon: "checkmark")
                    }
                }

            }
        }
    }

    private var authenticateStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Connection-type picker
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Connection type")
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

            if flow.proConnectionType == .oauth2 {
                oauth2Form
            } else {
                platformGatewayForm
            }
        }
    }

    private var oauth2Form: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: "Jamf Pro URL")
                    PNPTextField(value: binding(\.jamfURL), placeholder: "https://example.jamfcloud.com")
                    validationLine(ok: flow.isJamfURLValid, text: "Must use https:// and include a host")
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Client ID")
                        PNPTextField(value: binding(\.clientID), mono: true)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Client Secret")
                        SecureSecretField(
                            placeholder: "OAuth client secret",
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
                    Pill(text: "PROFILE REGISTERED", tone: .teal, icon: "checkmark")
                } else if flow.isRegisteringProfile {
                    Pill(text: "VERIFYING", tone: .gold, icon: "arrow.clockwise")
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
                        Text("1. Go to account.jamf.com → API Clients")
                        Text("2. Create an API Client and note the Client ID")
                        Text("3. Generate a Client Secret (shown only once)")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Gateway URL")
                        PNPTextField(
                            value: binding(\.gatewayURL),
                            placeholder: "https://us.api.jamfcloud.com",
                            mono: true
                        )
                        validationLine(ok: flow.isGatewayURLValid, text: "Must use https:// and include a host")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel(label: "Platform API scope")
                        SegmentedControl(
                            selection: Binding(
                                get: { flow.platformScope },
                                set: { flow.platformScope = $0 }
                            ),
                            options: OnboardingFlow.PlatformScope.allCases.map {
                                ($0, $0.label, nil)
                            }
                        )
                        Text(
                            "Environment is where a GA integration is usually created "
                                + "(needs jamf-cli 1.28 or later). Tenant is the legacy "
                                + "single-tenant level. Organization sends no scope at all."
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.fg2)
                        if flow.platformScope.needsID {
                            FieldLabel(label: flow.platformScope.idFieldLabel)
                            PNPTextField(
                                value: binding(\.platformScopeID),
                                placeholder: flow.platformScope == .environment
                                    ? "your-environment-id" : "your-tenant-id",
                                mono: true
                            )
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client ID")
                            PNPTextField(value: binding(\.platformClientID), mono: true)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client Secret")
                            SecureSecretField(
                                placeholder: "Platform client secret",
                                onTextChange: { flow.platformSecretFieldHasText = $0 }
                            ) { data in
                                flow.setPlatformClientSecret(data)
                            }
                            .frame(height: 28)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if flow.profileRegistered {
                        Pill(text: "PROFILE REGISTERED", tone: .teal, icon: "checkmark")
                    } else if flow.isRegisteringProfile {
                        Pill(text: "VERIFYING", tone: .gold, icon: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var addProductsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            protectProductCard
            schoolProductCard
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
                        Pill(text: "CONNECTED", tone: .teal, icon: "checkmark")
                    }
                }

                if !flow.protectConnected {
                    Divider().background(Theme.Colors.hairline)

                    Text("Create API client credentials in your Jamf Protect console under Settings → API Clients.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Protect URL")
                        PNPTextField(
                            value: binding(\.protectURL),
                            placeholder: "https://yourorg.protect.jamfcloud.com"
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Profile name")
                        PNPTextField(value: binding(\.protectProfileName), placeholder: "protect", mono: true)
                        FieldHelp(text: "Lowercase letters, numbers, hyphens, and underscores.")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client ID")
                            PNPTextField(value: binding(\.protectClientID), mono: true)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client Secret")
                            SecureSecretField(
                                placeholder: "Protect client secret",
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
                            title: flow.isConnectingProtect ? "Connecting…" : "Connect Protect",
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

    private var schoolProductCard: some View {
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
                        Text("Jamf School")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                        Text("Device and user management for K-12 and education environments.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    if flow.schoolConnected {
                        Pill(text: "CONNECTED", tone: .teal, icon: "checkmark")
                    }
                }

                if !flow.schoolConnected {
                    Divider().background(Theme.Colors.hairline)

                    Text("Find your Network ID at Devices → Enroll Device(s). Generate an API key at Organization → Settings → API.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "School URL")
                        PNPTextField(
                            value: binding(\.schoolURL),
                            placeholder: "https://yourorg.jamfcloud.com"
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Profile name")
                        PNPTextField(value: binding(\.schoolProfileName), placeholder: "school", mono: true)
                        FieldHelp(text: "Lowercase letters, numbers, hyphens, and underscores.")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Network ID")
                            PNPTextField(value: binding(\.schoolNetworkID), mono: true)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "API Key")
                            SecureSecretField(
                                placeholder: "School API key",
                                onTextChange: { flow.schoolAPIKeyFieldHasText = $0 }
                            ) { data in
                                flow.setSchoolAPIKey(data)
                            }
                            .frame(height: 28)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let err = flow.schoolConnectionError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        PNPButton(
                            title: flow.isConnectingSchool ? "Connecting…" : "Connect School",
                            icon: "graduationcap.fill",
                            style: .gold,
                            size: .sm
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            Task { await flow.registerSchoolProfile() }
                        }
                        .disabled(
                            flow.isConnectingSchool
                            || flow.schoolURL.trimmedForView.isEmpty
                            || flow.schoolProfileName.trimmedForView.isEmpty
                            || flow.schoolNetworkID.trimmedForView.isEmpty
                            || (!flow.schoolConnected && flow.schoolAPIKey.isEmpty
                                && !flow.schoolAPIKeyFieldHasText)
                        )
                    }
                }
            }
        }
    }

    /// Jamf School-only connect step (School product path).
    ///
    /// Reuses the exact Connect School machinery from the Add-products step —
    /// same `school setup` PTY call, same fields, same redaction — but connects
    /// School as the workspace's primary product via `connectSchoolAsPrimary`
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
                            Pill(text: "CONNECTED", tone: .teal, icon: "checkmark")
                        }
                    }

                    InlineBanner(icon: "info.circle.fill", tone: .info) {
                        Text("Jamf School support ships community-validated — the maintainer has no Jamf School tenant to test against. If something looks off, please open an issue or pull request.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !flow.schoolConnected {
                        Divider().background(Theme.Colors.hairline)

                        Text("Find your Network ID at Devices → Enroll Device(s). Generate an API key at Organization → Settings → API.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))

                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "School URL")
                            PNPTextField(
                                value: binding(\.schoolURL),
                                placeholder: "https://yourorg.jamfcloud.com"
                            )
                            validationLine(ok: flow.isSchoolURLValid, text: "Must use https:// and include a host")
                        }

                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                FieldLabel(label: "Network ID")
                                PNPTextField(value: binding(\.schoolNetworkID), mono: true)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 5) {
                                FieldLabel(label: "API Key")
                                SecureSecretField(
                                    placeholder: "School API key",
                                    onTextChange: { flow.schoolAPIKeyFieldHasText = $0 }
                                ) { data in
                                    flow.setSchoolAPIKey(data)
                                }
                                .frame(height: 28)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        if let err = flow.schoolConnectionError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            PNPButton(
                                title: flow.isConnectingSchool ? "Connecting…" : "Connect School",
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

    private var csvMappingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "tablecells")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.Colors.goldBright)
                            .frame(width: 40, height: 40)
                            .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("First Jamf Pro CSV export")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Text("Policy: accepted locations are Documents, Downloads, and Desktop.")
                                .font(.footnote)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        Spacer()
                        PNPButton(title: "Choose CSV", icon: "folder") {
                            showingCSVImporter = true
                        }
                        .disabled(flow.isScaffoldingCSV || flow.isSkippingCSVMapping)
                        PNPButton(title: "Skip for now", icon: "forward.fill") {
                            Task { await flow.skipCSVMapping() }
                        }
                        .disabled(flow.isScaffoldingCSV || flow.isSkippingCSVMapping)
                    }

                    if let selected = flow.selectedCSVURL {
                        HStack(spacing: 8) {
                            Image(systemName: flow.csvScaffolded ? "checkmark.circle.fill" : "doc.text")
                                .foregroundStyle(flow.csvScaffolded ? Theme.Colors.ok : Theme.Colors.fgMuted)
                            Mono(text: selected.path, size: 11.5, color: Theme.Colors.fg2)
                        }
                    }

                    if flow.csvMappingSkipped {
                        Pill(text: "MINIMAL CONFIG SEEDED", tone: .teal, icon: "checkmark")
                    }
                }
            }

            logViewer(
                title: csvLogViewerTitle,
                lines: flow.csvOutput,
                exitCode: (flow.csvScaffolded || flow.csvMappingSkipped) ? 0 : nil
            )
        }
    }

    private var csvLogViewerTitle: String {
        if flow.isScaffoldingCSV { return "Scaffold running" }
        if flow.isSkippingCSVMapping { return "Workspace init running" }
        if flow.csvMappingSkipped { return "Workspace init output" }
        return "Scaffold output"
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
                        Mono(text: "generate --profile \(flow.profileName.trimmedForView)", size: 11.5)
                    }
                    Spacer()
                    if let exit = flow.firstReportExitCode {
                        Pill(text: "EXIT \(exit)", tone: exit == 0 ? .teal : .danger)
                    }
                }
            }

            skipFinishCard

            logViewer(
                title: flow.isRunningFirstReport ? "Generate running" : "Generate output",
                lines: flow.firstReportOutput,
                exitCode: flow.firstReportExitCode
            )
        }
    }

    /// Secondary "Skip & finish setup" affordance on the First Report step.
    ///
    /// Surfaced as a sibling card under the Run card so the user sees an
    /// explicit "safe to skip" message instead of having to abandon the
    /// wizard. By the time this step renders the profile is registered,
    /// validated, and `config.yaml` is on disk — so skipping the generate
    /// run is safe; the user can run reports later from the Reports tab.
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
                    Text("Your workspace is fully set up. Skip if the generate output below looks off — you can run reports later from the Reports tab.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PNPButton(
                    title: "Skip & finish setup",
                    icon: "checkmark",
                    style: .neutral,
                    size: .md,
                    action: { skipAndFinishOnboarding() }
                )
                .disabled(flow.isRunningFirstReport)
            }
        }
    }

    /// Dismiss onboarding without running a report.
    ///
    /// Works from all three entry points:
    ///   - First-launch chooser → root OnboardingView: `reloadFromDisk` populates
    ///     `workspace.profiles`, ContentView swaps in the shell, the default
    ///     `tab = .overview` takes effect. The `.navigateToTab` post is a no-op
    ///     here because the shell's listener isn't registered yet.
    ///   - Settings "Add connection" → in-shell OnboardingView: the active tab
    ///     is `.onboarding`; the `.navigateToTab(.overview)` post lands the
    ///     user back on Overview where progress is visible.
    ///   - Sidebar "Add workspace…" → same as Settings path above.
    private func skipAndFinishOnboarding() {
        // Clear any first-launch demo preference so reloadFromDisk picks up
        // the newly-created real profile instead of staying in demo mode.
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
        workspaceStore.reloadFromDisk()
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": Tab.overview.rawValue]
        )
    }

    private var privilegesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Required Jamf Pro API privileges")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.fg)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                ForEach(privileges, id: \.self) { privilege in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Chart.tealLight)
                        Text(privilege).font(.caption).foregroundStyle(Theme.Colors.fg2)
                    }
                }
            }
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
            PNPButton(title: "Back") {
                flow.previousStep()
            }
            .disabled(flow.currentStep == .welcome || flow.isRegisteringProfile ||
                      flow.isValidatingConnection || flow.isScaffoldingCSV ||
                      flow.isSkippingCSVMapping || flow.isRunningFirstReport ||
                      flow.isConnectingProtect || flow.isConnectingSchool)
            .opacity(flow.currentStep == .welcome ? 0.45 : 1)
            .accessibilityLabel("Back to step \(max(1, flow.stepPosition - 1))")

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

    private var primaryButtonTitle: String {
        switch flow.currentStep {
        case .welcome: "Get started"
        case .installCLI: "Next"
        case .workspace: "Create workspace"
        case .authenticate: flow.isRegisteringProfile ? "Verifying" : "Verify & continue"
        case .validate:
            if flow.isValidatingConnection { "Validating" }
            else { flow.connectionValidated ? "Continue" : "Validate" }
        case .addProducts: "Continue"
        case .csvMapping:
            if flow.isScaffoldingCSV { "Mapping" }
            else if flow.isSkippingCSVMapping { "Seeding" }
            else { "Continue" }
        case .firstReport: flow.isRunningFirstReport ? "Running" : "Run now"
        case .schoolConnect: flow.schoolConnected ? "Continue" : "Connect School to continue"
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
        case .csvMapping: "arrow.right"
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
        case .csvMapping:
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

    private func validationLine(ok: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(ok ? Theme.Chart.tealLight : Theme.Colors.danger)
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
                        Pill(text: "EXIT \(exitCode)", tone: exitCode == 0 ? .teal : .danger)
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
