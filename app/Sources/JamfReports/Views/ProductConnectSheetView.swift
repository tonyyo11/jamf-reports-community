import AppKit
import SwiftUI

// MARK: - ProductConnectSheetView

/// Sheet presented from SourcesView (and any other post-onboarding entry point) to
/// connect Jamf Protect or Jamf School to the active workspace.
///
/// Uses the same `OnboardingFlow` methods (`registerProtectProfile` /
/// `registerSchoolProfile`) and applies the same security model:
/// secrets are delivered via `SecureSecretField.onTextChange` + `onFinalize`,
/// finalization is forced by `NSApp.keyWindow?.makeFirstResponder(nil)` before any
/// async credential read, and credentials are cleared via `defer` in the flow.
struct ProductConnectSheetView: View {
    let product: SourcesView.ProductConnectSheet
    let profileSlug: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var flow = OnboardingFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: productIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.goldBright)
                    Text(productTitle)
                        .font(Theme.Fonts.serif(22, weight: .bold))
                        .foregroundStyle(Theme.Colors.fg)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                Text(productSubtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))

            Divider().background(Theme.Colors.hairlineStrong)

            ScrollView {
                if product == .protect {
                    protectForm
                } else {
                    schoolForm
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Theme.Colors.winBG)
        .onAppear {
            // Pre-fill profile name default based on product type.
            if product == .protect, flow.protectProfileName.isEmpty {
                flow.protectProfileName = "protect"
            } else if product == .school, flow.schoolProfileName.isEmpty {
                flow.schoolProfileName = "school"
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
                    Text("Create API client credentials in your Jamf Protect console under Settings → API Clients.")
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
                        FieldHelp(text: "Lowercase letters, numbers, hyphens, and underscores.")
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
                                if flow.protectConnected { dismiss() }
                            }
                        }
                        .disabled(!protectCanConnect)

                        PNPButton(title: "Cancel", style: .neutral, size: .md) {
                            dismiss()
                        }
                    }

                    if flow.protectConnected {
                        Pill(text: "CONNECTED", tone: .teal, icon: "checkmark")
                    }
                }
            }
        }
        .padding(20)
    }

    // MARK: - School form

    private var schoolForm: some View {
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
                    Text("Find your Network ID at Devices → Enroll Device(s). Generate an API key at Organization → Settings → API.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "School URL")
                        PNPTextField(
                            value: schoolURLBinding,
                            placeholder: "https://yourorg.jamfcloud.com"
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Profile name")
                        PNPTextField(value: schoolProfileNameBinding, placeholder: "school", mono: true)
                        FieldHelp(text: "Lowercase letters, numbers, hyphens, and underscores.")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Network ID")
                            PNPTextField(value: schoolNetworkIDBinding, mono: true)
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
                            title: flow.isConnectingSchool ? "Connecting…" : "Connect",
                            icon: "graduationcap.fill",
                            style: .gold,
                            size: .md
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            Task {
                                await flow.registerSchoolProfile()
                                if flow.schoolConnected { dismiss() }
                            }
                        }
                        .disabled(!schoolCanConnect)

                        PNPButton(title: "Cancel", style: .neutral, size: .md) {
                            dismiss()
                        }
                    }

                    if flow.schoolConnected {
                        Pill(text: "CONNECTED", tone: .teal, icon: "checkmark")
                    }
                }
            }
        }
        .padding(20)
    }

    // MARK: - Helpers

    private var productIcon: String {
        product == .protect ? "shield.lefthalf.filled" : "graduationcap.fill"
    }

    private var productTitle: String {
        product == .protect ? "Connect Jamf Protect" : "Connect Jamf School"
    }

    private var productSubtitle: String {
        product == .protect
            ? "Extend the active workspace with Protect alert and analytics data."
            : "Extend the active workspace with School device and user data."
    }

    private var protectCanConnect: Bool {
        !flow.isConnectingProtect
        && !flow.protectURL.trimmed.isEmpty
        && !flow.protectProfileName.trimmed.isEmpty
        && !flow.protectClientID.trimmed.isEmpty
        && (!flow.protectClientSecret.isEmpty || flow.protectSecretFieldHasText)
    }

    private var schoolCanConnect: Bool {
        !flow.isConnectingSchool
        && !flow.schoolURL.trimmed.isEmpty
        && !flow.schoolProfileName.trimmed.isEmpty
        && !flow.schoolNetworkID.trimmed.isEmpty
        && (!flow.schoolAPIKey.isEmpty || flow.schoolAPIKeyFieldHasText)
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
    private var schoolURLBinding: Binding<String> {
        Binding(get: { flow.schoolURL }, set: { flow.schoolURL = $0 })
    }
    private var schoolProfileNameBinding: Binding<String> {
        Binding(get: { flow.schoolProfileName }, set: { flow.schoolProfileName = $0 })
    }
    private var schoolNetworkIDBinding: Binding<String> {
        Binding(get: { flow.schoolNetworkID }, set: { flow.schoolNetworkID = $0 })
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
