import SwiftUI

struct Titlebar: View {
    @Environment(WorkspaceStore.self) private var workspace

    let title: String
    var sub: String?
    let sidebarMode: SidebarMode
    let onCycleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCycleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 26, height: 24)
                    .background(Color.clear)
            }
            .buttonStyle(.plain)
            .help("Toggle sidebar")

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
            if let sub {
                Text("/ \(sub)")
                    .font(Theme.Fonts.mono(10.5))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.fgMuted)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(workspace.jamfCLIPath == nil ? Theme.Colors.warn : Theme.Colors.ok)
                    .frame(width: 6, height: 6)
                    .shadow(color: (workspace.jamfCLIPath == nil ? Theme.Colors.warn : Theme.Colors.ok).opacity(0.6), radius: 3)
                Text(cliStatusText)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
                    )
            )

        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metrics.titlebarHeight)
        .background(.ultraThinMaterial)
    }

    private var cliStatusText: String {
        guard workspace.jamfCLIPath != nil else { return "jamf-cli missing" }
        let version = workspace.jamfCLIVersion ?? "unknown"
        return "jamf-cli \(version) · \(workspace.demoMode ? "demo" : "live")"
    }
}
