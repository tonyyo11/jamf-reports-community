import AppKit
import SwiftUI

// MARK: - ProductConnectSheetView

/// Sheet presented from SourcesView (and any other post-onboarding entry point) to
/// connect Jamf Protect to the active workspace. Jamf School is not offered here: it gets
/// its own workspace, because `school_cli` turns the whole workspace that records it into a
/// School one.
///
/// Uses the same `OnboardingFlow` method (`registerProtectProfile`) and applies the same
/// security model:
/// secrets are delivered via `SecureSecretField.onTextChange` + `onFinalize`,
/// finalization is forced by `NSApp.keyWindow?.makeFirstResponder(nil)` before any
/// async credential read, and credentials are cleared via `defer` in the flow.
struct ProductConnectSheetView: View {
    let profileSlug: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var flow = OnboardingFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.goldBright)
                    Text("Connect Jamf Protect")
                        .font(Theme.Fonts.serif(22, weight: .bold))
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    Button {
                        flow.clearAllSecrets()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                Text("Extend the active workspace with Protect alert and analytics data.")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))

            Divider().background(Theme.Colors.hairlineStrong)

            ScrollView {
                protectForm
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Theme.Colors.winBG)
        // Esc dismisses. Hidden zero-size button with .cancelAction is the
        // canonical SwiftUI pattern (see OverviewView's drill-down dismissal).
        .background {
            Button("", action: { flow.clearAllSecrets(); dismiss() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            if flow.protectProfileName.isEmpty {
                flow.protectProfileName = "protect"
            }
            // Set the main profile so config writes target the right workspace.
            flow.profileName = profileSlug
        }
    }

    // MARK: - Protect form

    private var protectForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Theme.Colors.goldBright)
                        Text("Before continuing:")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg)
                    }
                    Text("""
                        Create API client credentials in your Jamf Protect console under \
                        Administrative → API Clients.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Protect URL")
                        PNPTextField(
                            value: protectURLBinding,
                            placeholder: "https://yourorg.protect.jamfcloud.com"
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Profile name")
                        PNPTextField(value: protectProfileNameBinding, placeholder: "protect", mono: true)
                        FieldHelp(text: "Any name without line breaks or spaces at either end.")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client ID")
                            PNPTextField(value: protectClientIDBinding, mono: true)
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
                            title: flow.isConnectingProtect ? "Connecting…" : "Connect",
                            icon: "shield.lefthalf.filled",
                            style: .gold,
                            size: .md
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            Task {
                                await flow.registerProtectProfile()
                                // A note stays on screen until the sheet is closed.
                                if flow.protectConnected, flow.protectConfigNote == nil {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!protectCanConnect)

                        PNPButton(
                            title: flow.protectConnected ? "Done" : "Cancel",
                            style: .neutral, size: .md
                        ) {
                            flow.clearAllSecrets()
                            dismiss()
                        }
                    }

                    connectedStatus(flow.protectConnected, note: flow.protectConfigNote)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Helpers

    /// CONNECTED, and under it what recording the connection in config.yaml did not keep.
    @ViewBuilder
    private func connectedStatus(_ connected: Bool, note: String?) -> some View {
        if connected {
            Pill(text: "CONNECTED", tone: .teal, icon: "checkmark")
        }
        if let note {
            Text(note)
                .font(.caption)
                .foregroundStyle(Theme.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protectCanConnect: Bool {
        !flow.isConnectingProtect
        && !flow.protectURL.trimmed.isEmpty
        && !flow.protectProfileName.trimmed.isEmpty
        && !flow.protectClientID.trimmed.isEmpty
        && (!flow.protectClientSecret.isEmpty || flow.protectSecretFieldHasText)
    }

    // Bindings into the flow's observable properties.
    private var protectURLBinding: Binding<String> {
        Binding(get: { flow.protectURL }, set: { flow.protectURL = $0 })
    }
    private var protectProfileNameBinding: Binding<String> {
        Binding(get: { flow.protectProfileName }, set: { flow.protectProfileName = $0 })
    }
    private var protectClientIDBinding: Binding<String> {
        Binding(get: { flow.protectClientID }, set: { flow.protectClientID = $0 })
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
