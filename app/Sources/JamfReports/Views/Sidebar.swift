import SwiftUI

struct Sidebar: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Binding var activeTab: Tab
    let mode: SidebarMode

    private struct NavGroup {
        let group: String
        let items: [Tab]
    }

    private let groups: [NavGroup] = [
        .init(group: "REPORTS", items: [.overview, .devices, .trends, .audit, .reports]),
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

            ForEach(groups, id: \.group) { group in
                navSection(group)
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Theme.Colors.gold : Theme.Colors.fgMuted)
                    .frame(width: 16, height: 16)

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
            .frame(maxWidth: .infinity, alignment: mode == .compact ? .center : .leading)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Theme.Colors.gold.opacity(0.18) : .clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(for item: Tab) -> String? {
        if workspace.demoMode { return item.badge }
        switch item {
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
        guard let workspaceURL = ProfileService.workspaceURL(for: workspace.profile) else { return 0 }
        let summariesDir = workspaceURL.appendingPathComponent("snapshots/summaries", isDirectory: true)
        return SummaryJSONParser.parseDirectory(summariesDir).count
    }

    // MARK: Workspace switcher chip (bottom of sidebar)

    @ViewBuilder
    private var workspaceChip: some View {
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
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(hex: 0x6E6E73), Color(hex: 0x48484A)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Text(String(workspace.profile.prefix(2)).uppercased())
                        .font(Theme.Fonts.mono(9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                if mode != .compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.profile)
                            .font(Theme.Fonts.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.fg)
                            .lineLimit(1)
                        Text("Active workspace")
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
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}
