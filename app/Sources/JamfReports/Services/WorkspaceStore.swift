import SwiftUI

/// Per-profile state that every screen reads. Owned by the app shell so a profile
/// switch (sidebar bottom chip) re-routes every view to a different workspace's data.
@MainActor
@Observable
final class WorkspaceStore {

    var org: Org
    var profile: String
    var profiles: [JamfCLIProfile]
    var schedules: [Schedule]
    var sheetCatalog: [SheetGroup]
    var customEAs: [CustomEA]
    var columnMappings: [ColumnMapping]
    var demoMode: Bool
    var selectedScoreCards: [TrendSeries.Metric]
    var jamfCLIPath: String?
    var jamfCLIVersion: String?
    var jamfCLIInstallSource: String?
    var jamfCLIUpdateMessage: String?
    var jamfCLIUpdateAvailable: Bool = false
    var isUpdatingJamfCLI: Bool = false
    var jrcPath: String?
    var isInitializingWorkspace: Bool = false
    var workspaceInitMessage: String?
    var launchAgentCleanupMessage: String?
    private var didAutoUpdateJamfCLI = false
    private static let forceDemoModeKey = "com.jamfreports.forceDemoMode"

    /// True when the active profile has a `config.yaml` on disk under
    /// `~/Jamf-Reports/<profile>/`. Demo profiles always report `true` because
    /// they don't have an on-disk workspace to initialize.
    var isWorkspaceInitialized: Bool {
        if demoMode { return true }
        guard let url = ProfileService.workspaceURL(for: profile) else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("config.yaml").path
        )
    }

    // MARK: Config state

    /// Editable config fields. Binds directly to ConfigView inputs.
    var configState: ConfigState = .defaultState
    /// Non-nil after a save or load error; cleared on success.
    var configError: String?

    // Last parsed document (preserves unknown keys + original text for round-trip).
    private var _loadedDoc: YAMLCodec.YAMLDocument?
    // Snapshot of state at last load/save — used by revert().
    private var _savedState: ConfigState?

    // MARK: Column label / required metadata

    private static let columnLabels: [String: String] = [
        "computer_name":     "Computer Name",
        "serial_number":     "Serial Number",
        "operating_system":  "Operating System",
        "last_checkin":      "Last Check-in",
        "department":        "Department",
        "manager":           "Manager",
        "email":             "Email",
        "filevault":         "FileVault Status",
        "sip":               "SIP Status",
        "firewall":          "Firewall Enabled",
        "gatekeeper":        "Gatekeeper",
        "secure_boot":       "Secure Boot",
        "bootstrap_token":   "Bootstrap Token",
        "disk_percent_full": "Disk % Full",
        "architecture":      "Architecture",
        "model":             "Model",
        "last_enrollment":   "Last Enrollment",
        "mdm_expiry":        "MDM Profile Expiry",
    ]

    private static let requiredColumnKeys: Set<String> = [
        "computer_name", "serial_number", "operating_system", "last_checkin",
    ]

    // MARK: Init

    init(demoMode: Bool? = nil) {
        let cleanup = LaunchAgentService.cleanupLegacyAgents()
        let realProfiles = ProfileService.discoverLocal()
        let realSchedules = LaunchAgentService.list()
        let isDemo = demoMode ?? realProfiles.isEmpty

        self.demoMode = isDemo
        self.org = isDemo ? DemoData.org : Self.org(for: realProfiles.first)
        self.profile = isDemo ? DemoData.org.profile : (realProfiles.first?.name ?? DemoData.org.profile)
        self.profiles = isDemo ? DemoData.cliProfiles : realProfiles
        self.schedules = isDemo ? DemoData.scheduledRuns : realSchedules
        self.sheetCatalog = DemoData.sheetCatalog
        self.customEAs = DemoData.customEAs
        self.columnMappings = DemoData.columnMappings
        self.selectedScoreCards = [.activeDevices, .fileVault, .compliance, .stale]
        let jamfCLI = JamfCLIInstaller.currentInstallation()
        self.jamfCLIPath = jamfCLI?.path
        self.jamfCLIVersion = jamfCLI?.version
        self.jamfCLIInstallSource = jamfCLI?.source.label
        self.jrcPath = CLIBridge().jrcDisplayPath()
        self.launchAgentCleanupMessage = cleanup.message
    }

    // MARK: Profile switching

    func setProfile(_ id: String) {
        guard ProfileService.isValid(id) else { return }
        profile = id
        if !demoMode {
            org = Self.org(for: profiles.first(where: { $0.name == id }))
        }
        if !demoMode {
            schedules = LaunchAgentService.list().filter { $0.profile == id }
            Task {
                do { try await loadConfig() } catch {
                    configError = error.localizedDescription
                }
            }
        }
    }

    /// Reload from disk — called from the sidebar refresh and after onboarding.
    /// Respects an explicit user demo-mode preference set via `setDemoMode(_:)`.
    func reloadFromDisk() {
        refreshToolStatus()
        let real = ProfileService.discoverLocal()
        let userForcedDemo = UserDefaults.standard.bool(forKey: Self.forceDemoModeKey)
        if real.isEmpty || userForcedDemo {
            demoMode = true
            org = DemoData.org
            profile = DemoData.org.profile
            profiles = DemoData.cliProfiles
            schedules = DemoData.scheduledRuns
        } else {
            demoMode = false
            profiles = real
            schedules = LaunchAgentService.list()
            if !real.contains(where: { $0.name == profile }) {
                profile = real.first!.name
            }
            org = Self.org(for: real.first(where: { $0.name == profile }))
        }
    }

    func setDemoMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.forceDemoModeKey)
        if enabled {
            demoMode = true
            org = DemoData.org
            profile = DemoData.org.profile
            profiles = DemoData.cliProfiles
            schedules = DemoData.scheduledRuns
        } else {
            let cleanupMessage = cleanupDemoProfileArtifacts()
            reloadFromDisk()
            if let cleanupMessage {
                launchAgentCleanupMessage = cleanupMessage
            }
        }
    }

    private func cleanupDemoProfileArtifacts() -> String? {
        let demoProfile = DemoData.org.profile
        let removedAgents = LaunchAgentService.removeAgents(profile: demoProfile)
        do {
            let removedWorkspace = try ProfileService.removeLocalWorkspace(profile: demoProfile)
            if removedWorkspace || !removedAgents.isEmpty {
                var parts: [String] = []
                if removedWorkspace {
                    parts.append("workspace \(demoProfile)")
                }
                if !removedAgents.isEmpty {
                    parts.append("\(removedAgents.count) demo LaunchAgent\(removedAgents.count == 1 ? "" : "s")")
                }
                return "Removed demo \(parts.joined(separator: " and "))."
            }
        } catch {
            if !removedAgents.isEmpty {
                return "Removed \(removedAgents.count) demo LaunchAgent"
                    + (removedAgents.count == 1 ? "" : "s")
                    + ", but could not remove workspace \(demoProfile): \(error.localizedDescription)"
            }
            return "Could not remove demo workspace \(demoProfile): \(error.localizedDescription)"
        }
        return nil
    }

    /// Run `jrc workspace-init` first so the user gets a workspace even without
    /// jamf-cli auth, then optionally chain a `collect` call when jamf-cli is
    /// available. The two failure modes are reported separately so a collect
    /// failure doesn't masquerade as a workspace-init failure.
    func initializeWorkspace() async {
        guard !demoMode, !isWorkspaceInitialized, !isInitializingWorkspace else { return }
        isInitializingWorkspace = true
        workspaceInitMessage = "Initializing workspace…"
        let bridge = CLIBridge()
        let initExit = await bridge.initializeWorkspace(profile: profile) { _ in }
        guard initExit == 0 else {
            isInitializingWorkspace = false
            workspaceInitMessage = "Workspace init failed · exit \(initExit)"
            return
        }
        reloadFromDisk()

        guard bridge.isJamfCLIAvailable else {
            isInitializingWorkspace = false
            workspaceInitMessage = "Workspace initialized · jamf-cli not installed"
            return
        }

        workspaceInitMessage = "Workspace initialized · collecting jamf-cli snapshots…"
        let collectExit = await bridge.collect(profile: profile) { _ in }
        isInitializingWorkspace = false
        if collectExit == 0 {
            workspaceInitMessage = "Workspace initialized · cached snapshots ready"
            reloadFromDisk()
        } else {
            workspaceInitMessage =
                "Workspace initialized · collect failed · exit \(collectExit) · check jamf-cli auth"
        }
    }

    func refreshToolStatus() {
        let jamfCLI = JamfCLIInstaller.currentInstallation()
        jamfCLIPath = jamfCLI?.path
        jamfCLIVersion = jamfCLI?.version
        jamfCLIInstallSource = jamfCLI?.source.label
        jrcPath = CLIBridge().jrcDisplayPath()
    }

    func checkJamfCLIUpdate() async {
        guard !isUpdatingJamfCLI else { return }
        isUpdatingJamfCLI = true
        jamfCLIUpdateMessage = "Checking jamf-cli updates..."
        let result = await JamfCLIInstaller().checkForUpdate()
        jamfCLIUpdateMessage = result.message
        jamfCLIUpdateAvailable = result.updateAvailable
        isUpdatingJamfCLI = false
        refreshToolStatus()
    }

    func updateJamfCLI() async {
        guard !isUpdatingJamfCLI else { return }
        isUpdatingJamfCLI = true
        jamfCLIUpdateMessage = "Updating jamf-cli..."
        let result = await JamfCLIInstaller().update()
        jamfCLIUpdateMessage = result.message
        jamfCLIUpdateAvailable = false
        isUpdatingJamfCLI = false
        refreshToolStatus()
    }

    func autoUpdateJamfCLIIfNeeded() async {
        guard !didAutoUpdateJamfCLI else { return }
        didAutoUpdateJamfCLI = true
        guard UserDefaults.standard.bool(forKey: "autoUpdateJamfCLI") else { return }
        await updateJamfCLI()
    }

    // MARK: Config I/O

    /// Load config.yaml for the current profile. Falls back to defaults if the
    /// file doesn't exist yet (new workspace). Other errors are rethrown.
    func loadConfig() async throws {
        do {
            let loaded = try ConfigService.load(profile: profile)
            _loadedDoc = loaded.document
            _savedState = loaded.state
            configState = loaded.state
            configError = nil
        } catch ConfigService.ConfigError.missingConfig {
            configState = .defaultState
            _loadedDoc = nil
            _savedState = nil
            configError = nil
        }
        rebuildColumnMappings()
        rebuildCustomEAs()
    }

    /// Flush current configState (+ any column mapping edits) to disk atomically.
    func saveConfig() async throws {
        syncColumnMappingsToState()
        let newDoc = try ConfigService.save(
            profile: profile,
            state: configState,
            existingDocument: _loadedDoc
        )
        _loadedDoc = newDoc
        _savedState = configState
        configError = nil
    }

    /// Discard in-memory edits and restore to the state at the last load/save.
    func revert() {
        configState = _savedState ?? .defaultState
        rebuildColumnMappings()
        rebuildCustomEAs()
        configError = nil
    }

    // MARK: Mutations

    func addSecurityAgent() {
        configState.securityAgents.append(ConfigSecurityAgent(name: "New Agent", column: "", connectedValue: ""))
    }

    func removeSecurityAgent(at index: Int) {
        configState.securityAgents.remove(at: index)
    }

    func addCustomEA() {
        configState.customEAs.append(ConfigCustomEA(
            name: "New EA Sheet",
            column: "",
            type: "text",
            trueValue: "",
            warningThreshold: "80",
            criticalThreshold: "90",
            currentVersions: [],
            warningDays: "30"
        ))
        rebuildCustomEAs()
    }

    func removeCustomEA(at index: Int) {
        configState.customEAs.remove(at: index)
        rebuildCustomEAs()
    }

    func addComplianceBenchmark() {
        configState.complianceBenchmarks.append("New Benchmark")
    }

    func removeComplianceBenchmark(at index: Int) {
        configState.complianceBenchmarks.remove(at: index)
    }

    // MARK: Private helpers

    /// Copy columnMappings.value back into configState.columns before saving.
    private func syncColumnMappingsToState() {
        for mapping in columnMappings {
            configState.columns[mapping.key] = mapping.value
        }
    }

    /// Rebuild [ColumnMapping] from configState.columns, preserving existing status badges.
    private func rebuildColumnMappings() {
        let statusByKey = Dictionary(columnMappings.map { ($0.key, $0.status) }, uniquingKeysWith: { $1 })
        columnMappings = ConfigState.columnKeys.map { key in
            let value = configState.columns[key] ?? ""
            return ColumnMapping(
                key: key,
                label: Self.columnLabels[key] ?? key,
                value: value,
                required: Self.requiredColumnKeys.contains(key),
                status: statusByKey[key] ?? (value.isEmpty ? .skip : .ok)
            )
        }
    }

    /// Rebuild [CustomEA] display models from configState.customEAs.
    private func rebuildCustomEAs() {
        customEAs = configState.customEAs.map { ea in
            CustomEA(
                name: ea.name,
                column: ea.column,
                type: CustomEA.EAType(rawValue: ea.type) ?? .text,
                warn: Int(ea.warningThreshold),
                crit: Int(ea.criticalThreshold),
                currentVersions: ea.currentVersions.isEmpty ? nil : ea.currentVersions,
                warningDays: Int(ea.warningDays),
                trueValue: ea.trueValue.isEmpty ? nil : ea.trueValue
            )
        }
    }

    private static func org(for profile: JamfCLIProfile?) -> Org {
        let name = profile?.name ?? "jamf-cli"
        let url = profile?.url ?? "(jamf-cli profile)"
        return Org(
            name: name,
            short: String(name.prefix(2)).uppercased(),
            jamfURL: url,
            profile: name,
            apiClient: profile?.authMethod ?? "",
            workspaceRoot: "~/Jamf-Reports/\(name)"
        )
    }
}

