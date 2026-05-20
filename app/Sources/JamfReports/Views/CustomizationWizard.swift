import SwiftUI
import AppKit

// MARK: - WizardState

/// Observable state for the 7-step customization wizard.
///
/// Each step writes to this model; `ConfigView`/`CustomizeView` read back from
/// `WorkspaceStore.configState` after the wizard commits.
@Observable
@MainActor
final class WizardState {

    // MARK: Step 0 — Template Selection
    var selectedTemplate: (any ReportTemplate)?
    var useCustomTemplate: Bool = false

    // MARK: Step 1 — Org Branding
    var orgName: String = ""
    var logoPath: String = ""
    var accentColor: Color = Color(hex: "#2D5EA2") ?? .blue
    var accentDark: Color = Color(hex: "#004165") ?? .blue

    // MARK: Step 2 — Compliance Framework
    enum Framework: String, CaseIterable, Identifiable {
        case none          = "None"
        case nist80053     = "NIST 800-53 Moderate"
        case fedramp       = "FedRAMP"
        case cis           = "CIS Benchmark"
        case disaStig      = "DISA STIG"
        case custom        = "Custom"
        var id: String { rawValue }
    }
    var framework: Framework = .none
    var customFrameworkLabel: String = ""

    var resolvedFramework: String {
        switch framework {
        case .none:   return ""
        case .custom: return customFrameworkLabel
        default:      return framework.rawValue
        }
    }

    // MARK: Step 3 — Extension Attributes
    var availableEAs: [ExtensionAttribute] = []
    var eaLoadError: String? = nil
    var isLoadingEAs: Bool = false
    var selectedEAIDs: Set<String> = []
    /// For EAs with type "boolean": user-supplied value that means compliant.
    var booleanTrueValues: [String: String] = [:]

    func selectedEAs() -> [ExtensionAttribute] {
        availableEAs.filter { ea in
            guard let id = ea.id else { return false }
            return selectedEAIDs.contains(id)
        }
    }

    // MARK: Step 4 — Sheet order
    var orderedSheets: [SheetItem] = []

    // MARK: Step 5 — Inventory fields
    var availableInventoryKeys: [String] = []
    var selectedInventoryKeys: Set<String> = []

    // MARK: Step 6 — Output preferences
    var outputDir: String = "Generated Reports"
    var timestampOutputs: Bool = true
    var keepLatestRuns: Int = 10

    // MARK: Step 7 — Exceptions (optional)
    var exceptions: [ConfigException] = []
    var exceptionDrafts: [CLISuggester.DraftException] = []

    // MARK: Navigation
    var currentStep: Int = 0
    let totalSteps = 9
    var isComplete: Bool = false

    /// Flipped to true on any user input; used to gate the discard-changes confirmation.
    var hasUnsavedChanges: Bool = false

    func advance() { if currentStep < totalSteps { currentStep += 1 } }
    func retreat() { if currentStep > 0 { currentStep -= 1 } }

    // MARK: Validation

