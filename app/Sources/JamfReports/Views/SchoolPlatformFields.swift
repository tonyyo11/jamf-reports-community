import SwiftUI

/// The Platform API fields of Jamf School setup, in onboarding's School step and the School
/// form of Update credentials. `school setup` writes them onto the School profile itself.
struct SchoolPlatformFields: View {
    let flow: OnboardingFlow
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { flow.schoolPlatformEnabled },
                set: { flow.schoolPlatformEnabled = $0 }
            )) {
                Text("Do you also have Platform API configured for Jamf School?")
                    .font(.footnote.weight(.medium))
            }
            .toggleStyle(.switch)
            Text(SchoolPlatformCheck.experimentalNote)
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            if flow.schoolPlatformEnabled { fields }
            if let check = flow.schoolPlatformCheck { Self.banner(check) }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(label: L("Region"))
                Picker("", selection: Binding(
                    get: { flow.schoolPlatformRegion },
                    set: { flow.schoolPlatformRegion = $0 }
                )) {
                    ForEach(GatewayRegion.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Platform API region")
            }
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(label: L("Tenant ID"))
                PNPTextField(value: text(\.schoolPlatformTenantID), placeholder: "your-tenant-id",
                             mono: true)
                if tenantIDProblem {
                    Text(OnboardingFlow.scopeIDProblemText)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.danger)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: L("Client ID"))
                    PNPTextField(value: text(\.schoolPlatformClientID),
                                 placeholder: L("Platform client ID"), mono: true)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: L("Client Secret"))
                    SecureSecretField(
                        placeholder: L("Platform client secret"),
                        onTextChange: { flow.schoolPlatformSecretFieldHasText = $0 }
                    ) { data in
                        flow.setSchoolPlatformClientSecret(data)
                    }
                    .frame(height: 28)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var tenantIDProblem: Bool {
        let id = flow.schoolPlatformTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !ConnectionEnvironments.isUsableID(id)
    }

    private func text(
        _ keyPath: ReferenceWritableKeyPath<OnboardingFlow, String>
    ) -> Binding<String> {
        Binding(get: { flow[keyPath: keyPath] }, set: { flow[keyPath: keyPath] = $0 })
    }

    static func banner(_ check: SchoolPlatformCheck.Verdict) -> some View {
        InlineBanner(
            icon: check.isAccepted ? "checkmark.seal" : "exclamationmark.triangle.fill",
            tone: check.isAccepted ? .info : .warn
        ) {
            Text(verbatim: check.message)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
