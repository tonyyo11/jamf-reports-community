import SwiftUI

struct Titlebar: View {
    @Environment(WorkspaceStore.self) private var workspace

    let title: String
    var sub: String?
    let sidebarMode: SidebarMode
    let onCycleSidebar: () -> Void

    @State private var breathing = false
    @State private var hoveringChip = false

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

            statusChip
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metrics.titlebarHeight)
        .background(.ultraThinMaterial)
    }

    private var statusChip: some View {
        let isWarn = workspace.jamfCLIPath == nil
        let dotColor = isWarn ? Theme.Colors.warn : Theme.Colors.ok
        return HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: dotColor.opacity(0.6), radius: 3)
                .scaleEffect(isWarn && breathing ? 1.0 : (isWarn ? 0.85 : 1.0))
                .opacity(isWarn && breathing ? 1.0 : (isWarn ? 0.7 : 1.0))
                .animation(
                    isWarn
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: breathing
                )
                .onAppear {
                    if isWarn { breathing = true }
                }
                .onChange(of: isWarn) { _, newValue in
                    breathing = newValue
                }
            Text(cliStatusText)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(workspace.demoMode
                      ? Theme.Colors.gold.opacity(0.08)
                      : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
                )
        )
        .onHover { hoveringChip = $0 }
        .popover(isPresented: $hoveringChip, arrowEdge: .bottom) {
            chipPopover
        }
    }

    private var chipPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("JAMF-CLI PATH")
                .font(Theme.Fonts.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Colors.fgMuted)
            Text(workspace.jamfCLIPath ?? "not found on PATH")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.fg)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(minWidth: 220, alignment: .leading)
    }

    private var cliStatusText: String {
        guard workspace.jamfCLIPath != nil else { return "jamf-cli missing" }
        let version = workspace.jamfCLIVersion ?? "unknown"
        return "jamf-cli \(version) · \(workspace.demoMode ? "demo" : "live")"
    }
}
