import SwiftUI

enum UnassignedProfilesCardText {
    /// The row's subtitle: product name, auth method and host. The host is
    /// `URL(string:)?.host`, else the url as stored, through `ConfigSchema.displayText`.
    static func subtitle(for row: AddSheetPlan.UnassignedProfile) -> String {
        let host = URL(string: row.url)?.host ?? row.url
        return [row.product.displayName, row.authMethod, host]
            .map(ConfigSchema.displayText)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Why the profile cannot be a workspace. App text, so it is shown whole, not cut by
    /// `ConfigSchema.displayText`.
    static func reason(for row: AddSheetPlan.UnassignedProfile) -> String? {
        if case .unavailable(let reason) = row.use { return reason }
        return nil
    }

    /// A Security Cloud login can be added to an environment whose slot is empty, never in demo.
    static func offersAttach(
        _ row: AddSheetPlan.UnassignedProfile, acceptsSecurityCloud: Bool, demo: Bool
    ) -> Bool {
        row.product == .securityCloud && acceptsSecurityCloud && !demo
    }

    /// Writes `profiles.security_cloud` (the writer confirms the pin on this Mac).
    @discardableResult
    static func attachSecurityCloud(
        _ profile: String, workspace: String, appSupport: URL = AppSupport.directory()
    ) throws -> ConfigSaveReport {
        try ProfilesConfigWriter.save(
            .securityCloud, to: profile, workspace: workspace, appSupport: appSupport)
    }
}

/// Data Sources' list of jamf-cli profiles no workspace uses (spec 6, P5). It adopts nothing:
/// the button opens the Add sheet, whose "Profiles jamf-cli already has" section does (R2).
struct UnassignedProfilesCard: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let rows: [AddSheetPlan.UnassignedProfile]
    var workspace = ""
    var acceptsSecurityCloud = false
    var demo = false
    var onChanged: () -> Void = {}
    @State private var attachError: String?

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(Theme.Colors.goldBright).font(.system(size: 16))
                    SectionHeader(title: L("Profiles not in an environment"))
                    Spacer()
                }
                Text(L(
                    "jamf-cli has these profiles, but no workspace uses them, so nothing collects them."))
                    .font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(rows) { row in rowView(row) }
                if let attachError {
                    Text(attachError).font(.caption).foregroundStyle(Theme.Colors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WrappingRow {
                    PNPButton(
                        title: L("Add or set up…"), icon: "plus", style: .ghost, size: .sm
                    ) {
                        NotificationCenter.default.post(name: .showAddSheet, object: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: AddSheetPlan.UnassignedProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ConfigSchema.displayText(row.name)).font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1).truncationMode(.middle)
            Text(UnassignedProfilesCardText.subtitle(for: row)).font(.caption)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let reason = UnassignedProfilesCardText.reason(for: row) {
                Text(reason).font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        if UnassignedProfilesCardText.offersAttach(
            row, acceptsSecurityCloud: acceptsSecurityCloud, demo: demo) {
            PNPButton(title: L("Add to this environment"), icon: "plus", style: .ghost, size: .sm) {
                attach(row.name)
            }
            .accessibilityLabel("Add \(ConfigSchema.displayText(row.name)) to \(workspace)")
        }
    }

    private func attach(_ name: String) {
        attachError = nil
        let target = workspace
        Task {
            do {
                try await Task.detached {
                    try UnassignedProfilesCardText.attachSecurityCloud(name, workspace: target)
                }.value
                onChanged()
            } catch {
                attachError = L("Could not add \(ConfigSchema.displayText(name)): \(error.localizedDescription)")
            }
        }
    }
}

#if DEBUG
#Preview("Unassigned profiles card") {
    UnassignedProfilesCard(rows: [
        .init(name: "acme-sandbox", product: .pro, url: "https://acme.jamfcloud.com",
              use: .newWorkspace, authMethod: "oauth2"),
        .init(name: "acme-security", product: .securityCloud, url: "https://sec.example.com",
              use: .unavailable("Jamf Security Cloud logins cannot be a workspace."),
              authMethod: "security"),
    ])
    .padding(16)
    .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
    .preferredColorScheme(.dark)
}
#endif
