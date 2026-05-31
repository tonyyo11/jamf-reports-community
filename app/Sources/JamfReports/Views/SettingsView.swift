import SwiftUI
import AppKit
import UniformTypeIdentifiers

private final class TextLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ text: String) { lock.withLock { _lines.append(text) } }
    var lines: [String] { lock.withLock { _lines } }
}

/// PR-23 T-23: per-row selection in the custom per-report cadence editor.
/// The three real tiers plus a Never option (the kill switch — maps to
/// `cadence: .never`, tier irrelevant).
private enum CustomTierChoice: String, CaseIterable, Identifiable {
    case refresh, inventory, scan, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .refresh:   return "Refresh"
        case .inventory: return "Inventory"
        case .scan:      return "Scan"
        case .never:     return "Never"
        }
    }
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
    // Legacy v3.5 history import (LegacyHistoryImporter).
    @State private var legacyImportMessage: String? = nil
    @State private var isImportingLegacyHistory = false
    // PR-23 T-21: collection cadence preset for the active profile.
    @State private var cadencePreset: CadencePreset = .onPrem
    @State private var pendingPreset: CadencePreset? = nil
    @State private var presetWriteError: String? = nil
    // PR-23 T-23: per-report cadence table, shown when preset is .custom.
    @State private var customCadence: [String: PerReportCadence] = [:]
    @State private var customCadenceMessage: String? = nil
    // PR-23 T-25: legacy collect_skip migration notice.
    @State private var hasLegacyCollectSkip = false
    @AppStorage("collectSkipMigrationBannerDismissed")
    private var migrationBannerDismissed = false

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

                migrationBanner

                HStack(alignment: .top, spacing: 14) {
                    cliCard
                    connectionsCard
                }
                dataAndChartsCard
                performanceCard
                diagnosticsCard
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
            workspace.reloadFromDisk()
            testResults = [:]
            loadCadencePreset()
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

    // MARK: - Migration banner (PR-23 T-25)

    /// One-time notice that the active profile's config still carries the
    /// legacy `jamf_cli.collect_skip` key. It is read transparently (PR-22
    /// T-12 folds it into per-report cadence), but saving a preset under
    /// Performance rewrites the file onto the new schema and removes it —
    /// at which point this banner stops appearing on its own. The Dismiss
    /// button is for operators who want to acknowledge without acting.
    ///
    /// Never shows on fresh installs: `hasLegacyCollectSkip` is only true
    /// when the key is physically present in config.yaml.
    @ViewBuilder
    private var migrationBanner: some View {
        if hasLegacyCollectSkip && !migrationBannerDismissed {
            Card(padding: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.Colors.goldBright)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Collection settings migrated")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("This profile's jamf_cli.collect_skip is now read as "
                             + "per-report cadence. Review it under Performance below; "
                             + "saving a preset there finalizes the migration.")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    PNPButton(title: "Dismiss", size: .sm) {
                        migrationBannerDismissed = true
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Collection settings migration notice")
        }
    }

    // MARK: - Performance (PR-23 T-21)

    private var performanceCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Performance")
                Text("Collection cadence preset for the active profile (\(workspace.profile)). "
                     + "Controls how often scheduled runs fetch each tier of jamf-cli data.")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))

                Picker("Cadence preset", selection: cadencePresetBinding) {
                    ForEach(CadencePreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(cadencePreset.displaySubtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))

                Divider().background(Theme.Hairline.standard)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolved cadences")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    Text(cadencePreset.cadenceSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }

                if let presetWriteError {
                    Text(presetWriteError)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warn)
                }

                if cadencePreset == .custom {
                    Divider().background(Theme.Hairline.standard)
                    customCadenceEditor
                }
            }
        }
        .confirmationDialog(
            "Change cadence preset?",
            isPresented: presetDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Switch to \(pendingPreset?.displayName ?? "")") {
                commitPendingPreset()
            }
            Button("Cancel", role: .cancel) { pendingPreset = nil }
        } message: {
            Text("Scheduled runs for '\(workspace.profile)' will adopt the new "
                 + "cadence on their next fire. Snapshots already collected are "
                 + "not affected.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Performance settings")
    }

    /// Picker binding that defers the actual change to a confirmation
    /// dialog: `set` stashes `pendingPreset` rather than committing, so the
    /// radio visually stays put until the operator confirms.
    private var cadencePresetBinding: Binding<CadencePreset> {
        Binding(
            get: { cadencePreset },
            set: { newValue in
                guard newValue != cadencePreset else { return }
                pendingPreset = newValue
            }
        )
    }

    private var presetDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingPreset != nil },
            set: { if !$0 { pendingPreset = nil } }
        )
    }

    private func commitPendingPreset() {
        guard let target = pendingPreset else { return }
        do {
            try ConfigService.setCadencePreset(profile: workspace.profile, preset: target)
            cadencePreset = target
            presetWriteError = nil
            // setCadencePreset rewrites the file without jamf_cli.collect_skip,
            // so the migration notice no longer applies (T-25).
            hasLegacyCollectSkip = false
        } catch {
            presetWriteError = "Could not save preset: \(error.localizedDescription)"
        }
        pendingPreset = nil
    }

    /// Read the active profile's preset from config.yaml. Absent block or
    /// unreadable config falls back to on-prem (the conservative default,
    /// matching CadenceResolver's missing-config behavior).
    ///
    /// Also seeds the custom per-report table: existing `per_report`
    /// overrides layered over the current preset's resolved defaults, so
    /// every known kind has a row whether or not the operator has touched
    /// the editor before.
    private func loadCadencePreset() {
        presetWriteError = nil
        customCadenceMessage = nil
        let config: ReportConfig? = {
            guard let url = try? ConfigService.configURL(for: workspace.profile),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? ConfigLoader.load(from: url)
        }()
        cadencePreset = config?.collectCadence?.preset ?? .onPrem

        var table = CollectCadenceConfig.customDefaults(basePreset: cadencePreset)
        if let existing = config?.collectCadence?.perReport {
            for (kind, entry) in existing { table[kind] = entry }
        }
        customCadence = table

        // T-25: the banner shows while the legacy key is physically in the
        // file. A preset save (which removes it) clears this on next load.
        hasLegacyCollectSkip = config?.jamfCli?.collectSkip?.isEmpty == false
    }

    // MARK: - Custom per-report editor (PR-23 T-23)

    /// The four standard preset cadences offered in the per-report editor.
    private static let standardCadenceChoices: [Int] = [43_200, 86_400, 172_800, 604_800]

    /// Cadence values the per-report picker offers: the standard four, plus
    /// any non-standard `.seconds` value already present in the loaded
    /// config. Including in-config values means a hand-edited interval
    /// (e.g. `overview: 3600`) stays selectable rather than being silently
    /// rounded to a standard value on first edit. Sorted ascending.
    private var customCadenceChoices: [Int] {
        var values = Set(Self.standardCadenceChoices)
        for entry in customCadence.values {
            if case .seconds(let seconds) = entry.cadence, seconds > 0 {
                values.insert(seconds)
            }
        }
        return values.sorted()
    }

    private var customCadenceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-report cadence")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Text.primary)
            Text("Each report's tier and how often it's fetched. "
                 + "Set a report to Never to skip it entirely.")
                .font(.caption.monospaced())
                .foregroundStyle(Theme.Text.tertiary(contrast))

            ForEach(ReportEngine.knownCollectKinds.sorted(), id: \.self) { kind in
                customCadenceRow(kind: kind)
            }

            HStack {
                if let customCadenceMessage {
                    Text(customCadenceMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                Spacer()
                PNPButton(title: "Save per-report cadence", size: .sm) {
                    saveCustomCadence()
                }
            }
        }
    }

    private func customCadenceRow(kind: String) -> some View {
        HStack(spacing: 8) {
            Text(kind)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.Text.primary)
            Spacer()
            Picker("", selection: tierChoiceBinding(kind)) {
                ForEach(CustomTierChoice.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)

            Picker("", selection: cadenceSecondsBinding(kind)) {
                ForEach(customCadenceChoices, id: \.self) { secs in
                    Text(CadencePreset.humanCadence(seconds: secs)).tag(secs)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            .disabled(tierChoiceBinding(kind).wrappedValue == .never)
        }
        .padding(.vertical, 2)
    }

    /// Tier-or-Never selection for one report row. `.never` maps to
    /// `cadence: .never`; the three tiers set `tier` and keep (or default)
    /// the seconds.
    private func tierChoiceBinding(_ kind: String) -> Binding<CustomTierChoice> {
        Binding(
            get: {
                let entry = customCadence[kind]
                if case .never = entry?.cadence { return .never }
                switch entry?.tier {
                case .refresh:   return .refresh
                case .inventory: return .inventory
                case .scan:      return .scan
                case nil:        return .never
                }
            },
            set: { choice in
                let current = customCadence[kind] ?? PerReportCadence(cadence: .never)
                let seconds: Int = {
                    if case .seconds(let n) = current.cadence { return n }
                    return 604_800
                }()
                switch choice {
                case .never:
                    customCadence[kind] = PerReportCadence(tier: current.tier, cadence: .never)
                case .refresh:
                    customCadence[kind] = PerReportCadence(tier: .refresh, cadence: .seconds(seconds))
                case .inventory:
                    customCadence[kind] = PerReportCadence(tier: .inventory, cadence: .seconds(seconds))
                case .scan:
                    customCadence[kind] = PerReportCadence(tier: .scan, cadence: .seconds(seconds))
                }
            }
        )
    }

    private func cadenceSecondsBinding(_ kind: String) -> Binding<Int> {
        Binding(
            get: {
                if case .seconds(let n) = customCadence[kind]?.cadence { return n }
                return 604_800
            },
            set: { seconds in
                let current = customCadence[kind] ?? PerReportCadence(cadence: .never)
                customCadence[kind] = PerReportCadence(
                    tier: current.tier, cadence: .seconds(seconds)
                )
            }
        )
    }

    private func saveCustomCadence() {
        do {
            try ConfigService.setCustomCadence(
                profile: workspace.profile, perReport: customCadence
            )
            customCadenceMessage = "Saved."
        } catch {
            customCadenceMessage = "Save failed: \(error.localizedDescription)"
        }
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
                    PNPButton(title: "Copy Diagnostic Command", icon: "doc.on.clipboard", size: .sm) {
                        runDiagnosticBundle()
                    }
                    .help(
                        "Copies the diagnostic-bundle command to your clipboard and opens Terminal. " +
                        "Paste and run to generate the bundle on your Desktop."
                    )
                    .accessibilityHint("Copies a diagnostic-bundle command to the clipboard and opens Terminal.")

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

                Divider().background(Theme.Hairline.standard)

                legacyImportSection
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diagnostics")
    }

    // MARK: - Legacy v3.5 history import

    /// Affordance to migrate a v3.5 `fleet_health_metrics_history.json` into
    /// the active profile's summaries directory so TrendsView gains historical
    /// data on day one without re-running collections.
    ///
    /// Isolation safety (Swift 6.1): `LegacyHistoryImporter` is `Sendable` and
    /// `importHistory(from:forProfile:)` is a `static func` with no captured
    /// actor state. The blocking file I/O runs inside `Task.detached` (outside
    /// `@MainActor`) so it doesn't hold the main actor during disk reads/writes.
    /// The `await .value` resumes on `@MainActor` to write UI state, which is
    /// safe because `Outcome` and `String` are both `Sendable`.
    @ViewBuilder
    private var legacyImportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("v3.5 History Migration")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Text.primary)
            Text(
                "Import a fleet_health_metrics_history.json from the previous v3.5 " +
                "dashboard into the active profile's Trends data. Existing daily " +
                "summaries are not overwritten."
            )
            .font(.caption.monospaced())
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if isImportingLegacyHistory {
                    ProgressView().controlSize(.small)
                    Text("Importing…")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    PNPButton(
                        title: "Migrate from v3.5 history…",
                        icon: "arrow.down.doc",
                        size: .sm
                    ) {
                        pickLegacyHistoryFile()
                    }
                    .disabled(workspace.profile.isEmpty)
                    .help(
                        "Pick a fleet_health_metrics_history.json file and import its entries " +
                        "into the active profile's snapshot directory."
                    )
                }
            }

            if let msg = legacyImportMessage {
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pickLegacyHistoryFile() {
        let panel = NSOpenPanel()
        panel.title = "Select fleet_health_metrics_history.json"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = LegacyHistoryImporter.defaultHistoryURL
            .deletingLastPathComponent()
        panel.begin { [profile = workspace.profile] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await self.runLegacyImport(from: url, profile: profile)
            }
        }
    }

    private func runLegacyImport(from url: URL, profile: String) async {
        isImportingLegacyHistory = true
        legacyImportMessage = nil
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try LegacyHistoryImporter.importHistory(from: url, forProfile: profile)
            }.value
            let parts: [String] = [
                "\(outcome.imported.count) snapshot(s) imported",
                outcome.skipped.isEmpty ? nil : "\(outcome.skipped.count) already existed",
                outcome.invalid.isEmpty ? nil : "\(outcome.invalid.count) unreadable date(s)",
            ].compactMap { $0 }
            legacyImportMessage = parts.joined(separator: " · ")
        } catch {
            legacyImportMessage = "Import failed: \(error.localizedDescription)"
        }
        isImportingLegacyHistory = false
    }

    /// Active workspace root, or nil if no profile is selected.
    private var currentWorkspaceURL: URL? {
        let profile = workspace.profile
        guard !profile.isEmpty, let url = ProfileService.workspaceURL(for: profile) else {
            return nil
        }
        return url
    }

    /// Build the diagnostic-bundle CLI command for the active workspace and
    /// hand it off to Terminal via the clipboard, matching the "Add connection"
    /// pattern. The Python CLI is the source of truth; the app is a launcher.
    private func runDiagnosticBundle() {
        guard let workspaceURL = currentWorkspaceURL else {
            diagnosticBundleMessage = "Select a workspace profile first."
            return
        }
        let configPath = workspaceURL.appendingPathComponent("config.yaml").path
        let result = SettingsView.buildDiagnosticBundleCommand(
            configPath: configPath,
            bundledScriptURL: SettingsView.bundledDiagnosticScriptURL()
        )
        SystemActions.copyToClipboard(result.command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", "-n"]
        do {
            try process.run()
            diagnosticBundleMessage = result.successMessage
        } catch {
            diagnosticBundleMessage =
                "Command copied — could not open Terminal automatically. " +
                "Paste it into a Terminal window manually."
        }
    }

    /// Locate `jamf-reports-community.py` inside the bundled `.app` so the
    /// emitted command uses an absolute path and works regardless of the
    /// user's Terminal cwd. Returns `nil` for dev builds (`swift run`) and
    /// for any bundle layout that doesn't include the script — the caller
    /// then falls back to the relative-path command.
    nonisolated static func bundledDiagnosticScriptURL() -> URL? {
        Bundle.main.url(forResource: "jamf-reports-community", withExtension: "py")
    }

    /// Pure-function command + toast builder so PR-19's bundled-script
    /// behavior is testable without launching Terminal. `bundledScriptURL`
    /// is the absolute path to `jamf-reports-community.py` inside
    /// `Contents/Resources` of the running `.app` bundle, or `nil` for dev
    /// builds where bundling doesn't apply.
    nonisolated static func buildDiagnosticBundleCommand(
        configPath: String,
        bundledScriptURL: URL?
    ) -> (command: String, successMessage: String) {
        if let scriptURL = bundledScriptURL {
            // Shell-escape both paths with single quotes; embedded single
            // quotes in either path become `'\''`. Workspace paths under
            // `~/Jamf-Reports/<slug>/` never contain single quotes given the
            // slug regex, but config paths supplied via custom seed could.
            let command =
                "python3 '\(shellEscape(scriptURL.path))' " +
                "diagnostic-bundle --config '\(shellEscape(configPath))'"
            let message =
                "Command copied. Paste it in the Terminal window that just opened. " +
                "It uses the script bundled inside the app, so any working directory " +
                "is fine. The zip will land on your Desktop."
            return (command, message)
        }
        // Dev-build fallback: relative path, with a hint to cd first.
        let command =
            "python3 jamf-reports-community.py diagnostic-bundle " +
            "--config '\(shellEscape(configPath))'"
        let message =
            "Command copied. Paste it in the Terminal window that just opened. " +
            "cd to your jamf-reports-community checkout first (this is a dev build " +
            "without the script bundled). The zip will land on your Desktop."
        return (command, message)
    }

    /// Escape single-quote characters for single-quoted shell strings:
    /// `'` becomes `'\''`. Leaves everything else untouched — single-quoted
    /// strings in POSIX shells are otherwise literal.
    nonisolated private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
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
