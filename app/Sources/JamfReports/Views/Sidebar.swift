import SwiftUI

struct Sidebar: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Binding var activeTab: Tab
    let mode: SidebarMode

    // Workspace chip affordance: SwiftUI's Menu does not expose its open state, so
    // we approximate "engaged" by combining hover + keyboard focus. Both feed the
    // glow/ring shown around the avatar and chip surface.
    @State private var chipHovered: Bool = false
    @FocusState private var chipFocused: Bool

    private struct NavGroup {
        let group: String
        let items: [Tab]
    }

    private let groups: [NavGroup] = [
        .init(group: "REPORTS", items: [.overview, .fleet, .devices, .trends, .audit, .reports]),
        .init(group: "AUTOMATION", items: [.schedules, .runs]),
        .init(group: "CONFIGURATION", items: [.config, .customize, .sources, .backups]),
        .init(group: "SYSTEM", items: [.settings]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // macOS traffic-light spacer (real traffic-lights come from the window
            // chrome when `windowStyle(.hiddenTitleBar)` is removed; keeping this
            // empty band so the sidebar height aligns with the titlebar).
            Color.clear.frame(height: Theme.Metrics.titlebarHeight)

            brandBlock
                .padding(.horizontal, mode == .compact ? 14 : 16)
                .padding(.bottom, 14)

            navStack
                .background(alignment: .top) {
                    if mode == .compact { compactRailTray }
                }

            Spacer()

            workspaceChip
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Colors.hairline).frame(width: 0.5)
        }
    }

    @ViewBuilder
    private var navStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.group) { group in
                navSection(group)
            }
        }
    }

    /// Subtle "tray" behind the icon column in compact mode. Defines the interactive
    /// zone without painting the full 64pt sidebar width.
    @ViewBuilder
    private var compactRailTray: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.025))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }

    // MARK: Brand block (org name + app name)

    @ViewBuilder
    private var brandBlock: some View {
        if mode == .compact {
            // Compact: just a tiny dot in PN&P gold so the brand isn't completely
            // gone but doesn't compete with icons.
            HStack {
                Spacer()
                Circle().fill(Theme.Colors.gold).frame(width: 6, height: 6)
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.org.name.uppercased())
                    .font(Theme.Fonts.mono(10.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Colors.fg)
                Text("Jamf Reports · v\(appVersion)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Nav section

    @ViewBuilder
    private func navSection(_ group: NavGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode != .compact {
                Text(group.group)
                    .font(Theme.Fonts.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } else {
                Spacer().frame(height: 6)
            }
            ForEach(group.items) { item in
                navItem(item)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Single nav item

    @ViewBuilder
    private func navItem(_ item: Tab) -> some View {
        let isActive = activeTab == item
        Button {
            activeTab = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.sfSymbol)
                    .font(.system(size: mode == .compact ? 15 : 13, weight: .medium))
                    .foregroundStyle(isActive ? Theme.Colors.gold : Theme.Colors.fgMuted)
                    .frame(width: mode == .compact ? 20 : 16, height: mode == .compact ? 20 : 16)

                if mode != .compact {
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? Theme.Colors.fg : Theme.Colors.fg2)
                    Spacer()
                    if let badge = badge(for: item) {
                        Text(badge)
                            .font(Theme.Fonts.mono(10, weight: .semibold))
                            .foregroundStyle(item.badgeIsGold ? Theme.Colors.goldBright : Theme.Colors.fgMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    item.badgeIsGold ? Theme.Colors.gold.opacity(0.2) : Color.white.opacity(0.08)
                                )
                            )
                    }
                }
            }
            .padding(.horizontal, mode == .compact ? 0 : 10)
            .padding(.vertical, mode == .compact ? 6 : 0)
            .frame(maxWidth: .infinity, alignment: mode == .compact ? .center : .leading)
            .frame(minHeight: mode == .compact ? 0 : 28)
            .background(
                RoundedRectangle(cornerRadius: mode == .compact ? 8 : 6, style: .continuous)
                    .fill(isActive ? Theme.Colors.gold.opacity(0.18) : .clear)
                    .padding(.horizontal, mode == .compact ? 4 : 0)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(for item: Tab) -> String? {
        if workspace.demoMode { return item.badge }
        switch item {
        case .fleet:
            let count = workspace.initializedProfiles.count
            return count > 0 ? "\(count)" : nil
        case .trends:
            let count = liveTrendCount()
            return count > 0 ? "\(count)" : nil
        case .reports:
            let count = ReportLibrary().stats(profile: workspace.profile).count
            return count > 0 ? "\(count)" : nil
        case .schedules:
            let count = workspace.schedules.count
            return count > 0 ? "\(count)" : nil
        default:
            return nil
        }
    }

    private func liveTrendCount() -> Int {
        guard let summariesDir = try? WorkspacePaths.summariesDir(for: workspace.profile) else { return 0 }
        return SummaryJSONParser.parseDirectory(summariesDir).count
    }

    // MARK: Workspace switcher chip (bottom of sidebar)

    @ViewBuilder
    private var workspaceChip: some View {
        let engaged = chipHovered || chipFocused
        Menu {
            ForEach(workspace.profiles) { p in
                Button {
                    workspace.setProfile(p.name)
                } label: {
                    HStack {
                        Text(p.name)
                        if p.name == workspace.profile { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button("Add workspace…") { activeTab = .onboarding }
        } label: {
            HStack(spacing: 10) {
                workspaceAvatar(engaged: engaged)
                    .frame(width: 22, height: 22)

                if mode != .compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.profile)
                            .font(Theme.Fonts.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.fg)
                            .lineLimit(1)
                        Text(workspaceSubtitle)
                            .font(Theme.Fonts.mono(9.5))
                            .tracking(0.4)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
            }
            .padding(.horizontal, mode == .compact ? 6 : 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(engaged ? 0.07 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                engaged ? Theme.Colors.gold.opacity(0.45) : Theme.Colors.hairlineStrong,
                                lineWidth: engaged ? 0.75 : 0.5
                            )
                    )
                    .shadow(
                        color: engaged ? Theme.Colors.gold.opacity(0.22) : .clear,
                        radius: engaged ? 8 : 0
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focused($chipFocused)
        .onHover { chipHovered = $0 }
        .animation(.easeOut(duration: 0.18), value: engaged)
    }

    /// Subtitle under the workspace name. Shows the initialized-workspace count when
    /// it's informative (>0); otherwise falls back to the static label.
    private var workspaceSubtitle: String {
        let count = workspace.initializedProfiles.count
        guard count > 0 else { return "Active workspace" }
        return "\(count) workspace\(count == 1 ? "" : "s")"
    }

    /// Distinctive avatar: gradient derived from a hue keyed off the profile's first
    /// letter, so each workspace gets a stable but unique tint. Adds a gold ring when
    /// the chip is engaged.
    @ViewBuilder
    private func workspaceAvatar(engaged: Bool) -> some View {
        let initial = workspace.profile.first.map { String($0).uppercased() } ?? "?"
        let hue = avatarHue(for: workspace.profile)
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.78),
                        Color(hue: hue, saturation: 0.70, brightness: 0.42),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Text(String(workspace.profile.prefix(2)).uppercased())
                .font(Theme.Fonts.mono(9, weight: .bold))
                .foregroundStyle(.white)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    engaged ? Theme.Colors.goldBright.opacity(0.85) : Color.white.opacity(0.10),
                    lineWidth: engaged ? 1.2 : 0.5
                )
        }
        .accessibilityLabel("Workspace \(initial)")
    }

    /// Stable hue in [0,1) derived from the profile name, so the same workspace
    /// always renders with the same gradient.
    private func avatarHue(for name: String) -> Double {
        guard let first = name.unicodeScalars.first else { return 0.12 }
        // 0.12 ≈ gold-ish; offset by character so distinct profiles diverge predictably.
        let base = Double(first.value % 360) / 360.0
        return base
    }
}