    /// True when Continue should be enabled on the current step.
    var canContinue: Bool {
        if currentStep == 0 {
            return selectedTemplate != nil || useCustomTemplate
        }
        if currentStep == 2 && framework == .custom {
            return !customFrameworkLabel.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// Applies wizard selections on top of the workspace's current config state.
    func applyTo(_ state: inout ConfigState) {
        state.orgName = orgName
        state.logoPath = logoPath
        state.accentColor = accentColor.hexString
        state.accentDark = accentDark.hexString
        // ConfigState uses `baselineLabel` for the compliance framework label.
        state.baselineLabel = resolvedFramework

        let picked = selectedEAs()
        let newEAs: [ConfigCustomEA] = picked.map { ea in
            let name = ea.name ?? "EA"
            let trueVal = booleanTrueValues[ea.id ?? ""] ?? ""
            return ConfigCustomEA(
                name: name,
                column: name,
                // ConfigCustomEA.type is String; use the raw value directly.
                type: ea.inferredEAType,
                trueValue: trueVal,
                warningThreshold: "",
                criticalThreshold: "",
                currentVersions: [],
                warningDays: ""
            )
        }
        // Merge: keep existing EAs that aren't being re-added.
        let existingNames = Set(state.customEAs.map(\.name))
        let additions = newEAs.filter { !existingNames.contains($0.name) }
        state.customEAs.append(contentsOf: additions)

        state.outputDir = outputDir
        state.timestampOutputs = timestampOutputs
        // ConfigState stores keepLatestRuns as String.
        state.keepLatestRuns = String(keepLatestRuns)
    }

    // MARK: Exception Operations

    /// Convert a draft exception to a real ConfigException and remove from drafts.
    ///
    /// - Parameters:
    ///   - draft: The draft to accept.
    ///   - expiresDate: Optional ISO-8601 `yyyy-MM-dd` expiry date string.
    ///                  When `nil`, the exception is accepted without an expiry and
    ///                  `hasNoExpiryWarning` is set so the UI can surface an audit warning.
    @discardableResult
    func acceptDraft(_ draft: CLISuggester.DraftException, expiresDate: String? = nil) -> ConfigException {
        let exception = ConfigException(
            id: draft.draftId,
            description: draft.description,
            signedOffBy: draft.proposedSignedOffBy,
            signedOffDate: draft.proposedSignedOffDate,
            expiresDate: expiresDate,
            linkedFinding: draft.linkedFinding
        )
        if expiresDate == nil { hasNoExpiryWarning = true }

        // Remove from drafts and add to accepted
        if let index = exceptionDrafts.firstIndex(where: { $0.id == draft.id }) {
            exceptionDrafts.remove(at: index)
        }
        exceptions.append(exception)

        return exception
    }

    /// Set when an exception was accepted without an expiry date.
    /// Cleared when the next exception accepted includes an expiry date.
    /// The UI uses this to show a one-line audit warning.
    var hasNoExpiryWarning: Bool = false

    /// Remove a draft exception without accepting
    func rejectDraft(_ draft: CLISuggester.DraftException) {
        if let index = exceptionDrafts.firstIndex(where: { $0.id == draft.id }) {
            exceptionDrafts.remove(at: index)
        }
    }

    /// Add a new empty exception for manual entry
    func addEmptyException() {
        let exception = ConfigException(
            id: "MANUAL-\(String(format: "%03d", exceptions.count + 1))",
            description: "Manual exception entry",
            signedOffBy: "",
            signedOffDate: "",
            expiresDate: nil,
            linkedFinding: nil
        )
        exceptions.append(exception)
    }

    /// Returns a display label for the selected template.
    var selectedTemplateName: String {
        if useCustomTemplate {
            return "Custom"
        } else if let template = selectedTemplate {
            return template.displayName
        } else {
            return "None selected"
        }
    }
}

// MARK: - CustomizationWizard

struct CustomizationWizard: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var state = WizardState()
    @State private var bridge = CLIBridge()
    @State private var showCancelConfirm = false
    @State private var saveError: String?
    var onDismiss: () -> Void

    var body: some View {
        wizardContent
            .modifier(WizardChangeObservers(state: state))
            .confirmationDialog(
                "Discard changes?",
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { onDismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your selections have not been saved to config.yaml.")
            }
            .alert(
                "Save failed",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
    }

    private var wizardContent: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()
            stepContent
            Divider()
            wizardFooter
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 480, idealHeight: 560)
        .background(Theme.Surface.base)
        .onAppear { populateFromWorkspace() }
    }

    // MARK: Header

    private var wizardHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Personalize Reports")
                    .font(Theme.Fonts.bodyText.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Step \(state.currentStep) of \(state.totalSteps) — \(stepTitle)")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            Spacer()
            ProgressView(value: Double(state.currentStep), total: Double(state.totalSteps))
                .frame(width: 120)
                .tint(Theme.Colors.gold)
                .accessibilityLabel("Step \(state.currentStep) of \(state.totalSteps): \(stepTitle)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
    }

    private var stepTitle: String {
        switch state.currentStep {
        case 0: return "Choose Template"
        case 1: return "Org Branding"
        case 2: return "Compliance Framework"
        case 3: return "Surface Custom EAs"
        case 4: return "Exceptions (optional)"
        case 5: return "Pick & Order Sheets"
        case 6: return "Inventory Fields"
        case 7: return "Output Preferences"
        case 8: return "Done — Preview"
        default: return ""
        }
    }

    // MARK: Step routing

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch state.currentStep {
                case 0: Step0TemplateView(state: state)
                case 1: Step1BrandingView(state: state)
                case 2: Step2FrameworkView(state: state)
                case 3: Step3EAsView(state: state, bridge: bridge, profile: workspace.profile)
                case 4: Step4ExceptionsView(state: state, bridge: bridge, profile: workspace.profile)
                case 5: Step5SheetsView(state: state)
                case 6: Step6InventoryView(state: state, bridge: bridge, profile: workspace.profile)
                case 7: Step7OutputView(state: state)
                case 8: Step8PreviewView(state: state)
                default: EmptyView()
                }
            }
            .padding(24)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private var wizardFooter: some View {
        HStack {
            PNPButton(title: "Cancel", style: .ghost) { handleCancel() }
                .accessibilityLabel("Cancel wizard and discard changes")

            if state.currentStep > 0 {
                PNPButton(title: "Back", icon: "chevron.left", action: { state.retreat() })
            }
            Spacer()
            if state.currentStep < state.totalSteps {
                PNPButton(title: "Skip step", style: .ghost) { state.advance() }
                PNPButton(title: "Continue", icon: "chevron.right", style: .gold) {
                    state.advance()
                }
                .disabled(!state.canContinue)
                .help(
                    state.currentStep == 2 && state.framework == .custom
                        && !state.canContinue
                        ? "Enter a label for your custom framework."
                        : ""
                )
            } else {
                PNPButton(title: "Save & Close", icon: "checkmark", style: .gold) { commitAndClose() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func handleCancel() {
        if state.hasUnsavedChanges {
            showCancelConfirm = true
        } else {
            onDismiss()
        }
    }

    // MARK: Helpers

    private func populateFromWorkspace() {
        let cs = workspace.configState
        state.orgName = cs.orgName
        state.logoPath = cs.logoPath
        if let c = Color(hex: cs.accentColor) { state.accentColor = c }
        if let c = Color(hex: cs.accentDark) { state.accentDark = c }
        state.outputDir = cs.outputDir
        state.timestampOutputs = cs.timestampOutputs
        // ConfigState stores keepLatestRuns as String; WizardState uses Int.
        state.keepLatestRuns = Int(cs.keepLatestRuns) ?? 10
        state.orderedSheets = workspace.sheetCatalog.flatMap(\.items)
    }

    private func commitAndClose() {
        state.isComplete = true
        state.applyTo(&workspace.configState)
        Task {
            do {
                try await workspace.saveConfig()
                onDismiss()
            } catch {
                saveError = "Could not save config.yaml: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Step 1: Org Branding

private struct Step1BrandingView: View {
    var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "building.2",
                title: "Org Branding",
                detail: "Your org name and colors appear in the report cover sheet and headers."
            )

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Organisation name")
                        PNPTextField(value: Binding(
                            get: { state.orgName },
                            set: { state.orgName = $0 }
                        ), placeholder: "Acme Corp")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "Logo file")
                        HStack(spacing: 8) {
                            PNPButton(title: "Choose logo…", icon: "photo") {
                                pickLogo()
                            }
                            .accessibilityLabel("Choose logo PNG file")
                            if !state.logoPath.isEmpty {
                                Text(URL(fileURLWithPath: state.logoPath).lastPathComponent)
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                                    .lineLimit(1)
                            }
                        }
                        FieldHelp(text: "PNG recommended · embedded in cover sheet")
                    }

                    HStack(spacing: 20) {
                        colorPickerField(
                            label: "Accent color",
                            color: Binding(get: { state.accentColor }, set: { state.accentColor = $0 })
                        )
                        colorPickerField(
                            label: "Accent dark",
                            color: Binding(get: { state.accentDark }, set: { state.accentDark = $0 })
                        )
                    }
                }
            }
        }
    }

    private func colorPickerField(label: String, color: Binding<Color>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label)
            HStack(spacing: 8) {
                ColorPicker("", selection: color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32, height: 28)
                    .accessibilityLabel(label)
                Text(color.wrappedValue.hexString)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png]
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in state.logoPath = url.path }
        }
    }
}

