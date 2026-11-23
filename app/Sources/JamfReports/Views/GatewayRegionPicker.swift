import SwiftUI

/// The Jamf Platform API region: United States, Europe, Asia-Pacific or Other, which takes a
/// gateway host. A stored gateway URL that is none of the three shows as Other with its host.
struct GatewayRegionPicker: View {
    let flow: OnboardingFlow
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(label: L("Region"))
            Picker("", selection: selection) {
                ForEach(GatewayRegion.allCases) { region in
                    Text(region.label).tag(Optional(region))
                }
                Text("Other").tag(GatewayRegion?.none)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Platform API region")
            if flow.gatewayPickerSelection == nil {
                PNPTextField(value: hostBinding, placeholder: "gateway.example.org", mono: true)
                    .accessibilityLabel("Platform API gateway host")
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(captionStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selection: Binding<GatewayRegion?> {
        Binding(
            get: { flow.gatewayPickerSelection },
            set: { choice in
                if let region = choice {
                    flow.chooseGatewayRegion(region)
                } else {
                    flow.chooseOtherGateway()
                }
            }
        )
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { flow.gatewayURL },
            set: {
                flow.gatewayOtherSelected = true
                flow.gatewayURL = $0
            }
        )
    }

    /// The reason the typed host is refused; nil while it is usable or still empty.
    private var problem: String? {
        let typed = flow.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return flow.gatewayPickerSelection == nil && !typed.isEmpty
            ? GatewayRegion.problem(with: typed) : nil
    }

    private var caption: String {
        if let problem { return problem }
        if let region = flow.gatewayPickerSelection { return L("Gateway: \(region.host)") }
        return L("Gateway: the host above, sent as https://. Pick a region to replace it.")
    }

    private var captionStyle: Color {
        problem == nil ? Theme.Text.tertiary(contrast) : Theme.Colors.danger
    }
}
