import AppKit
import SwiftUI

// MARK: - ReauthenticateSheet

/// Sheet presented from SourcesView's Connection Health card to update an
/// EXISTING Jamf Pro profile's jamf-cli credentials — the in-app equivalent of
/// `jamf-cli pro setup`. Needed when a profile was created with placeholder
/// credentials (the CSV-first path), an API client expired, or a secret was
/// rotated.
///
/// Reuses `OnboardingFlow` end to end: the same `registerJamfCLIProfile`
/// (`jamf-cli config add-profile`, which is idempotent for an existing profile
/// name and overwrites its stored credentials) followed by the same
/// `validateRegisteredProfile` (`jamf-cli config validate`) the onboarding
/// Validate step runs. The security model is identical to onboarding and
/// `ProductConnectSheetView`: secrets are delivered via
/// `SecureSecretField.onTextChange` + `onFinalize`, finalization is forced by
/// `NSApp.keyWindow?.makeFirstResponder(nil)` before any async credential read,
/// the secret is passed to jamf-cli over stdin (PTY) and wiped via `defer` in
/// the flow, and failure output is redacted before display. Nothing is
/// persisted by the app: `config add-profile` writes only to jamf-cli's own
/// credential store, not the workspace `config.yaml`.
///
/// On a Jamf School workspace it shows the School form instead and re-runs `jamf-cli school
/// setup` through `OnboardingFlow.registerSchoolProfile`, the onboarding School path.
struct ReauthenticateSheet: View {
    /// The existing profile slug whose credentials are being updated.
    let profileSlug: String
    /// The profile's currently-recorded server URL, if any (cheap prefill).
    var prefillURL: String = ""
    /// The profile's currently-recorded auth method, if any (selects the form).
    var prefillAuthMethod: String = ""
    /// A Jamf School workspace: the School form, never the Jamf Pro connection types.
    var isSchool: Bool = false
    /// Called once when credentials were (re)written, so the caller can re-run
    /// its connection-health probe. Not called on a pure cancel.
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var flow = OnboardingFlow()
    @State private var didPrefill = false

    // MARK: - Pure gating / prefill helpers (unit-tested)

    enum Form: Equatable { case school, oauth2, platformGateway }

    /// The form to show: School for a School workspace whatever its recorded auth method,
    /// else the gateway form for a `platform` profile and OAuth2 for anything else.
    nonisolated static func form(isSchool: Bool, authMethod: String) -> Form {
        if isSchool { return .school }
        return prefersPlatformGateway(authMethod: authMethod) ? .platformGateway : .oauth2
    }

    /// Whether the School "Verify & save" action may run. Mirrors onboarding's School step.
    nonisolated static func canVerifySchool(
        isBusy: Bool, urlValid: Bool, networkID: String, hasKey: Bool
    ) -> Bool {
        let idFilled = !networkID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isBusy && urlValid && idFilled && hasKey
    }

    /// Chooses the form to prefill from the profile's recorded auth method.
    /// `platform` (jamf-cli's Platform Gateway auth method, `JamfCLIAuthMethod`) selects the
    /// gateway form; everything else defaults to OAuth2.
    nonisolated static func prefersPlatformGateway(authMethod: String) -> Bool {
        JamfCLIAuthMethod(raw: authMethod)?.isPlatform == true
    }

    /// Whether the OAuth2 "Verify & save" action may run. Mirrors
    /// `OnboardingFlow.canAdvance`'s authenticate/oauth2 branch.
    nonisolated static func canVerifyOAuth2(
        isBusy: Bool, urlValid: Bool, clientID: String, hasSecret: Bool
    ) -> Bool {
        let idFilled = !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isBusy && urlValid && idFilled && hasSecret
    }