// MARK: - Tab routing

/// Routes the active screen. `Tab` is the source of truth for which detail view
/// the `NavigationSplitView` renders, and the title shown in the toolbar.
enum Tab: String, CaseIterable, Identifiable, Hashable {
    case overview, devices, trends, audit, reports, schedules, runs
    case config, customize, sources, backups, settings, onboarding

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:   "Overview"
        case .devices:    "Devices"
        case .trends:     "Trends"
        case .audit:      "Health Audit"
        case .reports:    "Generated"
        case .schedules:  "Schedules"
        case .runs:       "Run History"
        case .config:     "Config"
        case .customize:  "Customize"
        case .sources:    "Data Sources"
        case .backups:    "Backups"
        case .settings:   "Settings"
        case .onboarding: "Onboarding"
        }
    }

    var sfSymbol: String {
        switch self {
        case .overview:   "house"
        case .devices:    "laptopcomputer"
        case .trends:     "chart.line.uptrend.xyaxis"
        case .audit:      "shield.checkered"
        case .reports:    "doc.text"
        case .schedules:  "clock"
        case .runs:       "terminal"
        case .config:     "wrench.and.screwdriver"
        case .customize:  "sparkles"
        case .sources:    "externaldrive"
        case .backups:    "externaldrive.badge.timemachine"
        case .settings:   "gear"
        case .onboarding: "wand.and.stars"
        }
    }

    var badge: String? {
        switch self {
        case .devices:   "inv"
        case .trends:    "26w"
        case .reports:   "47"
        case .schedules: "5"
        default:         nil
        }
    }

    var badgeIsGold: Bool { self == .trends }
}

/// Sidebar collapse state. Persisted via `@AppStorage`. Standard macOS shortcut
/// `⌘0` cycles through the three states.
enum SidebarMode: String, CaseIterable {
    case expanded, compact, hidden

    func next() -> SidebarMode {
        switch self {
        case .expanded: .compact
        case .compact:  .hidden
        case .hidden:   .expanded
        }
    }
}
