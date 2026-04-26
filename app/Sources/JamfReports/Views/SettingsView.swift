import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var autoUpdate = true
    @State private var demoMode = false

    private struct Connection: Identifiable {
        let id = UUID()
        let name: String
        let url: String
        let type: String
        let active: Bool
    }

    private let connections: [Connection] = [
        .init(name: "meridian-prod",     url: "meridian.jamfcloud.com",         type: "Jamf Pro · API client", active: true),
        .init(name: "meridian-stage",    url: "stage.jamfcloud.com",            type: "Jamf Pro · API client", active: false),
        .init(name: "meridian-protect",  url: "meridian.protect.jamfcloud.com", type: "Jamf Protect",          active: false),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker(text: "Application", tone: .gold)
                    Text("Settings")
                        .font(Theme.Fonts.serif(26, weight: .bold))
                        .foregroundStyle(Theme.Colors.fg)
                }
                .padding(.bottom, 8)

                HStack(alignment: .top, spacing: 14) {
                    cliCard
                    connectionsCard
                }
                aboutCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
    }

    private var cliCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "jamf-cli")
                settingsRow(
                    label: "Installed version",
                    sub: "1.6.2 · /opt/homebrew/bin/jamf-cli",
                    trailing: AnyView(PNPButton(title: "Check for updates", size: .sm))
                )
                Divider().background(Theme.Colors.hairline)
                settingsRow(
                    label: "Auto-update jamf-cli",
                    sub: "Check on launch",
                    trailing: AnyView(PNPToggle(isOn: $autoUpdate))
                )
                Divider().background(Theme.Colors.hairline)
                settingsRow(
                    label: "Demo mode",
                    sub: "Synthetic data, no API calls",
                    trailing: AnyView(PNPToggle(isOn: $demoMode))
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func settingsRow(label: String, sub: String, trailing: AnyView) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg)
                Text(sub).font(Theme.Fonts.mono(11)).foregroundStyle(Theme.Colors.fgMuted)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 6)
    }

    private var connectionsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Connections")
                VStack(spacing: 0) {
                    ForEach(Array(connections.enumerated()), id: \.element.id) { idx, c in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(c.active ? Theme.Colors.ok : Theme.Colors.fgDisabled)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.Colors.fg)
                                Mono(text: "\(c.url) · \(c.type)", size: 10.5)
                            }
                            Spacer()
                            if c.active { Pill(text: "ACTIVE", tone: .gold) }
                        }
                        .padding(.vertical, 10)
                        if idx < connections.count - 1 {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                }
                PNPButton(title: "Add connection", icon: "plus", style: .gold, size: .sm)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var aboutCard: some View {
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: "Open Source", tone: .gold)
                    SectionHeader(title: "jamf-reports-community")
                    HStack(spacing: 4) {
                        Text("A GUI for the open-source")
                        Text("jamf-reports-community").foregroundStyle(Theme.Colors.goldBright)
                            .font(Theme.Fonts.mono(13))
                        Text("project — every flow in this app maps to a CLI command.")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.fg2)
                    .frame(maxWidth: 620, alignment: .leading)

                    Text("The CLI ships independently and stays the source of truth; this app reads and writes its config and orchestrates runs.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.fg2)
                        .frame(maxWidth: 620, alignment: .leading)

                    HStack(spacing: 14) {
                        metaPair(label: "App:", value: "2.4.0")
                        metaPair(label: "CLI:", value: "1.6.2")
                        metaPair(label: "Maintainer:", value: "@tonyyo11")
                        metaPair(label: "License:", value: "MIT")
                    }
                    .padding(.top, 4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    PNPButton(title: "View on GitHub", icon: "arrow.up.right.square") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community")
                    }
                    PNPButton(title: "Read the docs", icon: "chevron.left.forwardslash.chevron.right") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community#readme")
                    }
                    PNPButton(title: "Release notes", icon: "bolt") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community/releases")
                    }
                }
            }
        }
    }

    /// Opens an `https://` URL in the default browser. We hard-validate the
    /// scheme so a malformed string can't trick AppKit into launching anything
    /// other than a web URL.
    private func openURL(_ url: String) {
        guard let parsed = URL(string: url),
              parsed.scheme == "https",
              let host = parsed.host, !host.isEmpty
        else { return }
        NSWorkspace.shared.open(parsed)
    }

    private func metaPair(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.Colors.fgMuted)
            Text(value).foregroundStyle(Theme.Colors.fg)
        }
        .font(Theme.Fonts.mono(11.5))
    }
}
