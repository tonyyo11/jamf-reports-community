import SwiftUI
import Synchronization
import AppKit
import UniformTypeIdentifiers

private final class TextLineBuffer: Sendable {
    private let stored = Mutex<[String]>([])
    func append(_ text: String) { stored.withLock { $0.append(text) } }
    var lines: [String] { stored.withLock { $0 } }
}

struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("autoUpdateJamfCLI") private var autoUpdate = false
    private var autoUpdateManaged: Bool { ManagedPreference.isForced("autoUpdateJamfCLI") }
    @State private var bridge = CLIBridge()
    @State private var experimentalFeatures = ExperimentalFeatureService()
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
    // Debug logging (DebugLoggingService): what a configuration profile sets.
    @State private var managedLogging: ManagedDebugLogging?
    // AI Insights (macOS 27+, opt-in). Loaded/saved via AIConfigLoader/Writer,
    // not the Config-tab managed-key surface.
    @State private var aiConfig: AIConfig = AIConfig()
    @State private var aiSaveMessage: String? = nil
    /// What a save did not keep (a backup was made), shown while its profile is live.
    @State private var aiSaveNote: ProfileSaveNote?

    // Workspace location (2.7.0). Held in @State so the card reflects a change
    // without waiting for the next `.task`; the store is the source of truth.
    @State private var workspaceRootPath: String = ProfileService.workspacesRoot().path
    /// Read off `body` by the location card's task: detection reads the folder and its parents.
    @State private var workspaceRootStorage: CloudStorage.SharedStorage?
    @State private var workspaceRootMessage: String? = nil
    @State private var pendingSharedRoot: URL? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker(text: L("Application"), tone: .gold)
                    Text("Settings")
                        .font(Theme.Fonts.serifTitle())
                        .foregroundStyle(Theme.Text.primary)
                        .accessibilityAddTraits(.isHeader)
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
                appUpdatesCard
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
        // The demo flag is part of the id so turning demo mode on or off here
        // reloads the connections even when the profile name stays the same.
        .task(id: "\(workspace.demoMode)|\(workspace.profile)") {
            testResults = [:]
            // A cancelled run leaves its flag set for this task to reset, never to clear.
            loadingTokenProfiles = []
            guard !workspace.demoMode else {
                // Demo mode runs no jamf-cli and reloads nothing: a reload here
                // put a demo profile chosen in the sidebar back to meridian-prod.
                tokenStatuses = DemoData.tokenStatuses(for: workspace.profiles)
                return
            }
            workspace.refreshToolStatus()
            workspaceRootPath = ProfileService.workspacesRoot().path
            workspace.reloadFromDisk()
            await loadTokenStatuses()
            guard !Task.isCancelled else { return }
            // Collect and the health strip read the auth method through `ProfileAuthMethod`,
            // so a profile that just gained platform auth must not stay excluded for the
            // rest of the session.
            ProfileAuthMethod.invalidateCache()
        }
    }

    private var cliCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "jamf-cli")
                // Demo mode never runs jamf-cli, so this card describes nothing
                // the demo uses; only its Demo mode switch stays live.
                settingsRow(
                    label: L("Installed version"),
                    sub: workspace.demoMode ? DemoData.jamfCLINote : jamfCLISubtitle,
                    trailing: PNPButton(title: L("Refresh"), size: .sm) {
                        guard !workspace.demoMode else { return }
                        workspace.refreshToolStatus()
                        workspace.reloadFromDisk()
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : "Re-detect jamf-cli on PATH and reload workspace state from disk.")
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: L("jamf-cli updates"),
                    sub: workspace.demoMode ? DemoData.jamfCLINote : jamfCLIUpdateSubtitle,
                    trailing: jamfCLIUpdateControls
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: L("Auto-update jamf-cli"),
                    sub: autoUpdateManaged ? ManagedPreference.note : L("Check on launch"),
                    trailing: PNPToggle(isOn: $autoUpdate)
                        .disabled(workspace.demoMode || autoUpdateManaged)
                        .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: L("Demo mode"),
                    sub: L("Synthetic data, no API calls"),
                    trailing: PNPToggle(isOn: demoModeBinding)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Included CLI install

    private nonisolated static let workspaceLocationBlurb: String =
        L("Where profiles, history, snapshots and reports are kept. Point this at a shared team folder — OneDrive/SharePoint, Box, Dropbox or a mounted share — so several Macs can report against the same tenants and build one history between them. Keep the default if this Mac is the only one reporting.")

    private nonisolated static func providerLabel(_ name: String) -> String {
        L("On \(name) — multi-Mac coordination turns on automatically. Run Check on the Config screen reports who else writes here.")
    }

    private var workspaceRootManaged: Bool {
        ManagedPreference.isForced(WorkspaceRootStore.defaultsKey)
    }

    private var workspaceLocationCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Workspace location"))
                Text(Self.workspaceLocationBlurb)
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                // Demo mode shows where the demo's workspaces would live, and
                // never moves this Mac's root.
                Text(workspace.demoMode ? DemoData.workspacesRootDisplay : workspaceRootPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)

                if !workspace.demoMode, let storage = workspaceRootStorage {
                    Label(Self.providerLabel(storage.displayName), systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                }

                if workspaceRootManaged {
                    Text(ManagedPreference.note)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }

                HStack(spacing: 8) {
                    PNPButton(title: L("Choose folder…"), icon: "folder", size: .sm) {
                        chooseWorkspaceRoot()
                    }
                    .disabled(workspace.demoMode || workspaceRootManaged)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : workspaceRootManaged ? ManagedPreference.note
                          : "Pick the folder that holds your Jamf Reports workspaces.")
                    .accessibilityHint("Opens a folder picker for the workspace location.")

                    if !workspace.demoMode && WorkspaceRootStore.isCustomised() {
                        PNPButton(title: L("Use default"), icon: "arrow.uturn.backward", size: .sm) {
                            applyWorkspaceRoot(nil)
                        }
                        .disabled(workspaceRootManaged)
                        .help(workspaceRootManaged
                              ? ManagedPreference.note : "Go back to ~/Jamf-Reports on this Mac.")
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
        .task(id: workspaceRootPath) {
            workspaceRootStorage = CloudStorage.sharedStorage(
                for: URL(fileURLWithPath: workspaceRootPath))
        }
        .sharedFolderConsent(pending: $pendingSharedRoot) { applyWorkspaceRoot($0) }
    }

    private func chooseWorkspaceRoot() {
        guard !workspace.demoMode else { return }
        guard let url = WorkspaceFolderPicker.choose() else { return }

        // Choosing a synced folder widens who can read raw fleet data. That is
        // the operator's call to make — but it must be a call they knowingly
        // make, at the moment they make it, not something they read later in
        // the wiki. A local folder skips the prompt entirely.
        if CloudStorage.isSharedStorage(url) {
            pendingSharedRoot = url
            return
        }
        applyWorkspaceRoot(url)
    }

    /// Existing workspaces are deliberately NOT moved. Relocating gigabytes of
    /// snapshots onto a synced volume on a button press is not recoverable in
    /// one click, so the operator either points at a folder that already holds
    /// them or copies them across themselves.
    private func applyWorkspaceRoot(_ url: URL?) {
        guard !workspace.demoMode else { return }
        do {
            let applied = try WorkspaceRootStore.set(url)
            workspaceRootPath = applied.path
            workspace.reloadFromDisk()
            // Register/unregister the ticker against the new root's schedules.
            // The ticker itself picks up the new root on its next wake, not
            // synchronously here — the message below reflects that.
            Task { await workspace.applyAutomationPolicy() }
            workspaceRootMessage = url == nil
                ? L("Back to the default location. Profiles already in the previous folder stay there — copy them across if you want them here.")
                : L("Workspace location updated. Profiles already elsewhere are not moved; copy them in if you want them here. Scheduled runs use the new folder from their next run.")
        } catch {
            workspaceRootMessage = L("Couldn't use that folder: \(error.localizedDescription)")
        }
    }

    private var commandLineToolCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Command-line tool"))
                Text(
                    "Install a `jamf-reports` command so you can generate reports, collect snapshots, and back up from Terminal or a script — the same engine the app uses. This links the app into a directory on your PATH; the app never uses administrator rights."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    PNPButton(title: L("Install command-line tool"), icon: "terminal", size: .sm) {
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
                        PNPButton(title: L("Copy command"), icon: "doc.on.doc", size: .sm) {
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
            cliInstallMessage = L("Installed — open a new Terminal and run `jamf-reports --help`. (\(path))")
            cliInstallCommand = nil
        case let .alreadyInstalled(path):
            cliInstallMessage = L("Already installed at \(path).")
            cliInstallCommand = nil
        case let .manual(command):
            cliInstallMessage =
                L("The app can't write to /usr/local/bin. Run this in Terminal to finish installing:")
            cliInstallCommand = command
        case let .failed(reason):
            cliInstallMessage = L("Couldn't install: \(reason)")
            cliInstallCommand = nil
        }
    }

    /// This Mac's jamf-cli: version, install source and path. Live mode only.
    private var jamfCLISubtitle: String {
        guard let path = workspace.jamfCLIPath else { return L("Not found in /opt/homebrew/bin or /usr/local/bin") }
        let source = workspace.jamfCLIInstallSource ?? L("Unknown source")
        let versionLabel: String
        if let spec = workspace.jamfCLISpecProVersion, spec != "unknown" {
            versionLabel = L("\(workspace.jamfCLIVersion ?? "unknown") (spec \(spec))")
        } else {
            versionLabel = workspace.jamfCLIVersion ?? "unknown"
        }
        let base = "\(versionLabel) · \(source) · \(path)"
        if workspace.jamfCLIVerificationFailed {
            return L("\(base)\nCodesign verification failed — binary may be tampered. Update or reinstall jamf-cli.")
        }
        if JamfCLIInstaller.isBelowMinimumSupported(workspace.jamfCLIVersion) {
            return L("\(base)\nOlder than the supported \(JamfCLIInstaller.minimumSupportedVersion) — scheduled collects and backups stop until jamf-cli is updated.")
        }
        return base
    }

    private var jamfCLIUpdateSubtitle: String {
        workspace.jamfCLIUpdateMessage
            ?? L("Homebrew installs use brew; direct installs use GitHub releases")
    }

    private var jamfCLIUpdateControls: some View {
        HStack(spacing: 8) {
            if workspace.isUpdatingJamfCLI {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Updating jamf-cli")
            } else {
                PNPButton(title: L("Check"), size: .sm) {
                    guard !workspace.demoMode else { return }
                    Task { await workspace.checkJamfCLIUpdate() }
                }
                .disabled(workspace.demoMode)
                .help(workspace.demoMode
                      ? DemoData.liveOnlyHelp
                      : "Check GitHub releases (or Homebrew, depending on install source) for a newer jamf-cli.")
                if workspace.jamfCLIUpdateAvailable && !workspace.demoMode {
                    PNPButton(title: L("Update"), icon: "arrow.down.circle", style: .gold, size: .sm) {
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

    private func settingsRow<Trailing: View>(label: String, sub: String, trailing: Trailing) -> some View {
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
                SectionHeader(title: L("Connections"))
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
                            if c.name == workspace.profile { Pill(text: L("ACTIVE"), tone: .gold) }
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
                    // The way out of demo mode: setup ends it through
                    // `setDemoMode(false)` once the new profile exists.
                    PNPButton(title: L("Add connection"), icon: "plus", style: .gold, size: .sm) {
                        NotificationCenter.default.post(name: .showAddSheet, object: nil)
                    }
                    .help(workspace.demoMode
                          ? "Set up a real connection; demo mode ends when setup finishes."
                          : "Add a workspace or Jamf Protect, or use a profile jamf-cli already has.")
                    Text("A new Jamf Pro, Platform API or Jamf School workspace, Jamf Protect for this workspace, or a profile jamf-cli already has.")
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
                        .accessibilityLabel("Testing the connection to \(profileName)")
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
                    PNPButton(title: L("Retest"), size: .sm) {
                        runConnectionTest(for: profileName)
                    }
                }
                if let err = testErrors[profileName] {
                    Button { testErrors[profileName] = nil } label: {
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Colors.warn)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses this message")
                }
            } else {
                PNPButton(title: L("Test"), size: .sm) {
                    runConnectionTest(for: profileName)
                }
                .disabled(workspace.demoMode)
                .help(workspace.demoMode
                      ? DemoData.liveOnlyHelp
                      : "Run `jamf-cli config validate` and check this profile's URL and credential settings, plus the config file itself.")
            }
        }
    }

    private func runConnectionTest(for profileName: String) {
        guard !workspace.demoMode else { return }
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
                testErrors[profileName] = msg.isEmpty ? L("Connection failed (exit \(exit))") : msg
            }
            testingProfile = nil
            testingTooLong = false
        }
    }

    @ViewBuilder
    private func tokenStatusLabel(for profileName: String) -> some View {
        if loadingTokenProfiles.contains(profileName) {
            Mono(text: L("Token: checking..."), size: 10).foregroundStyle(Theme.Text.tertiary(contrast))
        } else if let status = tokenStatuses[profileName] {
            Mono(text: tokenStatusText(status), size: 10)
                .foregroundStyle(tokenStatusColor(status))
        }
    }

    private func tokenStatusText(_ status: TokenStatus) -> String {
        if status.keychainLocked {
            return L("Token: login keychain is locked. \(FailureCause.keychainLockedHint)")
        }
        guard status.isValid else {
            return L("Token: not authenticated")
        }
        guard let exp = status.expiresAt else {
            return L("Token: valid (no expiry)")
        }
        if exp <= tokenClock {
            return L("Token: expired")
        }
        return L("Token valid until \(Self.mediumShortFormatter.string(from: exp))")
    }

    private static let mediumShortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func tokenStatusColor(_ status: TokenStatus) -> Color {
        if status.keychainLocked { return Theme.Colors.warn }
        guard status.isValid else { return Theme.Text.tertiary(contrast) }
        if let exp = status.expiresAt, exp <= tokenClock { return Theme.Colors.warn }
        return Theme.Colors.ok
    }

    /// Demo tokens were issued at the demo's reference time, and read against
    /// the real clock they would all be expired.
    private var tokenClock: Date {
        workspace.demoMode ? DemoData.referenceDate : Date()
    }

    private func loadTokenStatuses() async {
        let bridge = CLIBridge()
        let names = workspace.profiles.filter { $0.status != .error }.map(\.name)
        await Self.probeTokenStatuses(
            for: names,
            probe: { name in await bridge.tokenStatus(for: name) },
            setChecking: { name, on in
                if on {
                    loadingTokenProfiles.insert(name)
                } else {
                    loadingTokenProfiles.remove(name)
                }
            },
            onStatus: { name, status in tokenStatuses[name] = status }
        )
    }

    /// Probes each profile in turn until the task is cancelled (Settings closed or its profile
    /// changed): no jamf-cli run starts after that, and the cancelled run's result is dropped.
    static func probeTokenStatuses(
        for names: [String],
        probe: (String) async -> TokenStatus?,
        setChecking: (String, Bool) -> Void,
        onStatus: (String, TokenStatus) -> Void
    ) async {
        for name in names {
            if Task.isCancelled { return }
            setChecking(name, true)
            let status = await probe(name)
            // A terminated jamf-cli reads as an invalid token, which is not what the profile has.
            // The task that replaced this one reset the flags and owns them, so leave them be.
            if Task.isCancelled { return }
            setChecking(name, false)
            if let status { onStatus(name, status) }
        }
    }

    /// Reports a newer stable release and never installs one (`AppUpdateCheck`).
    private var appUpdatesCard: some View {
        let updates = AppUpdateModel.shared
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("App updates"))
                settingsRow(
                    label: L("Check for updates"),
                    sub: updates.isForcedByProfile
                        ? ManagedPreference.note
                        : L("Once a day, stable releases only. Nothing is downloaded or installed."),
                    trailing: PNPToggle(isOn: Binding(
                        get: { updates.isEnabled }, set: { updates.setEnabled($0) }
                    ))
                    .disabled(updates.isForcedByProfile)
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: L("Status"),
                    sub: updates.statusText,
                    trailing: HStack(spacing: 8) {
                        if let page = updates.latest?.page, updates.isEnabled {
                            PNPButton(title: L("View release"), icon: "arrow.up.right.square",
                                      size: .sm) {
                                NSWorkspace.shared.open(page)
                            }
                            .help("Open the release notes on GitHub. Nothing is downloaded.")
                        }
                        PNPButton(title: L("Check now"), size: .sm) {
                            Task { await updates.checkNow() }
                        }
                        .disabled(!updates.isEnabled || updates.isChecking)
                        .help("Ask GitHub for the latest stable release now.")
                    }
                )
            }
        }
    }

    private var aboutCard: some View {
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: L("Open Source"), tone: .gold)
                    SectionHeader(title: "jamf-reports-community")
                    HStack(spacing: 4) {
                        Text("A GUI for the open-source")
                        Text("jamf-reports-community").foregroundStyle(Theme.Colors.goldBright)
                            .font(.footnote.monospaced())
                        Text("project.")
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(maxWidth: 620, alignment: .leading)

                    Text(Self.commandLineBlurb)
                        .font(.callout)
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(maxWidth: 620, alignment: .leading)

                    HStack(spacing: 14) {
                        metaPair(label: L("App:"), value: appVersion)
                        metaPair(label: "jamf-cli:", value: workspace.demoMode
                                 ? "demo" : workspace.jamfCLIVersion ?? L("not found"))
                        metaPair(label: L("Maintainer:"), value: L("@tonyyo11"))
                        metaPair(label: L("License:"), value: L("MIT"))
                    }
                    .padding(.top, 4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    PNPButton(title: L("View on GitHub"), icon: "arrow.up.right.square") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community")
                    }
                    .help("Open the project's GitHub repository.")
                    PNPButton(title: L("Read the docs"), icon: "chevron.left.forwardslash.chevron.right") {
                        openURL("https://github.com/tonyyo11/jamf-reports-community#readme")
                    }
                    .help("Open the README and setup guide on GitHub.")
                    PNPButton(title: L("Release notes"), icon: "bolt") {
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
        if let reason = profile.unusableReason { return reason }
        let product = profile.product.displayName
        if profile.authMethod.isEmpty { return L("\(product) profile") }
        return "\(product) · \(profile.authMethod)"
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
                SectionHeader(title: L("Data & Charts"))
                settingsRow(
                    label: L("Default trend range"),
                    sub: trendRangeManaged ? ManagedPreference.note
                        : L("Applies to Overview and Trends until you change the picker in-view."),
                    trailing: trendRangePicker
                )
                Divider().background(Theme.Hairline.standard)
                settingsRow(
                    label: L("Skip expensive collections"),
                    sub: skipExpensiveManaged
                        ? ManagedPreference.note : skipExpensiveCollectionsSubtitle,
                    trailing: PNPToggle(isOn: $skipExpensiveCollections)
                        .disabled(skipExpensiveManaged)
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
        .disabled(trendRangeManaged)
    }

    private var trendRangeManaged: Bool { ManagedPreference.isForced("defaultTrendRange") }
    private var skipExpensiveManaged: Bool {
        ManagedPreference.isForced("skipExpensiveCollections")
    }
    private var hiddenTabsManaged: Bool { ManagedPreference.isForced("hiddenTabs") }

    /// The app is also the `jamf-reports` command-line tool (one binary, installed from the
    /// Command-line tool card above); jamf-cli, which supplies the data, is separate.
    nonisolated static let commandLineBlurb =
        L("This app includes its own jamf-reports command-line tool, so reports, collection, backups and diagnostics can be scripted. Both use the same config.yaml and report engine. The fleet data comes from jamf-cli, which is installed separately.")

    private var skipExpensiveCollectionsSubtitle: String {
        Self.skipExpensiveSubtitle(skipping: skipExpensiveCollections)
    }

    /// What the switch does in its current position, naming the commands from the engine's own
    /// list (`ReportEngine.expensivePerDeviceKinds`) so the text cannot fall behind it. Begins
    /// with the position, so it never reads as the opposite of the switch's label.
    nonisolated static func skipExpensiveSubtitle(skipping: Bool) -> String {
        let kinds = ReportEngine.expensivePerDeviceKinds.sorted()
        let list = L("\(kinds.count) per-device commands (\(kinds.joined(separator: ", ")))")
        if skipping {
            return L("On: manual refreshes skip the \(list), so the screens built on them keep their last cached values until a collect runs them. Scheduled collects still run them.")
        }
        return L("Off: every collect runs the \(list), which can be slow on a large on-prem server. Turn on to skip them on manual refreshes.")
    }

    // MARK: - Diagnostics

    private var diagnosticsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Diagnostics"))
                Text(
                    "Generate a redacted zip of recent logs, summaries, config, and versions to share when reporting issues. Credentials are always redacted; hostnames, serials, emails, and device names are replaced with stable hash placeholders by default."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if isGeneratingBundle {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Generating diagnostic bundle")
                        Text("Generating bundle…")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        // Both act on the real workspace under the demo
                        // profile's name, which demo mode never touches.
                        PNPButton(
                            title: L("Generate diagnostic bundle now"),
                            icon: "archivebox",
                            size: .sm
                        ) {
                            generateDiagnosticBundleNow()
                        }
                        .disabled(workspace.profile.isEmpty || workspace.demoMode)
                        .help(workspace.demoMode
                              ? DemoData.liveOnlyHelp
                              : "Build the redacted diagnostic zip in this profile's workspace and reveal it in Finder. Runs entirely in-app — no Terminal needed.")
                        .accessibilityHint(
                            "Generates a redacted diagnostic bundle and reveals it in Finder.")
                    }
                }

                HStack(spacing: 8) {
                    PNPButton(title: L("Reveal Workspace"), size: .sm) {
                        guard !workspace.demoMode, let url = currentWorkspaceURL else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .disabled(workspace.demoMode || currentWorkspaceURL == nil)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : "Open the active workspace directory in Finder.")
                }

                if let msg = diagnosticBundleMessage {
                    Text(msg)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    PNPButton(title: L("Restore in-app tips"), icon: "lightbulb", size: .sm) {
                        let ok = AppTips.resetAll()
                        tipsResetConfirmation = ok
                            ? L("In-app tips restored — they'll reappear as you visit each screen.")
                            : L("Couldn't reset the tips datastore.")
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
                SectionHeader(title: L("Logging"))
                Text("View recent log entries and turn on verbose diagnostics.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.managedLoggingText(managedLogging))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    PNPButton(title: L("Reveal MDM profile"), icon: "doc.badge.gearshape", size: .sm) {
                        revealDebugProfile()
                    }
                    .help("Reveal the bundled debug-logging .mobileconfig in Finder for Jamf deployment.")
                    Text("Deploying it through MDM keeps debug and info messages; private values stay hidden.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                oneMacLoggingCommands

                Divider().background(Theme.Hairline.standard)
                LogViewerView()

                Divider().background(Theme.Hairline.standard)
                consoleInstructions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Logging")
        .onAppear { managedLogging = DebugLoggingService.managed() }
    }

    @ViewBuilder private var oneMacLoggingCommands: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turn on verbose logs on this Mac").font(.caption.weight(.semibold))
            loggingCommandRow(DebugLoggingService.enableCommand)
            loggingCommandRow(DebugLoggingService.resetCommand)
            Text("Needs an administrator and applies to this Mac. The reset command returns logging to the default.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loggingCommandRow(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Mono(text: command, size: 11)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            PNPButton(title: L("Copy"), icon: "doc.on.doc", size: .sm) {
                SystemActions.copyToClipboard(command)
            }
            .help("Copy the command to the clipboard.")
        }
    }

    /// Names what a deployed logging profile sets for this app, or that none does.
    nonisolated static func managedLoggingText(_ managed: ManagedDebugLogging?) -> String {
        guard let managed else { return L("No configuration profile sets logging for Jamf Reports.") }
        func onOff(_ value: Bool?) -> String {
            value.map { $0 ? "on" : "off" } ?? L("not set")
        }
        let base = L("A configuration profile sets logging for Jamf Reports: verbose logs \(onOff(managed.persistVerbose)), private data \(onOff(managed.revealPrivate)).")
        guard managed.revealPrivate == true else { return base }
        return base + L(" Private values (server names, paths, account names) are written to this Mac's unified log.")
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

    nonisolated static let aiInsightsBlurb: String =
        L("Turn already-collected fleet data into plain-language insight cards on Overview, Trends, Audit, Security Posture and Compliance Posture, using the On-Device Foundation Model (Apple Intelligence). Off by default. The model runs on this Mac and nothing leaves it.")

    /// Turns already-collected fleet data into plain-language insight cards on
    /// five screens. Off by default; requires macOS 27, where Apple's on-device
    /// Foundation Model generates it. Persists to this profile's `config.yaml`
    /// (`ai:` block) via `AIConfigWriter`, scoped to just that key, not the
    /// Config-tab's managed-key round-trip.
    private var aiInsightsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("AI Insights"))
                Text(Self.aiInsightsBlurb)
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)

                // Saving writes the `ai:` block of the profile's config.yaml.
                Toggle("Enable AI insights", isOn: Binding(
                    get: { aiConfig.isEnabled },
                    set: { aiConfig.enabled = $0; saveAIConfig() }))
                    .disabled(workspace.demoMode || AIPolicy.locksSettings())
                    .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")

                if aiConfig.isEnabled {
                    // No model picker: the app offers only Apple's on-device model, so
                    // there is nothing to choose between. The row states what will
                    // happen rather than offering a one-option control.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AIInsightCard.providerName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Runs entirely on this Mac. No fleet data leaves the device.")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    reportSummaryToggle
                }

                if let note = AIPolicy.settingsNote() {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                if !AIPolicy.locksSettings() {
                    Text(ModelAvailability.current(for: aiConfig).message)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }

                aiSaveStatus
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI Insights")
        .task(id: workspace.profile) {
            // A config.yaml under a demo profile's name is not the demo's.
            aiConfig = workspace.demoMode
                ? AIConfig() : AIConfigLoader.load(profile: workspace.profile)
            aiSaveMessage = nil
            aiSaveNote = nil
        }
    }

    /// `ai.include_in_reports`: off, the insight cards stay on and reports keep to the figures.
    private var reportSummaryToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Include the AI summary in reports", isOn: Binding(
                get: { aiConfig.includeInReports ?? false },
                set: { aiConfig.includeInReports = $0; saveAIConfig() }))
                .disabled(workspace.demoMode || AIPolicy.locksSettings())
            Text("Adds a model-written paragraph to the HTML and PDF reports you generate here. It can misstate a figure; scheduled reports never include it.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var aiSaveStatus: some View {
        if let aiSaveMessage { aiStatusLine(aiSaveMessage) }
        if let line = aiSaveNote?.line(for: workspace.profile) { aiStatusLine(line) }
    }

    private func aiStatusLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.Colors.warn)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveAIConfig() {
        guard !workspace.demoMode else { return }
        do {
            let profile = workspace.profile
            let written = try AIConfigWriter.save(aiConfig, profile: profile)
            aiSaveMessage = nil
            if let saved = written.report.note(for: profile) { aiSaveNote = saved }
        } catch {
            aiSaveMessage = L("Couldn't save AI settings: \(error.localizedDescription)")
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
        guard !workspace.demoMode else { return }
        guard !profile.isEmpty else {
            diagnosticBundleMessage = L("Select a workspace profile first.")
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
                    ? L("Bundle written to \(url.lastPathComponent) and revealed in Finder.")
                    : L("Bundle written to \(url.lastPathComponent) in ~/Library/Logs/JamfReports/diagnostics (Finder reveal was blocked).")
            } catch {
                diagnosticBundleMessage =
                    L("Diagnostic bundle failed: \(error.localizedDescription). Verify ~/Library/Logs/JamfReports/diagnostics is writable and has free space.")
            }
            isGeneratingBundle = false
        }
    }

    // MARK: - Experimental features

    /// Collapsible section listing opt-in preview features. Each feature has a
    /// toggle, a description and a discussion link; all are off by default.
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
                    SectionHeader(title: L("Experimental Features"))
                }
                .accessibilityHint("Opt-in toggles for preview features")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Experimental features")
    }

    private func experimentalFeatureRow(
        _ feature: ExperimentalFeatureService.Feature
    ) -> some View {
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
                PNPToggle(isOn: toggleBinding, label: L("\(feature.displayName) toggle"))
            }
            Text(feature.description)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
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

    /// The inventory tab as this workspace's sidebar names it: Devices on Jamf School.
    private var inventoryTabLabel: String {
        (workspace.isSchoolWorkspace ? Tab.schoolDevices : Tab.devices).label
    }

    private var sidebarVisibilityCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: L("Sidebar Visibility"))
                    Spacer()
                    PNPButton(title: L("Show all"), size: .sm) {
                        var v = TabVisibility.parse(hiddenTabsRaw)
                        v.showAll()
                        hiddenTabsRaw = v.serialize()
                    }
                    .disabled(hiddenTabsManaged)
                    .help(hiddenTabsManaged
                          ? ManagedPreference.note : "Restore every hidden tab to the sidebar.")
                }
                Text(hiddenTabsManaged ? ManagedPreference.note
                     : "Hide dashboards you don't use. Core tabs (Overview, \(inventoryTabLabel), Data Sources, Settings) cannot be hidden.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                ForEach(
                    SettingsView.toggleableGroups(
                        school: workspace.isSchoolWorkspace,
                        protectConnected: workspace.protectConnected),
                    id: \.label
                ) { group in
                    visibilityGroupRow(label: group.label, tabs: group.tabs)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar visibility settings")
    }

    /// The sidebar's own groups less the tabs that cannot be hidden and those the workspace
    /// does not have (a Jamf School workspace's Jamf Pro tabs), so a tab added to
    /// `Tab.navGroups` gets a switch here with no second list to forget (Groups & Searches
    /// had none). A group left with no tab to switch is dropped.
    nonisolated static func toggleableGroups(
        school: Bool, protectConnected: Bool = false
    ) -> [(label: String, tabs: [Tab])] {
        let available = TabVisibility()
            .limited(toSchool: school, protectConnected: protectConnected)
        return Tab.navGroups.compactMap { group in
            let tabs = group.items.filter { !$0.isCoreTab && available.isAvailable($0) }
            return tabs.isEmpty ? nil : (label: group.label, tabs: tabs)
        }
    }

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
                label: L("\(tab.label) visibility")
            )
            .disabled(hiddenTabsManaged)
        }
        .padding(.vertical, 2)
    }
}
