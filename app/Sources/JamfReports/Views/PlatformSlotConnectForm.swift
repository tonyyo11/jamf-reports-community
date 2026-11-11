import AppKit
import SwiftUI

/// The Platform API card's "Connect new" disclosure in the Add sheet (D25): registers a new
/// Platform profile and names it in this workspace's `platform` slot. No workspace is made.
struct PlatformSlotConnectForm: View {
    /// Runs after a profile was added, so the sheet reloads its lists.
    var onAdded: (String) -> Void
    var disabled: Bool

    @State private var model: PlatformSlotConnectModel
    @State private var expanded = false
    /// Lifted so the sheet can refuse to close while a registration runs.
    @Binding var isRunning: Bool

    init(
        workspace: String, existingProfiles: @escaping () -> [String], disabled: Bool,
        isRunning: Binding<Bool>,
        onAdded: @escaping (String) -> Void
    ) {
        self.disabled = disabled
        _isRunning = isRunning
        self.onAdded = onAdded
        _model = State(initialValue: PlatformSlotConnectModel(
            workspace: workspace,
            dependencies: .live(existingProfiles: existingProfiles)))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if disabled {
                    Text(DemoData.liveOnlyHelp).font(.caption).foregroundStyle(Theme.Colors.fg2)
                }
                fields.disabled(disabled || model.isRunning)
                if let outcome = model.outcome { outcomeText(outcome) }
                HStack {
                    Button(model.isRunning ? L("Connecting…") : L("Connect")) {
                        guard !disabled else { return }
                        Task { await connect() }
                    }
                    .disabled(disabled || !model.canConnect)
                    .accessibilityLabel("Connect new Platform API profile to \(model.workspace)")
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Connect new").font(.subheadline.weight(.semibold))
        }
        .onDisappear { model.clearSecret() }
    }

    private func connect() async {
        // Ends the secret field's editing, so it hands its bytes over and empties itself; a
        // click on Connect does not take focus, and the field kept showing dots after a refusal.
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard model.canConnect else { return }
        // Set here, not mirrored from the model: a form that leaves the sheet mid-connect (New
        // workspace) must still reset the sheet's flag, or the sheet can never close.
        isRunning = true
        defer { isRunning = false }
        await model.connect()
        if case .added(let text) = model.outcome { onAdded(text) }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(label: L("Profile name"))
                PNPTextField(value: $model.profileName, mono: true)
                if let problem = model.nameProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.Colors.danger)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(label: L("Region"))
                Picker("", selection: $model.region) {
                    ForEach(GatewayRegion.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Platform API region")
            }
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(label: L("Platform API scope"))
                SegmentedControl(
                    selection: $model.scope,
                    options: OnboardingFlow.PlatformScope.allCases.map { ($0, $0.label, nil) })
                Text(OnboardingFlow.PlatformScope.caption)
                    .font(.caption).foregroundStyle(Theme.Colors.fg2)
                FieldLabel(label: model.scope.idFieldLabel)
                PNPTextField(
                    value: $model.scopeID,
                    placeholder: model.scope == .environment
                        ? "your-environment-id" : "your-tenant-id", mono: true)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: L("Client ID"))
                    PNPTextField(value: $model.clientID, mono: true)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: L("Client Secret"))
                    SecureSecretField(
                        placeholder: L("Platform client secret"),
                        onTextChange: { model.secretFieldHasText = $0 },
                        onFinalize: { model.setSecret($0) }
                    )
                    .frame(height: 28)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func outcomeText(_ outcome: PlatformSlotConnectModel.Outcome) -> some View {
        switch outcome {
        case .added(let text):
            Text(text).font(.caption).foregroundStyle(Theme.Colors.ok)
        case .refused(let text), .failed(let text):
            Text(text).font(.caption).foregroundStyle(Theme.Colors.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
