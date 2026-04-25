import SwiftUI

struct Titlebar: View {
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

            Button {} label: { Image(systemName: "chevron.left").font(.system(size: 12)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.fgDisabled)
                .frame(width: 26, height: 24)
                .disabled(true)
            Button {} label: { Image(systemName: "chevron.right").font(.system(size: 12)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.fgDisabled)
                .frame(width: 26, height: 24)
                .disabled(true)

            Rectangle().fill(Theme.Colors.hairlineStrong).frame(width: 1, height: 16)

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
                    .fill(Theme.Colors.ok)
                    .frame(width: 6, height: 6)
                    .shadow(color: Theme.Colors.ok.opacity(0.6), radius: 3)
                Text("jamf-cli 1.6.2 · live")
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

            Button {} label: { Image(systemName: "bell").font(.system(size: 13)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.fgMuted)
                .frame(width: 26, height: 24)
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metrics.titlebarHeight)
        .background(.ultraThinMaterial)
    }
}