    /// Whether the Platform Gateway "Verify & save" action may run. Mirrors
    /// `OnboardingFlow.canAdvance`'s authenticate/platformGateway branch.
    nonisolated static func canVerifyPlatform(
        isBusy: Bool, gatewayURLValid: Bool, scopeID: String, clientID: String, hasSecret: Bool
    ) -> Bool {
        let scopeFilled = ConnectionEnvironments.isUsableID(
            scopeID.trimmingCharacters(in: .whitespacesAndNewlines))
        let idFilled = !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isBusy && gatewayURLValid && scopeFilled && idFilled && hasSecret
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Colors.hairlineStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isSchool {
                        schoolForm
                        schoolResultSection
                    } else {
                        connectionTypePicker
                        if flow.proConnectionType == .oauth2 {
                            oauth2Form
                        } else {
                            platformGatewayForm
                        }
                        resultSection
                    }
                }
                .padding(20)
            }
            Divider().background(Theme.Colors.hairlineStrong)
            footer
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(Theme.Colors.winBG)
        // Esc dismisses (pure cancel unless credentials were saved). Hidden
        // zero-size button with .cancelAction is the canonical SwiftUI pattern
        // (mirrors ProductConnectSheetView / OverviewView's drill-down dismissal).
        .background {
            Button("", action: { close() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear(perform: prefillOnce)
        // Off the main actor, and after the first layout: see `OnboardingFlow.init`.
        .task { await flow.refreshJamfCLIStatus() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Colors.goldBright)
                Text("Update credentials")
                    .font(Theme.Fonts.serif(22, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 4) {
                Text("Re-register jamf-cli credentials for profile")
                Text(profileSlug).foregroundStyle(Theme.Colors.goldBright)
            }
            .font(.callout)
            .foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))
    }

    // MARK: - Connection type

    private var connectionTypePicker: some View {
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
                .disabled(isBusy)
                .accessibilityLabel("Connection type")
            }
        }
    }

    // MARK: - OAuth2 form

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
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Platform Gateway form

    private var platformGatewayForm: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                GatewayRegionPicker(flow: flow)
                    .disabled(isBusy)

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(label: "Platform API scope")
                    SegmentedControl(
                        selection: Binding(
                            get: { flow.platformScope },
                            set: { flow.choosePlatformScope($0) }
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
            }
        }
    }

    // MARK: - Jamf School form

    private var schoolForm: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Find your Network ID at Devices → Enroll Device(s). Generate an API key at "
                     + "Organization → Settings → API.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: "Jamf School URL")
                    PNPTextField(
                        value: binding(\.schoolURL), placeholder: "https://yourorg.jamfcloud.com")
                    validationLine(
                        ok: flow.isSchoolURLValid,
                        text: "An https:// address with a host; a trailing /api is removed")
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Network ID")
                        PNPTextField(
                            value: binding(\.schoolNetworkID), placeholder: "Network ID",
                            mono: true)
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

                Text("Saving re-runs jamf-cli's School setup for this profile: it replaces the "
                     + "stored URL, Network ID and API key, removes any Platform API access added "
                     + "to the profile outside this app, and makes it jamf-cli's default profile.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var schoolResultSection: some View {
        if let error = flow.schoolConnectionError {
            InlineBanner(icon: "exclamationmark.triangle.fill", tone: .warn) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if flow.schoolConnected {
            Pill(text: "CREDENTIALS SAVED", tone: .teal, icon: "checkmark")
            if let note = flow.schoolConfigNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Result / validation output

    @ViewBuilder
    private var resultSection: some View {
        if let error = flow.lastError {
            InlineBanner(icon: "exclamationmark.triangle.fill", tone: .warn) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let check = flow.connectionCheck {
            ConnectionCheckBanner(verdict: check, tenantLevel: flow.platformScope == .tenant)
        }

        if flow.connectionValidated {
            Pill(text: "CREDENTIALS VERIFIED & SAVED", tone: .teal, icon: "checkmark")
        } else if flow.profileRegistered {
            // Credentials were written, but validation didn't pass — keep the
            // sheet open so the operator can correct and retry.
            Pill(text: "SAVED — VALIDATION FAILED, RETRY", tone: .warn, icon: "exclamationmark")
        }

        if !flow.validationOutput.isEmpty {
            validationLog
        }
    }

    private var validationLog: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Theme.Colors.gold)
                        .font(.system(size: 13))
                    Mono(text: "jamf-cli config validate", size: 12, color: Theme.Colors.fg2)
                    Spacer()
                    if let exit = flow.validationExitCode {
                        Pill(text: "EXIT \(exit)", tone: exit == 0 ? .teal : .danger)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().background(Theme.Colors.hairlineStrong)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(flow.validationOutput) { line in
                        Text(line.text)
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(color(for: line.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .background(Theme.Colors.codeBG)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            PNPButton(
                title: flow.profileRegistered || flow.schoolConnected ? "Close" : "Cancel",
                style: .neutral,
                size: .md
            ) {
                close()
            }
            .disabled(isBusy)

            Spacer()

            PNPButton(
                title: isBusy ? "Verifying\u{2026}" : "Verify & save",
                icon: isBusy ? "hourglass" : "checkmark.shield",
                style: .gold,
                size: .md
            ) {
                verifyAndSave()
            }
            .disabled(!canVerify)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(isBusy ? "Verifying" : "Verify and save credentials")
        }
        .padding(14)
    }

    // MARK: - State

    private var isBusy: Bool {
        flow.isRegisteringProfile || flow.isValidatingConnection || flow.isConnectingSchool
    }

    private var canVerify: Bool {
        // The Platform API scope default is set when the jamf-cli probe answers.
        guard !flow.isCheckingJamfCLI else { return false }
        if isSchool {
            return Self.canVerifySchool(
                isBusy: isBusy,
                urlValid: flow.isSchoolURLValid,
                networkID: flow.schoolNetworkID,
                hasKey: !flow.schoolAPIKey.isEmpty || flow.schoolAPIKeyFieldHasText
            )
        }
        switch flow.proConnectionType {
        case .oauth2:
            return Self.canVerifyOAuth2(
                isBusy: isBusy,
                urlValid: flow.isJamfURLValid,
                clientID: flow.clientID,
                hasSecret: !flow.clientSecret.isEmpty || flow.secretFieldHasText
            )
        case .platformGateway:
            return Self.canVerifyPlatform(
                isBusy: isBusy,
                gatewayURLValid: flow.isGatewayURLValid,
                scopeID: flow.platformScopeID,
                clientID: flow.platformClientID,
                hasSecret: !flow.platformClientSecret.isEmpty || flow.platformSecretFieldHasText
            )
        }
    }

    // MARK: - Actions

    private func prefillOnce() {
        guard !didPrefill else { return }
        didPrefill = true
        flow.profileName = profileSlug
        let stored = prefillURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.form(isSchool: isSchool, authMethod: prefillAuthMethod) {
        case .school:
            flow.schoolProfileName = profileSlug
            flow.schoolURL = stored
        case .platformGateway:
            flow.proConnectionType = .platformGateway
            if let url = GatewayRegion.startingURL(fromStored: prefillURL) {
                flow.gatewayURL = url
            }
        case .oauth2:
            flow.proConnectionType = .oauth2
            flow.jamfURL = stored
        }
    }

    private func verifyAndSave() {
        // Force finalization of any focused secure field before the async work
        // reads the secret. AppKit processes makeFirstResponder synchronously so
        // controlTextDidEndEditing fires before the Task body runs. (Mirrors the
        // onboarding Authenticate step and ProductConnectSheetView.)
        NSApp.keyWindow?.makeFirstResponder(nil)
        flow.lastError = nil
        if isSchool {
            // The School profile is the workspace's own (`connectSchoolAsPrimary`).
            Task { await flow.connectSchoolAsPrimary() }
            return
        }
        Task {
            do {
                try await flow.registerJamfCLIProfile()
                // Same validation the onboarding Validate step runs. It sets
                // connectionValidated / validationExitCode / lastError itself.
                await flow.validateRegisteredProfile()
            } catch {
                flow.lastError = error.localizedDescription
            }
        }
    }

    /// Single dismissal path. Notifies the caller to re-probe connection health
    /// only when credentials were actually (re)written. Wipes any typed-but-
    /// unsubmitted secret — the register defer only runs when Verify was
    /// pressed, so a cancel would otherwise release the plaintext un-zeroed.
    private func close() {
        flow.clearAllSecrets()
        if flow.profileRegistered || flow.schoolConnected { onSaved?() }
        dismiss()
    }

    // MARK: - Small helpers

    private func validationLine(ok: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(ok ? Theme.Chart.tealLight : Theme.Colors.danger)
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
