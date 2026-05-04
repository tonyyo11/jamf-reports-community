import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @AppStorage("autoUpdateJamfCLI") private var autoUpdate = false
    @State private var testingProfile: String? = nil
    @State private var testResults: [String: Bool] = [:]
    @State private var addConnectionMessage: String? = nil
    @State private var tokenStatuses: [String: TokenStatus] = [:]
    @State private var loadingTokenProfiles: Set<String> = []

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
        .task {
            workspace.refreshToolStatus()
            workspace.reloadFromDisk()
            testResults = [:]
            await loadTokenStatuses()
        }
    }

    private var cliCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "jamf-cli")
                settingsRow(
                    label: "Installed version",
                    sub: jamfCLISubtitle,
                    trailing: AnyView(PNPButton(title: "Refresh", size: .sm) {
                        workspace.refreshToolStatus()
                        workspace.reloadFromDisk()
                    })
                )
                Divider().background(Theme.Colors.hairline)
                settingsRow(
                    label: "jamf-cli updates",
                    sub: jamfCLIUpdateSubtitle,
                    trailing: AnyView(jamfCLIUpdateControls)
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
                    trailing: AnyView(PNPToggle(isOn: demoModeBinding))
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var jamfCLISubtitle: String {
        guard let path = workspace.jamfCLIPath else { return "Not found in /opt/homebrew/bin or /usr/local/bin" }
        let source = workspace.jamfCLIInstallSource ?? "Unknown source"
        return "\(workspace.jamfCLIVersion ?? "unknown") · \(source) · \(path)"
    }

    private var jamfCLIUpdateSubtitle: String {
        workspace.jamfCLIUpdateMessage
            ?? "Homebrew installs use brew; direct installs use GitHub releases"
    }

    private var jamfCLIUpdateControls: some View {
        HStack(spacing: 8) {
            if workspace.isUpdatingJamfCLI {
                ProgressView().controlSize(.small)
            } else {
                PNPButton(title: "Check", size: .sm) {
                    Task { await workspace.checkJamfCLIUpdate() }
                }
                if workspace.jamfCLIUpdateAvailable {
                    PNPButton(title: "Update", icon: "arrow.down.circle", style: .gold, size: .sm) {
                        Task { await workspace.updateJamfCLI() }
                    }
                }
            }
        }
    }

    private var demoModeBinding: Binding<Bool> {
        Binding(
            get: { workspace.demoMode },
            set: { workspace.setDemoMode($0) }
        )
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
                    ForEach(Array(workspace.profiles.enumerated()), id: \.element.id) { idx, c in
                        let isUnsupported = c.status == .error
                        HStack(spacing: 10) {
                            Circle()
                                .fill(dotColor(for: c))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(isUnsupported ? Theme.Colors.fgDisabled : Theme.Colors.fg)
                                Mono(text: "\(c.url) · \(profileType(c))", size: 10.5)
                                tokenStatusLabel(for: c.name)
                            }
                            Spacer()
                            if !isUnsupported {
                                testControlView(for: c.name)
                            }
                            if c.name == workspace.profile { Pill(text: "ACTIVE", tone: .gold) }
                        }
                        .padding(.vertical, 10)
                        .opacity(isUnsupported ? 0.55 : 1)
                        if idx < workspace.profiles.count - 1 {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                    if workspace.profiles.isEmpty {
                        Text("No local jamf-cli profiles found.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    PNPButton(title: "Add connection", icon: "plus", style: .gold, size: .sm) {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        process.arguments = ["-a", "Terminal", "-n"]
                        try? process.run()
                        SystemActions.copyToClipboard("jamf-cli config add-profile")
                        addConnectionMessage = "Command copied. Run it in the Terminal window that just opened."
                    }
                    if let msg = addConnectionMessage {
                        Text(msg)
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func testControlView(for profileName: String) -> some View {
        if testingProfile == profileName {
            ProgressView().controlSize(.small)
        } else if let passed = testResults[profileName] {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? Theme.Colors.ok : Theme.Colors.warn)
                .font(.system(size: 14))
        } else {
            PNPButton(title: "Test", size: .sm) {
                testingProfile = profileName
                Task {
                    let bridge = CLIBridge()
                    let exit = await bridge.validateConnection(profile: profileName) { _ in }
                    testResults[profileName] = exit == 0
                    testingProfile = nil
                }
            }
        }
    }

    @ViewBuilder
    private func tokenStatusLabel(for profileName: String) -> some View {
        if loadingTokenProfiles.contains(profileName) {
            Mono(text: "Token: checking...", size: 10).foregroundStyle(Theme.Colors.fgMuted)
        } else if let status = tokenStatuses[profileName] {
            Mono(text: tokenStatusText(status), size: 10)
                .foregroundStyle(tokenStatusColor(status))
        }
    }

    private func tokenStatusText(_ status: TokenStatus) -> String {
        guard status.isValid else {
            return "Token: not authenticated"
        }
        guard let exp = status.expiresAt else {
            return "Token: valid (no expiry)"
        }
        if exp <= Date() {
            return "Token: expired"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Token valid until \(formatter.string(from: exp))"
    }

    private func tokenStatusColor(_ status: TokenStatus) -> Color {
        guard status.isValid else { return Theme.Colors.fgMuted }
        if let exp = status.expiresAt, exp <= Date() { return Theme.Colors.warn }
        return Theme.Colors.ok
    }

    private func loadTokenStatuses() async {
        let bridge = CLIBridge()
        let profiles = workspace.profiles
        for profile in profiles where profile.status != .error {
            loadingTokenProfiles.insert(profile.name)
            let status = await bridge.tokenStatus(for: profile.name)
            loadingTokenProfiles.remove(profile.name)
            if let status {
                tokenStatuses[profile.name] = status
            }
        }
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
                        metaPair(label: "App:", value: appVersion)
                        metaPair(label: "CLI:", value: workspace.jamfCLIVersion ?? "not found")
                        metaPair(label: "jrc:", value: workspace.jrcPath == nil ? "not found" : "available")
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

    private func profileType(_ profile: JamfCLIProfile) -> String {
        if profile.authMethod.isEmpty { return "Jamf Pro profile" }
        return "Jamf Pro · \(profile.authMethod)"
    }

    private func dotColor(for profile: JamfCLIProfile) -> Color {
        if profile.status == .error { return Theme.Colors.warn }
        return profile.name == workspace.profile ? Theme.Colors.ok : Theme.Colors.fgDisabled
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func metaPair(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.Colors.fgMuted)
            Text(value).foregroundStyle(Theme.Colors.fg)
        }
        .font(Theme.Fonts.mono(11.5))
    }
}