// MARK: - Step 2: Compliance Framework

private struct Step2FrameworkView: View {
    var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "checkmark.shield",
                title: "Compliance Framework",
                detail: "Labels the compliance baseline across all report sheets."
            )

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    FieldLabel(label: "Framework")
                    Picker("Framework", selection: Binding(
                        get: { state.framework },
                        set: { state.framework = $0 }
                    )) {
                        ForEach(WizardState.Framework.allCases) { fw in
                            Text(fw.rawValue).tag(fw)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)

                    if state.framework == .custom {
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel(label: "Custom framework label")
                            PNPTextField(value: Binding(
                                get: { state.customFrameworkLabel },
                                set: { state.customFrameworkLabel = $0 }
                            ), placeholder: "My Framework 1.0")
                            if state.customFrameworkLabel
                                    .trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("Enter a label for your custom framework.")
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(Theme.Colors.warn)
                            }
                        }
                        .transition(.opacity)
                    }

                    Divider().background(Theme.Hairline.standard)
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Theme.Text.tertiary)
                            .font(Theme.Fonts.label)
                        Text("Writes to \(Text("compliance.framework").font(Theme.Fonts.mono(11))) in config.yaml")
                            .font(Theme.Fonts.label)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Step 3: Surface Custom EAs

private struct Step3EAsView: View {
    var state: WizardState
    var bridge: CLIBridge
    var profile: String
    @State private var searchText: String = ""
    @State private var lastSuggestAction: String? = nil
    @State private var showUndoButton: Bool = false
    @State private var preSuggestSelection: Set<String> = []

    private var filteredEAs: [ExtensionAttribute] {
        guard !searchText.isEmpty else { return state.availableEAs }
        return state.availableEAs.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    stepIntro(
                        icon: "sparkles",
                        title: "Surface Custom EAs",
                        detail: "Pick EAs to include as dedicated sheets. Types are inferred from Jamf's data type."
                    )
                }

                Spacer()

