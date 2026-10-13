import SwiftUI

/// The Jamf Platform API region: United States, Europe or Asia-Pacific. A stored gateway URL that
/// is none of the three shows as "Other" with the URL, and stays until a region is picked.
struct GatewayRegionPicker: View {
    let flow: OnboardingFlow
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(label: "Region")
            Picker("", selection: selection) {
                ForEach(GatewayRegion.allCases) { region in
                    Text(region.label).tag(Optional(region))
                }
                if flow.gatewayRegion == nil {
                    Text("Other: \(flow.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines))")
                        .tag(GatewayRegion?.none)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Platform API region")
            Text(caption)
                .font(.caption)
                .foregroundStyle(captionStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selection: Binding<GatewayRegion?> {
        Binding(
            get: { flow.gatewayRegion },
            set: { if let region = $0 { flow.chooseGatewayRegion(region) } }
        )
    }

    private var caption: String {
        if let region = flow.gatewayRegion { return "Gateway: \(region.host)" }
        return flow.isGatewayURLValid
            ? "This gateway URL is kept as it is. Pick a region to replace it."
            : "This gateway URL must use https:// and include a host. Pick a region to replace it."
    }

    private var captionStyle: Color {
        flow.gatewayRegion != nil || flow.isGatewayURLValid
            ? Theme.Text.tertiary(contrast) : Theme.Colors.danger
    }
}
