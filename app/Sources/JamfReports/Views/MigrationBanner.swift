import SwiftUI

/// Banner shown on first launch when dotted legacy workspaces or schedules are detected.
/// Uses @AppStorage for one-time acknowledgment flag to prevent showing repeatedly.
struct MigrationBanner: View {
    @AppStorage("dottedLegacyMigrationAcknowledged") private var acknowledged = false

    let legacyWorkspaces: [String]
    let legacySchedules: [String]
    let onDismiss: () -> Void

    var shouldShow: Bool {
        !acknowledged && (!legacyWorkspaces.isEmpty || !legacySchedules.isEmpty)
    }

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(Theme.Hairline.strong)
                content
                Divider().background(Theme.Hairline.strong)
                footer
            }
            .frame(width: 480)
            .background(Theme.Surface.base)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Colors.warn)
                .frame(width: 52, height: 52)
                .background(Theme.Colors.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("Legacy migration required")
                    .font(Theme.Fonts.serif(20, weight: .bold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Found workspaces or schedules with dotted names")
                    .font(Theme.Fonts.bodyText)
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !legacyWorkspaces.isEmpty {
                migrationSection(
                    title: "\(legacyWorkspaces.count) legacy workspace\(legacyWorkspaces.count == 1 ? "" : "s") need migration",
                    items: legacyWorkspaces,
                    icon: "folder",
                    actionTitle: "Open workspace folder",
                    action: {
                        let workspaceURL = URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent("Jamf-Reports")
                        _ = SystemActions.reveal(workspaceURL)
                    }
                )
            }

            if !legacySchedules.isEmpty {
                migrationSection(
                    title: "\(legacySchedules.count) legacy schedule\(legacySchedules.count == 1 ? "" : "s") need manual removal",
                    items: legacySchedules,
                    icon: "calendar",
                    actionTitle: "Open LaunchAgents folder",
                    action: {
                        let agentsURL = URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent("Library/LaunchAgents")
                        _ = SystemActions.reveal(agentsURL)
                    }
                )
            }
        }
        .padding(20)
    }

    private func migrationSection(
        title: String,
        items: [String],
        icon: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.warn)
                    .frame(width: 22, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(Theme.Fonts.bodyText)
                        .foregroundStyle(Theme.Text.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.self) { item in
                            Text("• \(item)")
                                .font(Theme.Fonts.mono)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }

                    PNPButton(title: actionTitle, icon: "arrow.right.square", style: .ghost) {
                        action()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Rename workspace folders and manually remove legacy schedules to complete migration.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Text.tertiary)

            Spacer()

            PNPButton(title: "I've cleaned these up") {
                acknowledged = true
                onDismiss()
            }
            .accessibilityLabel("Mark legacy migration complete")
        }
        .padding(16)
    }
}