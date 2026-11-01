import AppKit
import SwiftUI

/// Add environments and Update credentials for all: one client ID and secret, typed once, for
/// every environment of a Connection. The registration, secret handling and per-ID check are
/// `ConnectionCredentialsModel`'s (and through it onboarding's); this view only collects the
/// input and lists the result per ID. It cannot be closed while a run is in progress.
struct ConnectionCredentialsSheet: View {
    @State var model: ConnectionCredentialsModel
    /// Called when the sheet closes; the flag says whether anything was registered or added.
    var onFinished: (Bool) -> Void
    /// Opens the Add sheet on Jamf School for an ID no Jamf Pro answers for.
    var onSetUpSchool: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Colors.hairlineStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.hasRun { inputCard }
                    if let error = model.runError { errorBanner(error) }
                    if !model.rows.isEmpty { resultsCard }
                }
                .padding(20)
            }
            Divider().background(Theme.Colors.hairlineStrong)
            footer
        }
        .frame(minWidth: 540, minHeight: 480)
        .background(Theme.Colors.winBG)
        .interactiveDismissDisabled(model.isRunning)
        .background {
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Header

    private var title: String {
        model.mode == .addEnvironments ? L("Add environments") : L("Update credentials for all")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))
    }

    private var subtitle: String {
        switch model.mode {
        case .addEnvironments:
            L("Each environment gets its own jamf-cli profile in the connection \(model.connection.name), all with the client ID and secret below. The app does not keep the secret.")
        case .updateAll:
            L("Registers the client ID and secret again for all \(model.connection.members.count) profiles in \(model.connection.name), each with its own ID, and checks each one.")
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                if let problem = model.gatewayProblem { errorBanner(problem) }
                if model.mode == .addEnvironments { idsEditor }
                credentialFields
            }
        }
        .disabled(model.isRunning)
    }

    private var idsEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(label: model.scope == .tenant ? L("Tenant IDs") : L("Environment IDs"))
            TextEditor(text: $model.idsText)
                .font(Theme.Fonts.mono(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 90, maxHeight: 140)
                .background(Color.white.opacity(0.05), in: editorShape)
                .overlay(editorShape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
                .accessibilityLabel("Environment IDs, one per line")
            Text("One per line: the ID, then an optional label (for example \"<id> Production\"). The label names the profile and the sidebar entry.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            planPreview
        }
    }

    private var editorShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
    }

    @ViewBuilder
    private var planPreview: some View {
        let planned = model.plan
        if !planned.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(planned.enumerated()), id: \.offset) { _, item in
                    planLine(item)
                }
            }
            .padding(.top, 4)
        }
    }

    private func planLine(_ item: ConnectionEnvironments.Planned) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.refusal == nil ? "arrow.right" : "xmark.circle.fill")
                .foregroundStyle(item.refusal == nil
                    ? Theme.Text.tertiary(contrast) : Theme.Colors.danger)
                .font(.caption)
            Text(item.previewText)
                .font(.caption)
                .foregroundStyle(item.refusal == nil
                    ? Theme.Colors.fg2 : Theme.Colors.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialFields: some View {
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

    // MARK: - Results

    private var resultsCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    resultRow(row)
                    if row.id != model.rows.last?.id {
                        Divider().background(Theme.Colors.hairlineStrong)
                    }
                }
            }
        }
    }

    private func resultRow(_ row: ConnectionCredentialsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Pill(text: row.isSuccess ? L("OK") : L("NOT DONE"),
                     tone: row.isSuccess ? .teal : .warn,
                     icon: row.isSuccess ? "checkmark" : "exclamationmark")
                Text(row.label).font(.body.weight(.medium)).foregroundStyle(Theme.Colors.fg)
                Mono(text: row.profile, size: 11, color: Theme.Colors.fg2)
                Spacer()
            }
            Text(row.message(tenantLevel: model.scope == .tenant))
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if row.suggestsJamfSchool {
                PNPButton(title: L("Add a workspace\u{2026}"), icon: "graduationcap",
                          size: .sm, action: schoolAction)
            }
        }
        .padding(14)
    }

    private func errorBanner(_ text: String) -> some View {
        InlineBanner(icon: "exclamationmark.triangle.fill", tone: .warn) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            PNPButton(title: model.hasRun ? L("Close") : L("Cancel"), style: .neutral, size: .md,
                      action: close)
                .disabled(model.isRunning)
            Spacer()
            if !model.hasRun {
                PNPButton(
                    title: model.isRunning ? L("Working\u{2026}") : runTitle,
                    icon: model.isRunning ? "hourglass" : "checkmark.shield",
                    style: .gold, size: .md, action: run
                )
                .disabled(!model.canRun)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private var runTitle: String {
        model.mode == .addEnvironments ? L("Register & check") : L("Update all")
    }

    // MARK: - Actions

    private func run() {
        // Finalizes a focused secret field before the run reads the secret.
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { await model.run() }
    }

    /// The one dismissal path. Wipes a secret that was typed and never submitted.
    private func close() {
        guard !model.isRunning else { return }
        model.close()
        onFinished(model.didChange)
        dismiss()
    }

    private func schoolAction() {
        guard !model.isRunning else { return }
        model.close()
        onFinished(model.didChange)
        dismiss()
        onSetUpSchool()
    }
}
