import SwiftUI
import AppKit
import UniformTypeIdentifiers

private final class TextLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ text: String) { lock.withLock { _lines.append(text) } }
    var lines: [String] { lock.withLock { _lines } }
}

struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("autoUpdateJamfCLI") private var autoUpdate = false
    @State private var bridge = CLIBridge()
    @State private var experimentalFeatures = ExperimentalFeatureService()
    @State private var platformCapability: PlatformCapabilityService? = nil
    @State private var platformCapabilityAvailable = false
    @State private var experimentalExpanded = false
    @State private var testingProfile: String? = nil
    @State private var testResults: [String: Bool] = [:]
    @State private var testErrors: [String: String] = [:]
    @State private var testingTooLong = false
    @State private var tokenStatuses: [String: TokenStatus] = [:]
    @State private var loadingTokenProfiles: Set<String> = []
    @State private var diagnosticBundleMessage: String? = nil
    @State private var isGeneratingBundle = false
    @State private var tipsResetConfirmation: String? = nil
    // Included-CLI install (CLIInstaller). `cliInstallCommand` is set only when
    // the target dir isn't app-writable and the user must run the command.
    @State private var cliInstallMessage: String? = nil
    @State private var cliInstallCommand: String? = nil
    // Debug logging (DebugLoggingService) — toggles apply on next launch.
    @State private var debugState: DebugLoggingState = .off
    @State private var loggingApplyMessage: String? = nil
    // AI Insights (macOS 27+, opt-in). Loaded/saved via AIConfigLoader/Writer,
    // not the Config-tab managed-key surface.
    @State private var aiConfig: AIConfig = AIConfig()
    @State private var aiSaveMessage: String? = nil

    // Workspace location (2.7.0). Held in @State so the card reflects a change
    // without waiting for the next `.task`; the store is the source of truth.
    @State private var workspaceRootPath: String = ProfileService.workspacesRoot().path
    @State private var workspaceRootMessage: String? = nil
    @State private var pendingSharedRoot: URL? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker(text: "Application", tone: .gold)
                    Text("Settings")
                        .font(Theme.Fonts.serif(26, weight: .bold))
                        .foregroundStyle(Theme.Text.primary)
                }
                .padding(.bottom, 8)

                HStack(alignment: .top, spacing: 14) {
                    cliCard
                    connectionsCard
                }
                commandLineToolCard
                workspaceLocationCard
                dataAndChartsCard
                diagnosticsCard
                loggingCard
                // Config-free, synchronous: macOS 26 hosts never see this
                // panel at all — the config still round-trips for CLI/parity.
                if ModelAvailability.platformSupported {
                    aiInsightsCard
                }
                sidebarVisibilityCard
                experimentalFeaturesCard
                aboutCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        // id: workspace.profile — re-run when the sidebar chip switches
        // profiles, otherwise the Performance card + migration banner would
        // keep showing the first profile's config (PR-23 advisor finding).
        .task(id: workspace.profile) {
            workspace.refreshToolStatus()
            workspaceRootPath = ProfileService.workspacesRoot().path
            workspace.reloadFromDisk()
            testResults = [:]
            await loadTokenStatuses()
            await probePlatformCapability()
        }
    }

    /// Refresh the platform-auth capability flag for the active profile.
    /// Drives whether the Platform API toggle in `experimentalFeaturesCard`
    /// can be enabled. Skipped in demo mode (no real CLI to probe).
    private func probePlatformCapability() async {
        guard !workspace.demoMode, !workspace.profile.isEmpty else {
            platformCapabilityAvailable = false
            return
        }
        let service = platformCapability ?? PlatformCapabilityService(
            executor: DefaultCLIExecutor(bridge: bridge)
        )
        if platformCapability == nil { platformCapability = service }
        service.refresh()
        // Same fact, second cache: collect and the health strip read the auth
        // method through `ProfileAuthMethod`, so a profile that just gained
        // platform auth must not stay excluded for the rest of the session.
        ProfileAuthMethod.invalidateCache()
        platformCapabilityAvailable = await service.isAvailable(for: workspace.profile)
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
                    }
                    .help("Re-detect jamf-cli on PATH and reload workspace state from disk."))
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: "jamf-cli updates",
                    sub: jamfCLIUpdateSubtitle,
                    trailing: AnyView(jamfCLIUpdateControls)
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: "Auto-update jamf-cli",
                    sub: "Check on launch",
                    trailing: AnyView(PNPToggle(isOn: $autoUpdate))
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: "Demo mode",
                    sub: "Synthetic data, no API calls",
                    trailing: AnyView(PNPToggle(isOn: demoModeBinding))
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Included CLI install

    private nonisolated static let workspaceLocationBlurb: String =
        "Where profiles, history, snapshots and reports are kept. Point this at a " +
        "shared team folder — OneDrive/SharePoint, Box, Dropbox or a mounted " +
        "share — so several Macs can report against the same tenants and build " +
        "one history between them. Keep the default if this Mac is the only one " +
        "reporting."

    /// Shared with `ExistingCLISetupView` — the same folder pick, the same consent.
    nonisolated static let sharedFolderConsentMessage: String = """
        Device serials, usernames and email addresses are stored in clear text in the \
        raw snapshots and run logs, and any webhook URL you configure is stored in \
        config.yaml. The folder's sharing settings decide who can read all of that — \
        this app cannot restrict it, and the file permissions it sets are not carried \
        across by the sync provider.

        Confirm the folder is shared only with people cleared to see device-level \
        inventory. If a wider audience only needs the reports, cancel and set \
        Output & Branding's output folder to the shared location instead — that \
        publishes finished reports without sharing the raw data.
        """

    private nonisolated static func providerLabel(_ name: String) -> String {
        "On \(name) — multi-Mac coordination turns on automatically. Run Check on the Config screen reports who else writes here."
    }

    private var workspaceLocationCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Workspace location")
                Text(Self.workspaceLocationBlurb)
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                Text(workspaceRootPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)

                if let provider = CloudStorage.provider(
                    for: URL(fileURLWithPath: workspaceRootPath)
                ) {
                    Label(Self.providerLabel(provider.displayName), systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    PNPButton(title: "Choose folder…", icon: "folder", size: .sm) {
                        chooseWorkspaceRoot()
                    }
                    .help("Pick the folder that holds your Jamf Reports workspaces.")
                    .accessibilityHint("Opens a folder picker for the workspace location.")

                    if WorkspaceRootStore.isCustomised() {
                        PNPButton(title: "Use default", icon: "arrow.uturn.backward", size: .sm) {
                            applyWorkspaceRoot(nil)
                        }
                        .help("Go back to ~/Jamf-Reports on this Mac.")
                    }
                }

                if let msg = workspaceRootMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace location")
        .confirmationDialog(
            sharedFolderConsentTitle,
            isPresented: Binding(
                get: { pendingSharedRoot != nil },
                set: { if !$0 { pendingSharedRoot = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use this folder") {
                let url = pendingSharedRoot
                pendingSharedRoot = nil
                if let url { applyWorkspaceRoot(url) }
            }
            Button("Cancel", role: .cancel) { pendingSharedRoot = nil }
        } message: {
            Text(Self.sharedFolderConsentMessage)
        }
    }

    private func chooseWorkspaceRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that holds your Jamf Reports workspaces."
        panel.directoryURL = URL(fileURLWithPath: workspaceRootPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Choosing a synced folder widens who can read raw fleet data. That is
        // the operator's call to make — but it must be a call they knowingly
        // make, at the moment they make it, not something they read later in
        // the wiki. A local folder skips the prompt entirely.
        if CloudStorage.provider(for: url) != nil {
            pendingSharedRoot = url
            return
        }
        applyWorkspaceRoot(url)
    }

    /// Named for what it actually shares, not for the feature.
    private var sharedFolderConsentTitle: String {
        guard let url = pendingSharedRoot,
              let provider = CloudStorage.provider(for: url) else {
            return "Use this shared folder?"
        }
        return "Everyone with access to this \(provider.displayName) folder will be able to "
            + "read your fleet's device data"
    }

    /// Existing workspaces are deliberately NOT moved. Relocating gigabytes of
    /// snapshots onto a synced volume on a button press is not recoverable in
    /// one click, so the operator either points at a folder that already holds
    /// them or copies them across themselves.
    private func applyWorkspaceRoot(_ url: URL?) {
        do {
            let applied = try WorkspaceRootStore.set(url)
            workspaceRootPath = applied.path
            workspace.reloadFromDisk()
            // Register/unregister the ticker against the new root's schedules.
            // The ticker itself picks up the new root on its next wake, not
            // synchronously here — the message below reflects that.
            Task { await workspace.applyAutomationPolicy() }
            workspaceRootMessage = url == nil
                ? "Back to the default location. Profiles already in the previous folder stay "
                    + "there — copy them across if you want them here."
                : "Workspace location updated. Profiles already elsewhere are not moved; copy "
                    + "them in if you want them here. Scheduled runs use the new folder from "
                    + "their next run."
        } catch {
            workspaceRootMessage = "Couldn't use that folder: \(error.localizedDescription)"
        }
    }

    private var commandLineToolCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Command-line tool")
                Text(
                    "Install a `jamf-reports` command so you can generate reports, " +
                    "collect snapshots, and back up from Terminal or a script — the same " +
                    "engine the app uses. This links the app into a directory on your PATH; " +
                    "the app never uses administrator rights."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    PNPButton(title: "Install command-line tool", icon: "terminal", size: .sm) {
                        installCommandLineTool()
                    }
                    .help("Create a `jamf-reports` symlink in /usr/local/bin, or show the command to run if it isn't writable.")
                    .accessibilityHint("Installs the jamf-reports command-line tool.")
                }

                if let msg = cliInstallMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cmd = cliInstallCommand {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cmd)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        PNPButton(title: "Copy command", icon: "doc.on.doc", size: .sm) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        }
                        .help("Copy the install command to the clipboard.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command-line tool")
    }

    private func installCommandLineTool() {
        switch CLIInstaller.install() {
        case let .installed(path):
            cliInstallMessage = "Installed — open a new Terminal and run `jamf-reports --help`. (\(path))"
            cliInstallCommand = nil
        case let .alreadyInstalled(path):
            cliInstallMessage = "Already installed at \(path)."
            cliInstallCommand = nil
        case let .manual(command):
            cliInstallMessage =
                "The app can't write to /usr/local/bin. Run this in Terminal to finish installing:"
            cliInstallCommand = command
        case let .failed(reason):
            cliInstallMessage = "Couldn't install: \(reason)"
            cliInstallCommand = nil
        }
    }

    private var jamfCLISubtitle: String {
        guard let path = workspace.jamfCLIPath else { return "Not found in /opt/homebrew/bin or /usr/local/bin" }
        let source = workspace.jamfCLIInstallSource ?? "Unknown source"
        let versionLabel: String
        if let spec = workspace.jamfCLISpecProVersion, spec != "unknown" {
            versionLabel = "\(workspace.jamfCLIVersion ?? "unknown") (spec \(spec))"
        } else {
            versionLabel = workspace.jamfCLIVersion ?? "unknown"
        }
        let base = "\(versionLabel) · \(source) · \(path)"
        if workspace.jamfCLIVerificationFailed {
            return "\(base)\nCodesign verification failed — binary may be tampered. Update or reinstall jamf-cli."
        }
        if JamfCLIInstaller.isBelowMinimumSupported(workspace.jamfCLIVersion) {
            return "\(base)\nBelow minimum supported \(JamfCLIInstaller.minimumSupportedVersion) — Device Lookup payloads may be incomplete. Update recommended."
        }
        return base
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
                .help("Check GitHub releases (or Homebrew, depending on install source) for a newer jamf-cli.")
                if workspace.jamfCLIUpdateAvailable {
                    PNPButton(title: "Update", icon: "arrow.down.circle", style: .gold, size: .sm) {
                        Task { await workspace.updateJamfCLI() }
                    }
                    .help("Download and install the newer jamf-cli release.")
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
                Text(label).font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text(sub).font(.caption.monospaced()).foregroundStyle(Theme.Text.tertiary(contrast))
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
                                Text(c.name).font(.footnote.weight(.medium))
                                    .foregroundStyle(isUnsupported ? Theme.Text.disabled(contrast) : Theme.Text.primary)
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
                            Divider().background(Theme.Hairline.standard)
                        }
                    }
                    if workspace.profiles.isEmpty {
                        Text("No local jamf-cli profiles found.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    PNPButton(title: "Add connection", icon: "plus", style: .gold, size: .sm) {
                        NotificationCenter.default.post(
                            name: .navigateToTab,
                            object: nil,
                            userInfo: ["tab": Tab.onboarding.rawValue]
                        )
                    }
                    .help("Opens the onboarding wizard so the GUI walks you through jamf-cli profile setup.")
                    Text("Walks you through profile registration, workspace setup, and CSV mapping without leaving the app.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func testControlView(for profileName: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if testingProfile == profileName {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if testingTooLong {
                        Text("Taking longer than usual…")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
            } else if let passed = testResults[profileName] {
                HStack(spacing: 6) {
                    Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(passed ? Theme.Colors.ok : Theme.Colors.warn)
                        .font(.system(size: 14))
                    PNPButton(title: "Retest", size: .sm) {
                        runConnectionTest(for: profileName)
                    }
                }
                if let err = testErrors[profileName] {
                    Text(err)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Colors.warn)
                        .lineLimit(4)
                        .onTapGesture { testErrors[profileName] = nil }
                }
            } else {
                PNPButton(title: "Test", size: .sm) {
                    runConnectionTest(for: profileName)
                }
                .help("Run `jamf-cli pro auth-status` against this profile to verify the API token is valid.")
            }
        }
    }

    private func runConnectionTest(for profileName: String) {
        testingProfile = profileName
        testErrors[profileName] = nil
        testingTooLong = false
        Task {
            let bridge = CLIBridge()
            let buf = TextLineBuffer()
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { testingTooLong = true }
            }
            let exit: Int32
            do {
                exit = try await bridge.validateConnection(profile: profileName) { line in
                    buf.append(line.text)
                }
            } catch {
                timeoutTask.cancel()
                testResults[profileName] = false
                testErrors[profileName] = error.localizedDescription
                testingProfile = nil
                testingTooLong = false
                return
            }
            timeoutTask.cancel()
            testResults[profileName] = exit == 0
            if exit != 0 {
                let msg = buf.lines.filter { !$0.isEmpty }.joined(separator: "\n")
                testErrors[profileName] = msg.isEmpty ? "Connection failed (exit \(exit))" : msg
            }
            testingProfile = nil
            testingTooLong = false
        }
    }

    @ViewBuilder
    private func tokenStatusLabel(for profileName: String) -> some View {
        if loadingTokenProfiles.contains(profileName) {
            Mono(text: "Token: checking...", size: 10).foregroundStyle(Theme.Text.tertiary(contrast))
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
        guard status.isValid else { return Theme.Text.tertiary(contrast) }
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
                            .font(.footnote.monospaced())
                        Text("project — every flow in this app maps to a CLI command.")
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(maxWidth: 620, alignment: .leading)

                    Text("The CLI ships independently and stays the source of truth; this app reads and writes its config and orchestrates runs.")
                        .font(.callout)
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(maxWidth: 620, alignment: .leading)

                    HStack(spacing: 14) {
                        metaPair(label: "App:", value: appVersion)
                        metaPair(label: "CLI:", value: workspace.jamfCLIVersion ?? "not found")
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
                    .help("Open the project's GitHub repository.")
                    PNPButton(title: "Read the docs", icon: "chevron.left.forwardslash.chevron.right") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community#readme")
                    }
                    .help("Open the README and setup guide on GitHub.")
                    PNPButton(title: "Release notes", icon: "bolt") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community/releases")
                    }
                    .help("View release notes and download history on GitHub.")
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
        return profile.name == workspace.profile ? Theme.Colors.ok : Theme.Text.disabled(contrast)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func metaPair(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.Text.tertiary(contrast))
            Text(value).foregroundStyle(Theme.Text.primary)
        }
        .font(.caption.monospaced())
    }

    // MARK: - Sidebar visibility

    /// Lets the user hide tabs they don't use. Backed by `@AppStorage`
    /// (parsed/serialized via `TabVisibility`). Grouped by the same sidebar
    /// sections so the layout mirrors what the user sees on the left.
    @AppStorage("hiddenTabs") private var hiddenTabsRaw: String = ""

    /// Defaults that fan out across every trend-aware screen. Stored as raw
    /// strings so adding new `TrendRange` cases later doesn't shift saved prefs.
    @AppStorage("defaultTrendRange") private var defaultTrendRangeRaw: String = TrendRange.w4.rawValue

    /// When ON, `ReportEngine.collect()` skips the four per-device commands
    /// (ea-results, patch-device-failures, update-device-failures,
    /// device-compliance). Off by default — the cold tier already paces them
    /// at 24h, so most users want them.
    @AppStorage("skipExpensiveCollections") private var skipExpensiveCollections: Bool = false

    private var dataAndChartsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Data & Charts")
                settingsRow(
                    label: "Default trend range",
                    sub: "Applies to Overview and Trends until you change the picker in-view.",
                    trailing: AnyView(trendRangePicker)
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: "Skip expensive collections",
                    sub: skipExpensiveCollectionsSubtitle,
                    trailing: AnyView(PNPToggle(isOn: $skipExpensiveCollections))
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Data and charts settings")
    }

    private var trendRangePicker: some View {
        Picker("Default trend range", selection: $defaultTrendRangeRaw) {
            Text("4 weeks").tag(TrendRange.w4.rawValue)
            Text("12 weeks").tag(TrendRange.w12.rawValue)
            Text("26 weeks").tag(TrendRange.w26.rawValue)
            Text("52 weeks").tag(TrendRange.w52.rawValue)
            Text("All").tag(TrendRange.all.rawValue)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130)
    }

    private var skipExpensiveCollectionsSubtitle: String {
        if skipExpensiveCollections {
            return "Per-device commands paused. Posture, Patch, Updates, and Extension Attributes dashboards will show last cached values until refreshed."
        }
        return "Run the four per-device commands (ea-results, patch-device-failures, update-device-failures, device-compliance) on every collect."
    }

    // MARK: - Diagnostics

    private var diagnosticsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Diagnostics")
                Text(
                    "Generate a redacted zip of recent logs, summaries, config, and " +
                    "versions to share when reporting issues. Credentials are always " +
                    "redacted; hostnames, serials, emails, and device names are " +
                    "replaced with stable hash placeholders by default."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if isGeneratingBundle {
                        ProgressView().controlSize(.small)
                        Text("Generating bundle…")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        PNPButton(
                            title: "Generate diagnostic bundle now",
                            icon: "archivebox",
                            size: .sm
                        ) {
                            generateDiagnosticBundleNow()
                        }
                        .disabled(workspace.profile.isEmpty)
                        .help(
                            "Build the redacted diagnostic zip in this profile's workspace and " +
                            "reveal it in Finder. Runs entirely in-app — no Terminal needed."
                        )
                        .accessibilityHint(
                            "Generates a redacted diagnostic bundle and reveals it in Finder.")
                    }
                }

                HStack(spacing: 8) {
                    PNPButton(title: "Reveal Workspace", size: .sm) {
                        if let url = currentWorkspaceURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(currentWorkspaceURL == nil)
                    .help("Open the active workspace directory in Finder.")
                }

                if let msg = diagnosticBundleMessage {
                    Text(msg)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    PNPButton(title: "Restore in-app tips", icon: "lightbulb", size: .sm) {
                        let ok = AppTips.resetAll()
                        tipsResetConfirmation = ok
                            ? "In-app tips restored — they'll reappear as you visit each screen."
                            : "Couldn't reset the tips datastore."
                    }
                    .help("Clear the seen/dismissed state for all guidance tips so they show again.")
                    .accessibilityHint("Restores all in-app guidance tips.")
                }

                if let msg = tipsResetConfirmation {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diagnostics")
    }

    // MARK: - Logging

    private var loggingCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Logging")
                Text(
                    "Control verbose diagnostics and view recent log entries. Changes to the "
                    + "toggles apply after you quit and reopen JamfReports."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                Toggle("Persist verbose logs", isOn: Binding(
                    get: { debugState.persistVerbose },
                    set: { debugState.persistVerbose = $0; applyDebugState() }))
                Toggle("Reveal private values in logs (serials, hostnames, usernames)", isOn: Binding(
                    get: { debugState.revealPrivate },
                    set: { debugState.revealPrivate = $0; applyDebugState() }))
                if debugState.revealPrivate {
                    Text("⚠︎ Private values are written in full to the local log store on this Mac. "
                        + "Leave off unless actively debugging.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let loggingApplyMessage {
                    Text(loggingApplyMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    PNPButton(title: "Quit to apply", icon: "power", size: .sm) {
                        NSApplication.shared.terminate(nil)
                    }
                    .help("Quit JamfReports so the logging toggles take effect on next launch.")
                    PNPButton(title: "Reveal MDM profile", icon: "doc.badge.gearshape", size: .sm) {
                        revealDebugProfile()
                    }
                    .help("Reveal the bundled debug-logging .mobileconfig in Finder for Jamf deployment.")
                }

                Divider().background(Theme.Hairline.standard)
                LogViewerView()

                Divider().background(Theme.Hairline.standard)
                consoleInstructions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Logging")
        .onAppear { debugState = DebugLoggingService.current() }
    }

    private func applyDebugState() {
        do {
            try DebugLoggingService.apply(debugState)
            loggingApplyMessage = "Saved — applies on next launch."
        } catch {
            loggingApplyMessage = "Couldn't write the logging config: \(error.localizedDescription)"
        }
    }

    private func revealDebugProfile() {
        // The bundle resource lives outside the SystemActions allow-list; revealing a
        // read-only app-bundle file is benign, so use NSWorkspace directly.
        if let url = DebugLoggingService.bundledProfileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @ViewBuilder private var consoleInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("View live logs in Terminal").font(.caption.weight(.semibold))
            Mono(text: "log stream --predicate 'subsystem == "
                + "\"com.github.tonyyo11.jamf-reports-community\"' --level debug", size: 11)
                .textSelection(.enabled)
            Text("Or open Console.app and filter on subsystem "
                + "“com.github.tonyyo11.jamf-reports-community”.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AI Insights (macOS 27+, opt-in)

    /// Turns already-collected fleet data into a plain-language insight card
    /// on Overview. Off by default; requires macOS 27 for on-device or Private
    /// Cloud Compute generation. Persists to this profile's `config.yaml`
    /// (`ai:` block) via `AIConfigWriter`, scoped to just that key — the same
    /// pattern as `DebugLoggingService`'s own plist, not the Config-tab's
    /// managed-key round-trip.
    private var aiInsightsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "AI Insights")
                Text(
                    "Turn already-collected fleet data into a plain-language insight card "
                    + "on Overview, using Apple's on-device Foundation Model (or Private Cloud "
                    + "Compute, if you opt in). Off by default; nothing leaves this Mac unless "
                    + "you choose Private Cloud Compute."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable AI insights", isOn: Binding(
                    get: { aiConfig.isEnabled },
                    set: { aiConfig.enabled = $0; saveAIConfig() }))

                if aiConfig.isEnabled {
                    // No model picker: Apple Foundation Models is on-device only,
                    // so there is nothing to choose between. The row states what
                    // will happen rather than offering a one-option control.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model — On-device")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Runs entirely on this Mac. No fleet data leaves the device.")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }

                Text(ModelAvailability.current(for: aiConfig).message)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))

                if let aiSaveMessage {
                    Text(aiSaveMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI Insights")
        .task(id: workspace.profile) {
            aiConfig = AIConfigLoader.load(profile: workspace.profile)
            aiSaveMessage = nil
        }
    }

    private func saveAIConfig() {
        do {
            try AIConfigWriter.save(aiConfig, profile: workspace.profile)
            aiSaveMessage = nil
        } catch {
            aiSaveMessage = "Couldn't save AI settings: \(error.localizedDescription)"
        }
    }

    /// Active workspace root, or nil if no profile is selected.
    private var currentWorkspaceURL: URL? {
        let profile = workspace.profile
        guard !profile.isEmpty, let url = ProfileService.workspaceURL(for: profile) else {
            return nil
        }
        return url
    }

    /// Generate the diagnostic bundle natively (no bundled-script execution) and
    /// reveal it in Finder. The redaction/zip work runs off the main actor in a
    /// detached task; `DiagnosticBundleService.generate` is a `nonisolated`
    /// static func and its inputs/outputs (`String`, `URL`) are `Sendable`.
    private func generateDiagnosticBundleNow() {
        let profile = workspace.profile
        guard !profile.isEmpty else {
            diagnosticBundleMessage = "Select a workspace profile first."
            return
        }
        isGeneratingBundle = true
        diagnosticBundleMessage = nil
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try DiagnosticBundleService.generate(profile: profile)
                }.value
                let revealed = SystemActions.reveal(url)
                diagnosticBundleMessage = revealed
                    ? "Bundle written to \(url.lastPathComponent) and revealed in Finder."
                    : "Bundle written to \(url.lastPathComponent) in this profile's " +
                      "diagnostics folder (Finder reveal was blocked)."
            } catch {
                let diagnosticsPath = WorkspaceRootStore.displayPath(
                    profile: workspace.profile, subpath: "diagnostics"
                )
                diagnosticBundleMessage =
                    "Diagnostic bundle failed: \(error.localizedDescription). Verify "
                    + "\(diagnosticsPath) is writable and has free space."
            }
            isGeneratingBundle = false
        }
    }

    // MARK: - Experimental features

    /// Collapsible section listing v2.1.0 opt-in preview features. Each
    /// feature has a toggle, a description, a capability note (if relevant),
    /// and a discussion link. Disabled by default so an admin can't enable a
    /// feature they don't have the prerequisites for (e.g. Platform API
    /// without a `platform` auth-method profile).
    private var experimentalFeaturesCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup(isExpanded: $experimentalExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ExperimentalFeatureService.Feature.allCases, id: \.self) { feature in
                            experimentalFeatureRow(feature)
                            if feature != ExperimentalFeatureService.Feature.allCases.last {
                                Divider().background(Theme.Hairline.standard)
                            }
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    SectionHeader(title: "Experimental Features")
                }
                .accessibilityHint("Opt-in toggles for v2.1.0 preview features")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Experimental features")
    }

    private func experimentalFeatureRow(
        _ feature: ExperimentalFeatureService.Feature
    ) -> some View {
        let isPlatform = (feature == .platformAPI)
        let isDisabled = isPlatform && !platformCapabilityAvailable
        let disabledTooltip = "Requires a jamf-cli profile with auth-method: platform. "
            + "Run `jamf-cli config list` to see your current profile's auth method."
        let toggleBinding = Binding<Bool>(
            get: { experimentalFeatures.isEnabled(feature) },
            set: { experimentalFeatures.setEnabled(feature, $0) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(feature.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                experimentalBadge
                Spacer()
                PNPToggle(isOn: toggleBinding, label: "\(feature.displayName) toggle")
                    .disabled(isDisabled)
                    .help(isDisabled ? disabledTooltip : "")
            }
            Text(feature.description)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            if isPlatform {
                Text("Requires a jamf-cli profile with auth-method: platform.")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            if let url = feature.discussionURL {
                Link("Learn more \u{2192}", destination: url)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.gold)
            }
        }
    }

    private var experimentalBadge: some View {
        ExperimentalBadge()
    }

    private var sidebarVisibilityCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Sidebar Visibility")
                    Spacer()
                    PNPButton(title: "Show all", size: .sm) {
                        var v = TabVisibility.parse(hiddenTabsRaw)
                        v.showAll()
                        hiddenTabsRaw = v.serialize()
                    }
                    .help("Restore every hidden tab to the sidebar.")
                }
                Text("Hide dashboards you don't use. Core tabs (Overview, Devices, Sources, Settings) cannot be hidden.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                ForEach(SettingsView.toggleableGroups, id: \.label) { group in
                    visibilityGroupRow(label: group.label, tabs: group.tabs)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar visibility settings")
    }

    private static let toggleableGroups: [(label: String, tabs: [Tab])] = [
        ("Reports",       [.fleet, .deviceLookup, .trends, .audit, .reports]),
        ("Posture",       [.securityPosture, .compliancePosture, .complianceBenchmarks, .outreach]),
        ("Operations",    [.patch, .updates, .ddmBlueprints, .policyProfile, .extensionAttributes]),
        ("Fleet",         [.mobileFleet, .protectDashboard]),
        ("Automation",    [.schedules, .runs]),
        ("Configuration", [.config, .customize, .backups])
    ]

    private func visibilityGroupRow(label: String, tabs: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            ForEach(tabs, id: \.self) { tab in
                visibilityRow(for: tab)
            }
        }
    }

    private func visibilityRow(for tab: Tab) -> some View {
        let visibility = TabVisibility.parse(hiddenTabsRaw)
        let isVisible = visibility.isVisible(tab)
        return HStack(spacing: 10) {
            Image(systemName: tab.sfSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.fgMuted)
                .frame(width: 16, alignment: .center)
            Text(tab.label)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg)
            Spacer()
            PNPToggle(
                isOn: Binding(
                    get: { isVisible },
                    set: { newValue in
                        var v = TabVisibility.parse(hiddenTabsRaw)
                        // The toggle binds to "isVisible". A true→false flip
                        // means the user wants the tab hidden, so we call
                        // toggle() when the current state and new state differ.
                        if v.isVisible(tab) != newValue { v.toggle(tab) }
                        hiddenTabsRaw = v.serialize()
                    }
                ),
                label: "\(tab.label) visibility"
            )
        }
        .padding(.vertical, 2)
    }
}
