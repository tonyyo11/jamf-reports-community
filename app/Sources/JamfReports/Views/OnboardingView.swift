import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
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
        HStack(spacing: 10) {
            ForEach(Array(OnboardingFlow.Step.allCases.enumerated()), id: \.element.id) { idx, step in
                stepPill(step)
                if idx < OnboardingFlow.Step.allCases.count - 1 {
                    Rectangle().fill(Theme.Colors.hairlineStrong).frame(width: 10, height: 0.5)
                }
            }
        }
    }

    private func stepPill(_ step: OnboardingFlow.Step) -> some View {
        let done = step.rawValue < flow.currentStep.rawValue
        let current = step == flow.currentStep

        return HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: 0x6DC0C0))
            } else {
                Text("\(step.number)")
                    .font(Theme.Fonts.mono(10, weight: .semibold))
                    .foregroundStyle(current ? Theme.Colors.goldBright : Theme.Colors.fgMuted)
            }
            Text(step.label)
                .font(.system(size: 11.5))
                .foregroundStyle(current ? Theme.Colors.fg :
                                 done ? Theme.Colors.fg2 : Theme.Colors.fgMuted)
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
                text: "Step \(flow.currentStep.number) of \(OnboardingFlow.Step.allCases.count) - \(flow.currentStep.label)",
                tone: .gold
            )
            Text(headerTitle)
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text(headerSubtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.fgMuted)
                .frame(maxWidth: 650, alignment: .leading)
        }
    }

    private var headerTitle: String {
        switch flow.currentStep {
        case .welcome: "Build your Jamf Reports workspace."
        case .installCLI: "Install the Jamf CLI."
        case .workspace: "Name the workspace."
        case .authenticate: "Connect to Jamf Pro."
        case .validate: "Validate the profile."
        case .csvMapping: "Map your first CSV export."
        case .firstReport: "Generate the first report."
        }
    }

    private var headerSubtitle: String {
        switch flow.currentStep {
        case .welcome:
            "This wizard creates the local folder structure, registers a jamf-cli profile, scaffolds config.yaml from your export, and runs the first workbook."
        case .installCLI:
            "The app detects jamf-cli locally. Installation stays under your control; copy the Homebrew command if it is missing."
        case .workspace:
            "The profile name becomes both the jamf-cli profile id and the folder under ~/Jamf-Reports."
        case .authenticate:
            "Jamf Reports passes the API client secret to jamf-cli over stdin and clears the field after the profile add command returns."
        case .validate:
            "jamf-cli validates the saved profile before report setup continues."
        case .csvMapping:
            "CSV imports are accepted from ~/Documents, ~/Downloads, or ~/Desktop, then jrc scaffold writes the workspace config."
        case .firstReport:
            "The final step runs jrc generate for the new profile and streams stdout and stderr here."
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
        case .csvMapping:
            csvMappingStep
        case .firstReport:
            firstReportStep
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
                            .font(.system(size: 14, weight: .semibold))
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
                        .font(.system(size: 15))
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
                            .font(.system(size: 15, weight: .semibold))
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
                    PNPTextField(value: binding(\.profileName), placeholder: "meridian-prod", mono: true)
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
                            PNPTextField(value: binding(\.clientSecret), mono: true, secure: true)
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
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Text("Policy: accepted locations are Documents, Downloads, and Desktop.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                        PNPButton(title: "Choose CSV", icon: "folder") {
                            showingCSVImporter = true
                        }
                        .disabled(flow.isScaffoldingCSV)
                    }

                    if let selected = flow.selectedCSVURL {
                        HStack(spacing: 8) {
                            Image(systemName: flow.csvScaffolded ? "checkmark.circle.fill" : "doc.text")
                                .foregroundStyle(flow.csvScaffolded ? Theme.Colors.ok : Theme.Colors.fgMuted)
                            Mono(text: selected.path, size: 11.5, color: Theme.Colors.fg2)
                        }
                    }
                }
            }

            logViewer(
                title: flow.isScaffoldingCSV ? "jrc scaffold running" : "jrc scaffold output",
                lines: flow.csvOutput,
                exitCode: flow.csvScaffolded ? 0 : nil
            )
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Colors.fg)
                        Mono(text: "jrc generate --profile \(flow.profileName.trimmedForView)", size: 11.5)
                    }
                    Spacer()
                    if let exit = flow.firstReportExitCode {
                        Pill(text: "EXIT \(exit)", tone: exit == 0 ? .teal : .danger)
                    }
                }
            }

            logViewer(
                title: flow.isRunningFirstReport ? "jrc generate running" : "jrc generate output",
                lines: flow.firstReportOutput,
                exitCode: flow.firstReportExitCode
            )
        }
    }

    private var privilegesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Required Jamf Pro API privileges")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                ForEach(privileges, id: \.self) { privilege in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: 0x6DC0C0))
                        Text(privilege).font(.system(size: 11)).foregroundStyle(Theme.Colors.fg2)
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
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.fg2)
                Spacer()
            }
            .padding(12)
            .background(Theme.Colors.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Colors.warn.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    private var navigationButtons: some View {
        HStack {
            PNPButton(title: "Back") {
                flow.previousStep()
            }
            .disabled(flow.currentStep == .welcome || flow.isRegisteringProfile ||
                      flow.isValidatingConnection || flow.isScaffoldingCSV || flow.isRunningFirstReport)
            .opacity(flow.currentStep == .welcome ? 0.45 : 1)

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
            if flow.isValidatingConnection { "Validating" } else { flow.connectionValidated ? "Continue" : "Validate" }
        case .csvMapping: flow.isScaffoldingCSV ? "Mapping" : "Continue"
        case .firstReport: flow.isRunningFirstReport ? "Running" : "Run now"
        }
    }

    private var primaryButtonIcon: String {
        switch flow.currentStep {
        case .welcome: "arrow.right"
        case .installCLI: "checkmark"
        case .workspace: "folder.badge.plus"
        case .authenticate: "checkmark"
        case .validate: flow.connectionValidated ? "arrow.right" : "network.badge.shield.half.filled"
        case .csvMapping: "arrow.right"
        case .firstReport: "play.fill"
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
        case .csvMapping:
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
        .font(.system(size: 11.5))
        .foregroundStyle(ok ? Color(hex: 0x6DC0C0) : Theme.Colors.danger)
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
                            .foregroundStyle(Theme.Colors.fgMuted)
                    } else {
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text(line.timestamp, style: .time)
                                    .foregroundStyle(Theme.Colors.fgMuted)
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