                if let template = state.selectedTemplate {
                    suggestEAsButton(template: template)
                }
            }

            if state.isLoadingEAs {
                HStack {
                    ProgressView()
                    Text("Loading extension attributes…")
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .padding(16)
            } else if let err = state.eaLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warn)
                    Text(err)
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .padding(16)
            } else if state.availableEAs.isEmpty {
                // No error thrown — tenant genuinely has no EAs (or jamf-cli returned empty).
                Text("This tenant has no Extension Attributes configured. "
                     + "You can skip this step or add some in Jamf Pro.")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.tertiary)
                    .padding(16)
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        // Search bar
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Theme.Text.tertiary)
                                .font(Theme.Fonts.label)
                            TextField("Filter EAs…", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(Theme.Fonts.label)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.Surface.raised)

                        Divider().background(Theme.Hairline.standard)

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredEAs) { ea in
                                    eaRow(ea)
                                    Divider().background(Theme.Hairline.standard)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
            }

            if !state.selectedEAIDs.isEmpty {
                booleanPrompts
            }
        }
        .task {
            guard state.availableEAs.isEmpty, !state.isLoadingEAs else { return }
            state.isLoadingEAs = true
            state.eaLoadError = nil
            do {
                state.availableEAs = try await bridge.listExtensionAttributes(profile: profile)
                // eaLoadError stays nil — empty list shown via its own branch in the view.
            } catch {
                state.eaLoadError = "Could not load Extension Attributes: "
                    + "\(error.localizedDescription). "
                    + "Check that jamf-cli is authenticated."
            }
            state.isLoadingEAs = false
        }
    }

    private func eaRow(_ ea: ExtensionAttribute) -> some View {
        let eaID = ea.id ?? ""
        let isSelected = state.selectedEAIDs.contains(eaID)

        return Button {
            if isSelected {
                state.selectedEAIDs.remove(eaID)
            } else {
                state.selectedEAIDs.insert(eaID)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.Colors.goldBright : Theme.Text.tertiary)
                    .font(.system(size: 14))
                    .accessibilityLabel(isSelected ? "Selected" : "Not selected")

                VStack(alignment: .leading, spacing: 2) {
                    Text(ea.name ?? "—")
                        .font(Theme.Fonts.label.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    if let desc = ea.description, !desc.isEmpty {
                        Text(desc)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Text.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Pill(text: ea.inferredEAType, tone: pillTone(ea.inferredEAType))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.Colors.gold.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func pillTone(_ type: String) -> Pill.Tone {
        switch type {
        case "boolean":    return .teal
        case "date":       return .warn
        case "percentage": return .gold
        default:           return .muted
        }
    }

    @ViewBuilder
    private var booleanPrompts: some View {
        let boolEAs = state.selectedEAs().filter { $0.inferredEAType == "boolean" }
        if !boolEAs.isEmpty {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Compliant values for boolean EAs", size: 12)
                    ForEach(boolEAs) { ea in
                        let eaID = ea.id ?? ""
                        HStack {
                            Text(ea.name ?? "")
                                .font(Theme.Fonts.label)
                                .foregroundStyle(Theme.Text.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            PNPTextField(
                                value: Binding(
                                    get: { state.booleanTrueValues[eaID] ?? "" },
                                    set: { state.booleanTrueValues[eaID] = $0 }
                                ),
                                placeholder: "e.g. Enabled"
                            )
                            .frame(width: 160)
                        }
                    }
                }
            }
        }
    }

    private func suggestEAsButton(template: any ReportTemplate) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PNPButton(
                    title: "Suggest from jamf-cli",
                    icon: "terminal",
                    style: .ghost,
                    size: .sm
                ) {
                    suggestEAs(template: template)
                }
                .disabled(state.availableEAs.isEmpty || state.isLoadingEAs)
                .help(state.availableEAs.isEmpty
                      ? "No EAs available or still loading"
                      : "Suggest relevant EAs based on \(template.displayName) template")

                Button("?", action: { showEAHelp() })
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.Surface.raised))
                    .help("Show help about EA suggestions")
                    .accessibilityLabel("Show help")
            }

            if showUndoButton, let action = lastSuggestAction {
                HStack(spacing: 6) {
                    Text(action)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.secondary)
                    PNPButton(title: "Undo", style: .ghost, size: .sm) {
                        undoSuggestion()
                    }
                }
            }
        }
    }

    private func suggestEAs(template: any ReportTemplate) {
        preSuggestSelection = state.selectedEAIDs
        let suggested = CLISuggester.suggestEAs(from: state.availableEAs, template: template)

        for ea in suggested {
            if let id = ea.id {
                state.selectedEAIDs.insert(id)
            }
        }

        let addedCount = suggested.count
        lastSuggestAction = "Added \(addedCount) EAs from \(state.availableEAs.count) candidates"
        showUndoButton = true

        // Auto-hide undo button after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            showUndoButton = false
        }
    }

    private func undoSuggestion() {
        state.selectedEAIDs = preSuggestSelection
        showUndoButton = false
        lastSuggestAction = nil
    }

    private func showEAHelp() {
        // Simple alert for now - could be enhanced to popover
        let alert = NSAlert()
        alert.messageText = "EA Suggestions"
        alert.informativeText = """
        Suggests Extension Attributes relevant to your chosen template based on naming patterns.

        For example, Compliance templates look for EAs containing "audit", "compliance", "STIG".
        Security templates look for "FileVault", "Gatekeeper", "CrowdStrike".

        You can still manually select additional EAs after applying suggestions.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Step 4: Exceptions (Optional)

private struct Step4ExceptionsView: View {
    var state: WizardState
    var bridge: CLIBridge
    var profile: String

    @State private var isLoadingAudit = false
    @State private var cachedFindings: [AuditFinding] = []
    @State private var auditError: String?
    @State private var showHelp = false

    /// Which draft is currently showing the expiry-date confirm form.
    @State private var expandedDraftID: String? = nil
    /// Proposed expiry date per draft. Default: 90 days from today.
    @State private var proposedExpiries: [String: Date] = [:]

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func defaultExpiry() -> Date {
        Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    stepIntro(
                        icon: "doc.text.below.ecg",
                        title: "Exceptions (optional)",
                        detail: "Document signed-off waivers for compliance findings. This step is optional — skip if you don't have any to record yet."
                    )
                }

                Spacer()

                suggestExceptionsButton()
            }

            if !state.exceptionDrafts.isEmpty {
                draftsSection
            }

            if !state.exceptions.isEmpty {
                acceptedExceptionsSection
            }

            if state.exceptionDrafts.isEmpty && state.exceptions.isEmpty {
                emptyStateMessage
            }
        }
        .task {
            await loadCachedAuditFindings()
        }
    }

    private var emptyStateMessage: some View {
        Text("No exceptions to display. Use the suggest button to generate drafts from audit findings, or manually add entries.")
            .font(Theme.Fonts.label)
            .foregroundStyle(Theme.Text.tertiary)
            .padding(16)
    }

    private func suggestExceptionsButton() -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PNPButton(
                    title: "Suggest from audit findings",
                    icon: "terminal",
                    style: .ghost,
                    size: .sm
                ) {
                    suggestExceptions()
                }
                .disabled(cachedFindings.isEmpty || isLoadingAudit)
                .help(cachedFindings.isEmpty
                      ? "No audit findings available — run an audit first"
                      : "Suggest waivers based on high/medium severity audit findings")

                Button("?", action: { showHelp = true })
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.Surface.raised))
                    .help("Show help about exception suggestions")
                    .accessibilityLabel("Show help")
            }

            HStack(spacing: 8) {
                PNPButton(
                    title: "Add manually",
                    icon: "plus",
                    style: .ghost,
                    size: .sm
                ) {
                    state.addEmptyException()
                }
            }
        }
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
            exceptionHelpPopover
        }
    }

    private var exceptionHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exception Suggestions")
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Text.primary)

            Text("Suggested drafts are starting points based on high/medium severity audit findings. You are signing off — verify the description and date before accepting.")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Theme.Hairline.standard)

            Text("Suggested exceptions group findings by category and rule. Only findings with severity 'high', 'medium', 'critical', or 'warning' are included.")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.Surface.base)
    }

    @ViewBuilder
    private var draftsSection: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader(title: "Draft Exceptions", size: 14)
                    Spacer()
                    Pill(text: "\(state.exceptionDrafts.count) drafts", tone: .gold)
                }
                .padding(16)

                Divider().background(Theme.Hairline.standard)

                VStack(spacing: 0) {
                    ForEach(Array(state.exceptionDrafts.enumerated()), id: \.element.id) { idx, draft in
                        draftCard(draft)
                        if idx < state.exceptionDrafts.count - 1 {
                            Divider().background(Theme.Hairline.standard)
                        }
                    }
                }
            }
        }
    }

    private func draftCard(_ draft: CLISuggester.DraftException) -> some View {
        let isExpanded = expandedDraftID == draft.draftId
        let expiryBinding = Binding<Date>(
            get: { proposedExpiries[draft.draftId] ?? defaultExpiry() },
            set: { proposedExpiries[draft.draftId] = $0 }
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(draft.draftId)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.primary)
                        Pill(text: draft.severity, tone: severityTone(draft.severity))
                    }

                    Text(draft.description)
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(2)

                    if let finding = draft.linkedFinding {
                        Text("Linked: \(finding)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Text.tertiary)
                    }

                    Text("Signed off by \(draft.proposedSignedOffBy) on \(draft.proposedSignedOffDate)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }

                Spacer()

                if !isExpanded {
                    VStack(spacing: 4) {
                        PNPButton(title: "Accept", style: .gold, size: .sm) {
                            expandedDraftID = draft.draftId
                            if proposedExpiries[draft.draftId] == nil {
                                proposedExpiries[draft.draftId] = defaultExpiry()
                            }
                        }
                        PNPButton(title: "Reject", style: .ghost, size: .sm) {
                            state.rejectDraft(draft)
                        }
                    }
                }
            }

            // Inline expiry-date confirm form shown after tapping Accept.
            if isExpanded {
                Divider().background(Theme.Hairline.standard)

                VStack(alignment: .leading, spacing: 8) {
                    DatePicker(
                        "Expires",
                        selection: expiryBinding,
                        displayedComponents: .date
                    )
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.secondary)

                    HStack(spacing: 8) {
                        PNPButton(title: "Confirm", icon: "checkmark", style: .gold, size: .sm) {
                            let iso = Self.isoFormatter.string(from: expiryBinding.wrappedValue)
                            state.acceptDraft(draft, expiresDate: iso)
                            state.hasNoExpiryWarning = false
                            expandedDraftID = nil
                        }

                        PNPButton(title: "Skip expiry", style: .ghost, size: .sm) {
                            state.acceptDraft(draft, expiresDate: nil)
                            expandedDraftID = nil
                        }

                        PNPButton(title: "Cancel", style: .ghost, size: .sm) {
                            expandedDraftID = nil
                        }
                    }

                    Text("Exceptions without expiry dates may not satisfy audit requirements.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.warn)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var acceptedExceptionsSection: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader(title: "Accepted Exceptions", size: 14)
                    Spacer()
                    Pill(text: "\(state.exceptions.count) accepted", tone: .teal)
                }
                .padding(16)

                Divider().background(Theme.Hairline.standard)

                VStack(spacing: 0) {
                    ForEach(Array(state.exceptions.enumerated()), id: \.offset) { idx, exception in
                        acceptedCard(exception)
                        if idx < state.exceptions.count - 1 {
                            Divider().background(Theme.Hairline.standard)
                        }
                    }
                }
            }
        }
    }

    private func acceptedCard(_ exception: ConfigException) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.Fonts.label.weight(.semibold))
                .foregroundStyle(Theme.Colors.ok)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(exception.id)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Text.primary)
                    if exception.linkedFinding != nil {
                        Pill(text: "Linked", tone: .muted)
                    }
                }

                Text(exception.description)
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(2)

                Text("Signed off by \(exception.signedOffBy) on \(exception.signedOffDate)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }

            Spacer()

            PNPButton(title: "Remove", style: .ghost, size: .sm) {
                removeException(exception)
            }
        }
        .padding(16)
    }

    private func removeException(_ exception: ConfigException) {
        if let index = state.exceptions.firstIndex(where: { $0.id == exception.id }) {
            state.exceptions.remove(at: index)
        }
    }

    private func severityTone(_ severity: String) -> Pill.Tone {
        let s = severity.lowercased()
        switch s {
        case "critical": return .danger
        case "high": return .danger
        case "warning": return .warn
        case "medium": return .warn
        default: return .muted
        }
    }

    private func suggestExceptions() {
        let operatorName = NSFullUserName()
        let drafts = CLISuggester.suggestExceptions(from: cachedFindings, operatorName: operatorName)
        state.exceptionDrafts = drafts
    }

    private func loadCachedAuditFindings() async {
        isLoadingAudit = true
        auditError = nil

        let snapshots = await bridge.cachedJSONSnapshots(profile: profile, type: "audit", limit: 1)

        if let latest = snapshots.first {
            let decoder = JSONDecoder()
            if let findings = try? decoder.decode([AuditFinding].self, from: latest.data) {
                cachedFindings = findings
            } else {
                auditError = "Could not decode audit findings"
            }
        } else {
            auditError = "No cached audit findings available"
        }

        isLoadingAudit = false
    }
}

// MARK: - Step 5: Pick + Order Sheets

private struct Step5SheetsView: View {
    var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "list.number",
                title: "Pick & Order Sheets",
                detail: "Drag to reorder. CSV-only sheets require a Jamf Pro CSV export."
            )

            Card(padding: 0) {
                List {
                    ForEach(Array(state.orderedSheets.enumerated()), id: \.element.id) { idx, item in
                        sheetRow(item: item, position: idx + 1)
                    }
                    .onMove { src, dst in
                        state.orderedSheets.move(fromOffsets: src, toOffset: dst)
                    }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(state.orderedSheets.count) * 36 + 4, 300))
            }
        }
    }

    private func sheetRow(item: SheetItem, position: Int) -> some View {
        let isCSVOnly = item.req == "csv"
        return HStack(spacing: 10) {
            Mono(
                text: "\(position)",
                size: 11,
                color: Theme.Text.tertiary
            )
            .frame(width: 22, alignment: .trailing)

            Image(systemName: "doc")
                .font(Theme.Fonts.label)
                .foregroundStyle(isCSVOnly ? Theme.Text.tertiary : Theme.Colors.gold)

            Text(item.name)
                .font(Theme.Fonts.label)
                .foregroundStyle(isCSVOnly ? Theme.Text.tertiary : Theme.Text.primary)
                .opacity(isCSVOnly ? 0.6 : 1.0)

            Spacer()

            Pill(text: item.req.uppercased(), tone: isCSVOnly ? .muted : .teal)
                .help(isCSVOnly ? "Requires a Jamf Pro CSV export" : "Generated from jamf-cli data")

            Image(systemName: "line.3.horizontal")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Inventory field heuristic

/// Maps raw inventory key strings (camelCase / snake_case / display) to `columns.*` config keys.
enum InventoryFieldMatcher {
    static func matchColumnKey(_ rawKey: String) -> String? {
        let lower = rawKey.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let map: [String: String] = [
            "fullname": "full_name", "displayname": "full_name",
            "assettag": "asset_tag",
            "building": "building",
            "position": "position",
            "lastloggedinuser": "last_logged_in_user",
            "lastloggedinusername": "last_logged_in_user",
            "recoverylockpassword": "recovery_lock", "recoverylock": "recovery_lock",
            "batteryhealth": "battery_health", "batterylifecyclecount": "battery_health",
            "entrassoregistrationstatus": "entra_sso_status",
            "entrassoregistered": "entra_sso_status",
            // Phase 6 additions — warranty and purchase date.
            "warrantyexpires": "warranty_expires", "warrantyend": "warranty_expires",
            "hardwarewarrantyexpires": "warranty_expires",
            "purchasedate": "purchase_date", "podate": "purchase_date",
            "acquireddate": "purchase_date", "acquired": "purchase_date",
        ]
        return map[lower]
    }
}

// MARK: - Step 6: Inventory Fields

private struct Step6InventoryView: View {
    var state: WizardState
    var bridge: CLIBridge
    var profile: String
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "server.rack",
                title: "Inventory Fields",
                detail: "Select additional inventory fields to surface in the Device Inventory sheet."
            )

            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading inventory sample…")
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .padding(16)
            } else if state.availableInventoryKeys.isEmpty {
                Text("Could not load inventory sample. Ensure jamf-cli is authenticated.")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Text.tertiary)
                    .padding(16)
            } else {
                Card(padding: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.availableInventoryKeys, id: \.self) { key in
                                inventoryRow(key: key)
                                Divider().background(Theme.Hairline.standard)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
        .task {
            guard state.availableInventoryKeys.isEmpty, !isLoading else { return }
            isLoading = true
            // Fetch a single device to extract keys.
            if let data = await bridge.deviceDetail(profile: profile, deviceID: "0") {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    state.availableInventoryKeys = obj.keys.sorted()
                }
            }
            isLoading = false
        }
    }

    private func inventoryRow(key: String) -> some View {
        let isSelected = state.selectedInventoryKeys.contains(key)
        let colKey = InventoryFieldMatcher.matchColumnKey(key)

        return Button {
            if isSelected {
                state.selectedInventoryKeys.remove(key)
            } else {
                state.selectedInventoryKeys.insert(key)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.Colors.goldBright : Theme.Text.tertiary)
                    .font(.system(size: 14))
                    .accessibilityLabel(isSelected ? "Selected" : "Not selected")

                Text(key)
                    .font(Theme.Fonts.mono(11.5))
                    .foregroundStyle(Theme.Text.primary)

                Spacer()

                if let mapped = colKey {
                    Mono(text: "→ \(mapped)", size: 10, color: Theme.Text.tertiary)
                } else {
                    Mono(text: "unmapped", size: 10, color: Theme.Text.tertiary.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.Colors.gold.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 7: Output Preferences

private struct Step7OutputView: View {
    var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "folder",
                title: "Output Preferences",
                detail: "Where reports land and how they're named."
            )

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(label: "output_dir")
                        HStack(spacing: 8) {
                            PNPTextField(value: Binding(
                                get: { state.outputDir },
                                set: { state.outputDir = $0 }
                            ), mono: true)
                            PNPButton(title: "", icon: "folder", size: .md) {
                                pickOutputFolder()
                            }
                            .accessibilityLabel("Choose output folder")
                        }
                        FieldHelp(text: "Relative to config.yaml, or absolute path")
                    }

                    Divider().background(Theme.Hairline.standard)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Timestamp output filenames")
                                .font(Theme.Fonts.bodyText.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text("_2026-04-25_091418")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                        Spacer()
                        PNPToggle(isOn: Binding(
                            get: { state.timestampOutputs },
                            set: { state.timestampOutputs = $0 }
                        ))
                    }

                    Divider().background(Theme.Hairline.standard)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep latest runs")
                                .font(Theme.Fonts.bodyText.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text("Older files moved to archive")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                        Spacer()
                        EditableNumberStepper(
                            value: Binding(
                                get: { state.keepLatestRuns },
                                set: { state.keepLatestRuns = $0 }
                            ),
                            range: AppConstants.keepLatestRunsMin...AppConstants.keepLatestRunsMax,
                            help: "Older files move to the archive once this count is exceeded."
                        )
                    }
                }
            }
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in state.outputDir = url.path }
        }
    }
}

// MARK: - Step 8: Done — Preview

private struct Step8PreviewView: View {
    var state: WizardState
    @Environment(WorkspaceStore.self) private var workspace

    private var templateSummary: String {
        state.selectedTemplateName
    }

    private var enabledSheetsCount: Int {
        state.orderedSheets.filter(\.on).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "checkmark.circle",
                title: "Done — Preview",
                detail: "Review your selections below. Clicking 'Save & Close' writes config.yaml."
            )

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    summaryRow(label: "Template", value: templateSummary)
                    summaryRow(label: "Sheets enabled", value: "\(enabledSheetsCount) of \(state.orderedSheets.count)")
                    summaryRow(label: "Org name",   value: state.orgName.isEmpty ? "—" : state.orgName)
                    summaryRow(label: "Logo",       value: state.logoPath.isEmpty
                        ? "—" : URL(fileURLWithPath: state.logoPath).lastPathComponent)
                    summaryRow(label: "Framework",  value: state.resolvedFramework.isEmpty ? "—" : state.resolvedFramework)
                    summaryRow(label: "Custom EAs", value: "\(state.selectedEAIDs.count) selected")
                    summaryRow(label: "Exceptions", value: state.exceptions.isEmpty ? "none — you can add waivers later by editing config.yaml" : "\(state.exceptions.count) accepted")
                    summaryRow(label: "Output dir", value: state.outputDir)
                    summaryRow(label: "Timestamps", value: state.timestampOutputs ? "on" : "off")
                    summaryRow(label: "Keep runs",  value: "\(state.keepLatestRuns)")
                }
            }
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Theme.Fonts.label.weight(.medium))
                .foregroundStyle(Theme.Text.primary)
        }
    }
}

// MARK: - Shared helpers

private func stepIntro(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Theme.Colors.gold)
            .frame(width: 32)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Text.primary)
            Text(detail)
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Text.tertiary)
        }
    }
}

// MARK: - Step 0: Template Selection

private struct Step0TemplateView: View {
    var state: WizardState

    private let availableTemplates: [any ReportTemplate] = TemplateResolver.allTemplates

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro(
                icon: "doc.badge.gearshape",
                title: "Choose Template",
                detail: "Pick a template optimized for your audience, or start with a custom configuration."
            )

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(availableTemplates, id: \.identifier) { template in
                    templateCard(template: template)
                }

                customTemplateCard
            }
            .padding(.horizontal, 4)
        }
    }

    private func templateCard(template: any ReportTemplate) -> some View {
        let isSelected = (state.selectedTemplate?.identifier == template.identifier && !state.useCustomTemplate)

        return Button {
            selectTemplate(template)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: templateIcon(for: template))
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(isSelected ? Theme.Colors.goldBright : Theme.Colors.gold)
                        .frame(width: 32, alignment: .leading)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.goldBright)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.displayName)
                        .font(Theme.Fonts.bodyText.weight(.semibold))
                        .foregroundStyle(Theme.Text.primary)
                        .multilineTextAlignment(.leading)

                    Text(template.description)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                Spacer()

                HStack {
                    Pill(text: template.recommendedSchedule.rawValue.uppercased(), tone: .muted)
                    Spacer()
                    Pill(text: "\(template.includedSheets.count) sheets", tone: .teal)
                }
            }
            .padding(16)
            .frame(minHeight: 140)
            .background(isSelected ? Theme.Colors.gold.opacity(0.08) : Theme.Surface.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Theme.Colors.gold : Theme.Hairline.standard, lineWidth: isSelected ? 2 : 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel("\(template.displayName) template")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var customTemplateCard: some View {
        let isSelected = state.useCustomTemplate

        return Button {
            selectCustom()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(isSelected ? Theme.Colors.goldBright : Theme.Text.tertiary)
                        .frame(width: 32, alignment: .leading)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.goldBright)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom")
                        .font(Theme.Fonts.bodyText.weight(.semibold))
                        .foregroundStyle(Theme.Text.primary)
                        .multilineTextAlignment(.leading)

                    Text("Start with a blank configuration and manually select all settings.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                Spacer()

                HStack {
                    Pill(text: "MANUAL", tone: .muted)
                    Spacer()
                    Pill(text: "all sheets", tone: .teal)
                }
            }
            .padding(16)
            .frame(minHeight: 140)
            .background(isSelected ? Theme.Colors.gold.opacity(0.08) : Theme.Surface.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Theme.Colors.gold : Theme.Hairline.standard, lineWidth: isSelected ? 2 : 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel("Custom template")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func selectTemplate(_ template: any ReportTemplate) {
        state.selectedTemplate = template
        state.useCustomTemplate = false
        TemplateApplier.apply(template, to: state)
    }

    private func selectCustom() {
        state.selectedTemplate = nil
        state.useCustomTemplate = true
        // Don't apply any template defaults for custom
    }

    private func templateIcon(for template: any ReportTemplate) -> String {
        switch template.identifier {
        case "executive": return "person.3"
        case "operational": return "gearshape.2"
        case "compliance": return "checkmark.shield"
        case "asset": return "building.2"
        case "security-posture": return "shield"
        default: return "doc"
        }
    }
}

// MARK: - Color + Hex helpers

extension Color {
    /// Initialise from a CSS hex string: "#RRGGBB" or "#RGB".
    init?(hex: String) {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let full: String
        switch raw.count {
        case 3:  full = raw.map { "\($0)\($0)" }.joined()
        case 6:  full = raw
        default: return nil
        }
        guard let value = UInt64(full, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Returns a "#RRGGBB" string for use in config.yaml.
    var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent   * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - WizardChangeObservers

/// Observes wizard state mutations and flips `hasUnsavedChanges`.
/// Extracted into its own modifier so the SwiftUI type-checker does not time out
/// trying to resolve a long chain of `.onChange` calls inside the wizard body.
private struct WizardChangeObservers: ViewModifier {
    @Bindable var state: WizardState

    func body(content: Content) -> some View {
        content
            .onChange(of: state.useCustomTemplate) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.orgName) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.logoPath) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.framework) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.customFrameworkLabel) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.selectedEAIDs) { _, _ in state.hasUnsavedChanges = true }
            .modifier(WizardChangeObserversExtension(state: state))
    }
}

/// Second part of change observers to avoid compiler timeout
private struct WizardChangeObserversExtension: ViewModifier {
    @Bindable var state: WizardState

    func body(content: Content) -> some View {
        content
            .onChange(of: state.outputDir) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.timestampOutputs) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.keepLatestRuns) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.exceptions) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.exceptionDrafts) { _, _ in state.hasUnsavedChanges = true }
            .onChange(of: state.hasNoExpiryWarning) { _, _ in state.hasUnsavedChanges = true }
    }
}
