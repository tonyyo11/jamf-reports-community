import SwiftUI

// DRAFT — needs visual sign-off at PageScaffold.minSupportedWidth

/// Sheet presented from CustomizeView's "How to customize" button.
/// One row per customization surface: what it controls and where to find it.
struct CustomizeGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Hairline.standard)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(GuideRow.all) { row in
                        GuideRowView(row: row, dismiss: dismiss)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 560)
        .background(Theme.Surface.base)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.Colors.goldBright)
            VStack(alignment: .leading, spacing: 2) {
                Text("How to customize")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.fg)
                Text("Five places that shape what reports look like.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Text.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Row model

private struct GuideRow: Identifiable {
    let id: String
    let icon: String
    let title: String
    let description: String
    /// Destination tab, or nil when the surface is on the current screen.
    let destination: Tab?

    static let all: [GuideRow] = [
        GuideRow(
            id: "templates",
            icon: "doc.badge.plus",
            title: "Report templates",
            description: "Full Instance, Executive, Operational, Compliance, and Custom presets "
                + "control which sheets go into the generated workbook.",
            destination: nil
        ),
        GuideRow(
            id: "sheets",
            icon: "checkmark.square",
            title: "Sheet visibility",
            description: "Toggle individual sheets on or off in the grid on this screen.",
            destination: nil
        ),
        GuideRow(
            id: "score",
            icon: "gauge.medium",
            title: "Score weights",
            description: "Adjust the Security Score factor weights (FileVault, SIP, Firewall, "
                + "EDR, mSCP, and more) on the Config → Scoring tab.",
            destination: .config
        ),
        GuideRow(
            id: "sidebar",
            icon: "sidebar.left",
            title: "Sidebar & tab visibility",
            description: "Show or hide tabs from the sidebar on the Settings screen.",
            destination: .settings
        ),
        GuideRow(
            id: "groups",
            icon: "rectangle.3.group",
            title: "Report groups",
            description: "Group profiles into consolidated fleet reports on the Automation screen.",
            destination: .schedules
        ),
    ]
}

// MARK: - Row view

private struct GuideRowView: View {
    let row: GuideRow
    let dismiss: DismissAction
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.goldBright)
                .frame(width: 22, alignment: .top)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Text(row.description)
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let dest = row.destination {
                    PNPButton(
                        title: "Go to \(dest.label)",
                        icon: "arrow.right",
                        style: .ghost,
                        size: .sm
                    ) {
                        dismiss()
                        NotificationCenter.default.post(
                            name: .navigateToTab,
                            object: nil,
                            userInfo: ["tab": dest.rawValue]
                        )
                    }
                    .padding(.top, 2)
                } else {
                    Text("Below on this screen.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if row.id != GuideRow.all.last?.id {
                Divider().background(Theme.Hairline.standard)
            }
        }
    }
}

#Preview {
    CustomizeGuideSheet()
        .environment(WorkspaceStore(demoMode: true))
}
