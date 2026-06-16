import SwiftUI

/// jamf-cli connection status chip: a status dot (breathing when jamf-cli is
/// missing) + a version/mode label, with a hover popover showing the resolved
/// jamf-cli path. Extracted from `Titlebar` so it can sit as a system toolbar
/// item in the Liquid Glass shell (macOS 26) while staying a plain view on the
/// current chrome. Behavior is unchanged from the prior inline `Titlebar.statusChip`.
struct CLIStatusChip: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var breathing = false
    @State private var hoveringChip = false

    var body: some View {
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
                .foregroundStyle(Theme.Text.tertiary(contrast))
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
                .foregroundStyle(Theme.Text.tertiary(contrast))
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
