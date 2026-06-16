import SwiftUI

struct Titlebar: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

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
            .accessibilityLabel("Toggle sidebar")

            Button(action: popToRoot) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
            }
            .buttonStyle(.plain)
            .help("Return to \(title)")

            if let sub {
                Text("/")
                    .font(Theme.Fonts.mono(10.5))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.hairlineStrong)
                Button(action: popToRoot) {
                    Text(sub)
                        .font(Theme.Fonts.mono(10.5))
                        .tracking(0.6)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                .buttonStyle(.plain)
                .help("Return to \(title)")
            }

            Spacer()

            CLIStatusChip()
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metrics.titlebarHeight)
        .background(.ultraThinMaterial)
    }

    private func popToRoot() {
        NotificationCenter.default.post(name: .popToRootNavigation, object: nil)
    }
}
