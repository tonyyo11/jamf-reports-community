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
    /// True when the located jamf-cli binary failed the codesign-fingerprint gate.
    /// Surfaced as a distinct warning in Settings separate from the version-floor check.
    var jamfCLIVerificationFailed: Bool = false
    var jamfCLIUpdateMessage: String?
    var jamfCLIUpdateAvailable: Bool = false
    var isUpdatingJamfCLI: Bool = false
    var isInitializingWorkspace: Bool = false
    var workspaceInitMessage: String?
    var launchAgentCleanupMessage: String?
    /// Labels of JRC LaunchAgent plists whose recorded executable no longer
    /// exists on disk. Populated by `LaunchAgentService.staleExecutableLabels`
    /// during workspace refresh and on init. Drives the
    /// SchedulesView "stale executable" warning banner (PR-15). Empty when
    /// every plist's executable resolves cleanly.
    var launchAgentStaleLabels: [String] = []
    var globalStatus: String? = nil
    var toast: Toast? = nil
    /// Last known auth probe result for the active profile. `nil` while not yet
    /// checked (e.g. demo mode, or immediately after a profile switch before the
    /// async probe completes). Refreshed by `refreshAuthStatus()`.
    var authStatus: TokenStatus? = nil
    private var didAutoUpdateJamfCLI = false
    /// UserDefaults key for "user has explicitly chosen demo mode."
    /// Persisted by `setDemoMode(_:)`; consulted by `init` and
    /// `reloadFromDisk` to decide whether to enter demo on no-profiles.
    /// Internal (not private) so tests can pin/clear the value in setUp;
    /// `nonisolated` because it's a constant string with no actor-state
    /// dependency, and tests need to read it from `tearDown` (which
    /// XCTestCase requires to be non-MainActor-isolated).
    nonisolated static let forceDemoModeKey = "com.jamfreports.forceDemoMode"

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

    var initializedProfiles: [JamfCLIProfile] {
        if demoMode { return profiles }
        return profiles.filter { profile in
            guard let url = ProfileService.workspaceURL(for: profile.name) else { return false }
            return FileManager.default.fileExists(
                atPath: url.appendingPathComponent("config.yaml").path
            )
        }
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

    /// True when configState has been edited since the last save or load.
    var hasUnsavedChanges: Bool { _savedState != nil && configState != _savedState }

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
        // MFS-2: one-shot Spotlight + permissions backfill on existing
        // workspaces. Gated on a per-version UserDefaults sentinel so the
        // walk runs at most once per app version. Wave 1 covers the
        // going-forward path (`OnboardingFlow.createWorkspace`); this
        // covers the pre-existing-workspace case.
        WorkspaceMigration.runIfNeeded()

        let cleanup = LaunchAgentService.cleanupLegacyAgents()
        let realProfiles = ProfileService.discoverLocal()
        let realSchedules = LaunchAgentService.list()
        // First-launch chooser: an empty real-profile list no longer implies
        // demo mode. Only an explicit `demoMode:` override (tests) or the
        // persisted `forceDemoModeKey` (user previously chose demo) enables
        // it here. `ContentView` routes to `FirstLaunchChooserView` while
        // both `profiles` is empty and `demoMode` is false so the user can
        // make the call before any synthetic data is bound to the app state.
        let userForcedDemo = UserDefaults.standard.bool(forKey: Self.forceDemoModeKey)
        let isDemo = demoMode ?? userForcedDemo

        self.demoMode = isDemo
        self.org = isDemo ? DemoData.org : Self.org(for: realProfiles.first)
        self.profile = isDemo ? DemoData.org.profile : (realProfiles.first?.name ?? DemoData.org.profile)
        self.profiles = isDemo ? DemoData.cliProfiles : realProfiles
        self.schedules = isDemo ? DemoData.scheduledRuns : realSchedules
        self.sheetCatalog = DemoData.sheetCatalog
        self.customEAs = DemoData.customEAs
        self.columnMappings = DemoData.columnMappings
        self.selectedScoreCards = [.stability, .activeDevices, .fileVault, .compliance]
        let jamfCLI = JamfCLIInstaller.currentInstallation()
        self.jamfCLIPath = jamfCLI?.path
        self.jamfCLIVersion = jamfCLI?.version
        self.jamfCLIInstallSource = jamfCLI?.source.label
        self.jamfCLIVerificationFailed = jamfCLI?.codesignVerified == false
        self.launchAgentCleanupMessage = cleanup.message
        self.launchAgentStaleLabels = LaunchAgentService.staleExecutableLabels()
    }

    // MARK: Profile switching

    func setProfile(_ id: String) {
        guard ProfileService.isValid(id) else { return }
        profile = id
        authStatus = nil
        if !demoMode {
            org = Self.org(for: profiles.first(where: { $0.name == id }))
            // PR-24: a profile switch backfills the new profile's Refresh-tier
            // data if it's overdue. Debounced in the coordinator so rapid chip
            // cycling doesn't spawn a refresh per intermediate selection.
            observeProfileSwitchRefresh(for: id)
        }
        if !demoMode {
            schedules = LaunchAgentService.list().filter { $0.profile == id }
            Task {
                do { try await loadConfig() } catch {
                    configError = error.localizedDescription
                }
                await refreshAuthStatus()
            }
        }
    }

    /// Probes `pro auth token` for the active profile and updates `authStatus`.
    /// No-ops in demo mode. Called on profile switch and app launch.
    func refreshAuthStatus() async {
        guard !demoMode else { authStatus = nil; return }
        authStatus = await CLIBridge().tokenStatus(for: profile)
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
            launchAgentStaleLabels = LaunchAgentService.staleExecutableLabels()
            if !real.contains(where: { $0.name == profile }) {
                profile = real.first!.name
            }
            org = Self.org(for: real.first(where: { $0.name == profile }))
            Task { await refreshAuthStatus() }
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

    /// Call `ScaffoldService.writeMinimalConfig` first so the user gets a workspace
    /// even without jamf-cli auth, then optionally chain a `collect` call when
    /// jamf-cli is available. The two failure modes are reported separately so a
    /// collect failure doesn't masquerade as a workspace-init failure.
    func initializeWorkspace() async {
        guard !demoMode, !isWorkspaceInitialized, !isInitializingWorkspace else { return }
        isInitializingWorkspace = true
        workspaceInitMessage = "Initializing workspace…"
        let bridge = CLIBridge()
        let initExit: Int32
        do {
            initExit = try await bridge.initializeWorkspace(profile: profile) { _ in }
        } catch {
            isInitializingWorkspace = false
            workspaceInitMessage = "Workspace init failed · \(error.localizedDescription)"
            return
        }
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
        let collectExit: Int32
        do {
            collectExit = try await bridge.collect(profile: profile) { _ in }
        } catch {
            isInitializingWorkspace = false
            workspaceInitMessage = "Workspace initialized · collect failed · \(error.localizedDescription)"
            return
        }
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
        jamfCLIVerificationFailed = jamfCLI?.codesignVerified == false
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

    // MARK: Sidebar badge helpers

    /// Reads the device count from the most recent summary JSON for the given profile.
    /// Returns 0 if no summary exists or the file cannot be read. Does not trigger a live call.
    func deviceCount(for profile: String) -> Int {
        guard let dir = try? WorkspacePaths.summariesDir(for: profile) else { return 0 }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return 0 }
        let jsons = files.filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return aDate > bDate
            }
        guard let newest = jsons.first,
              let data = try? Data(contentsOf: newest),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = dict["total_devices"] as? Int else { return 0 }
        return count
    }

    /// Returns a human-readable relative "last synced" label derived from the mtime
    /// of the most recently modified file in the profile's data directory.
    func lastSyncedRelative(for profile: String) -> String {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return "Never synced" }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return "Never synced" }
        let newest = files.compactMap { url -> Date? in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
        guard let date = newest else { return "Never synced" }
        let components = Calendar.current.dateComponents([.minute, .hour, .day], from: date, to: Date())
        if let days = components.day, days > 0 { return "Synced \(days)d ago" }
        if let hours = components.hour, hours > 0 { return "Synced \(hours)h ago" }
        if let minutes = components.minute, minutes > 0 { return "Synced \(minutes)m ago" }
        return "Synced just now"
    }

    // MARK: Console deep-links

    /// Returns the Jamf Pro Computers list URL (no device ID) for the active profile,
    /// suitable for opening a search context in the console browser.
    func computerListURL() -> URL? {
        let rawServer = activeProfileURL()
        guard !rawServer.isEmpty, rawServer != "(jamf-cli profile)" else { return nil }
        let normalized = rawServer.contains("://") ? rawServer : "https://\(rawServer)"
        guard var components = URLComponents(string: normalized),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else { return nil }
        let sep = components.path.hasSuffix("/") ? "" : "/"
        components.path = components.path + sep + "computers.html"
        components.queryItems = nil
        return components.url
    }

    /// Returns the Jamf Pro console URL for a computer, or nil if the active
    /// profile has no server URL or the URL is malformed.
    ///
    /// Pattern mirrors JamfDash: `<server>/computers.html?id=<id>&o=r`
    func consoleURL(forComputerID id: Int) -> URL? {
        consoleURL(path: "computers.html", id: id)
    }

    /// Returns the Jamf Pro console URL for a mobile device, or nil if the active
    /// profile has no server URL or the URL is malformed.
    ///
    /// Pattern: `<server>/mobileDevices.html?id=<id>&o=r`
    func consoleURL(forMobileDeviceID id: Int) -> URL? {
        consoleURL(path: "mobileDevices.html", id: id)
    }

    /// Returns the Jamf Pro console URL for a computer group. `isStatic` selects
    /// `staticComputerGroups.html`; otherwise `smartComputerGroups.html`.
    func consoleURL(forComputerGroupID id: Int, isStatic: Bool) -> URL? {
        consoleURL(path: isStatic ? "staticComputerGroups.html" : "smartComputerGroups.html", id: id)
    }

    /// Returns the Jamf Pro console URL for a policy.
    /// Pattern: `<server>/policies.html?id=<id>&o=r`
    func consoleURL(forPolicyID id: Int) -> URL? {
        consoleURL(path: "policies.html", id: id)
    }

    /// Returns the Jamf Pro console URL for a computer configuration profile.
    /// Pattern: `<server>/OSXConfigurationProfiles.html?id=<id>&o=r`
    func consoleURL(forComputerConfigProfileID id: Int) -> URL? {
        consoleURL(path: "OSXConfigurationProfiles.html", id: id)
    }

    /// Returns the Jamf Pro console URL for a mobile-device configuration profile.
    /// Pattern: `<server>/mobileDeviceConfigurationProfiles.html?id=<id>&o=r`
    func consoleURL(forMobileConfigProfileID id: Int) -> URL? {
        consoleURL(path: "mobileDeviceConfigurationProfiles.html", id: id)
    }

    /// String-id convenience: wraps the numeric Int helper. Returns nil if the
    /// string isn't a positive integer.
    func consoleURL(forComputerID id: String) -> URL? {
        Int(id).flatMap { consoleURL(forComputerID: $0) }
    }

    func consoleURL(forMobileDeviceID id: String) -> URL? {
        Int(id).flatMap { consoleURL(forMobileDeviceID: $0) }
    }

    private func consoleURL(path: String, id: Int) -> URL? {
        let rawServer = activeProfileURL()
        guard !rawServer.isEmpty,
              rawServer != "(jamf-cli profile)" else { return nil }
        // `ProfileService.displayURL` stores the profile URL as a bare host
        // (e.g. `acme.jamfcloud.com`) for sidebar display. URLComponents on
        // that yields no scheme, which used to silently fail and break every
        // "Open in Jamf Pro" button. Default to https:// when no scheme is
        // present — Jamf Pro is HTTPS-only.
        let normalized = rawServer.contains("://")
            ? rawServer
            : "https://\(rawServer)"
        guard var components = URLComponents(string: normalized),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else { return nil }
        let separator = components.path.hasSuffix("/") ? "" : "/"
        components.path = components.path + separator + path
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "o", value: "r"),
        ]
        return components.url
    }

    /// Server URL for the currently active profile.
    private func activeProfileURL() -> String {
        if demoMode { return org.jamfURL }
        return profiles.first(where: { $0.name == profile })?.url ?? ""
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
    case overview, fleet, devices, deviceLookup, trends, audit, reports, schedules, runs
    case config, customize, sources, backups, settings, onboarding
    case securityPosture, compliancePosture, complianceBenchmarks
    case patch, updates, ddmBlueprints
    case policyProfile, extensionAttributes
    case outreach, protectDashboard, mobileFleet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:          "Overview"
        case .fleet:             "Fleet Overview"
        case .devices:           "Devices"
        case .deviceLookup:      "Device Lookup"
        case .trends:            "Trends"
        case .audit:             "Health Audit"
        case .reports:           "Generated"
        case .schedules:         "Schedules"
        case .runs:              "Run History"
        case .config:            "Config"
        case .customize:         "Customize"
        case .sources:           "Data Sources"
        case .backups:           "Backups"
        case .settings:          "Settings"
        case .onboarding:        "Onboarding"
        case .securityPosture:   "Security Posture"
        case .compliancePosture: "Compliance Posture"
        case .complianceBenchmarks: "Compliance Benchmarks"
        case .patch:             "Patch Compliance"
        case .updates:           "OS Updates"
        case .ddmBlueprints:     "DDM Blueprints"
        case .policyProfile:     "Policies & Profiles"
        case .extensionAttributes: "Extension Attributes"
        case .outreach:          "Offline Outreach"
        case .protectDashboard:  "Jamf Protect"
        case .mobileFleet:       "Mobile Fleet"
        }
    }

    var sfSymbol: String {
        switch self {
        case .overview:          "house"
        case .fleet:             "rectangle.grid.2x2"
        case .devices:           "laptopcomputer"
        case .deviceLookup:      "magnifyingglass"
        case .trends:            "chart.line.uptrend.xyaxis"
        case .audit:             "shield.checkered"
        case .reports:           "doc.text"
        case .schedules:         "clock"
        case .runs:              "terminal"
        case .config:            "wrench.and.screwdriver"
        case .customize:         "sparkles"
        case .sources:           "externaldrive"
        case .backups:           "externaldrive.badge.timemachine"
        case .settings:          "gear"
        case .onboarding:        "wand.and.stars"
        case .securityPosture:   "lock.shield"
        case .compliancePosture: "checkmark.shield"
        case .complianceBenchmarks: "list.bullet.clipboard"
        case .patch:             "shippingbox"
        case .updates:           "arrow.down.circle"
        case .ddmBlueprints:     "doc.badge.gearshape.fill"
        case .policyProfile:     "doc.badge.gearshape"
        case .extensionAttributes: "tag.fill"
        case .outreach:          "envelope.badge"
        case .protectDashboard:  "shield.lefthalf.filled"
        case .mobileFleet:       "ipad"
        }
    }

    var badge: String? {
        switch self {
        case .devices:   "inv"
        case .fleet:     "multi"
        case .trends:    "26w"
        case .reports:   "47"
        case .schedules: "5"
        default:         nil
        }
    }

    var badgeIsGold: Bool { self == .trends }

    /// Tabs the user cannot hide. These are the bones of the app — hiding
    /// them would break navigation or leave the user without a way back to
    /// configuration. Everything else is toggleable via `TabVisibility`.
    var isCoreTab: Bool {
        switch self {
        case .overview, .devices, .sources, .settings, .onboarding:
            return true
        case .fleet, .deviceLookup, .trends, .audit, .reports,
             .schedules, .runs, .config, .customize, .backups,
             .securityPosture, .compliancePosture, .complianceBenchmarks,
             .patch, .updates, .ddmBlueprints,
             .policyProfile, .extensionAttributes,
             .outreach, .protectDashboard, .mobileFleet:
            return false
        }
    }
}

// MARK: - Tab visibility

/// Per-user sidebar visibility preferences. Backed by `@AppStorage("hiddenTabs")`
/// as a comma-separated string of `Tab.rawValue` slugs. Core tabs (see
/// `Tab.isCoreTab`) are never hidden even if their slug appears in storage.
///
/// Lives outside `WorkspaceStore` because visibility is a per-user UX
/// preference, not workspace-bound state — switching profiles shouldn't
/// re-show tabs the user has hidden.
struct TabVisibility: Sendable, Equatable {
    private var hidden: Set<Tab>

    init(hidden: Set<Tab> = []) {
        // Core tabs can never be hidden — strip them on construction so
        // downstream code does not need to check twice.
        self.hidden = hidden.filter { !$0.isCoreTab }
    }

    /// True when this tab should appear in the sidebar.
    func isVisible(_ tab: Tab) -> Bool {
        tab.isCoreTab || !hidden.contains(tab)
    }

    /// True when this tab is explicitly hidden by the user.
    func isHidden(_ tab: Tab) -> Bool { !isVisible(tab) }

    /// Toggle a tab's visibility. Core tabs are no-ops.
    mutating func toggle(_ tab: Tab) {
        guard !tab.isCoreTab else { return }
        if hidden.contains(tab) { hidden.remove(tab) }
        else { hidden.insert(tab) }
    }

    /// Show every tab again (used by "Reset to defaults" button).
    mutating func showAll() {
        hidden.removeAll()
    }

    /// Parse from `@AppStorage` string: comma-separated raw values.
    /// Unknown slugs (e.g. tabs removed in a future version) are silently
    /// dropped. Core-tab slugs are stripped via the `init` filter.
    static func parse(_ raw: String) -> TabVisibility {
        let parts = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tabs = parts.compactMap { Tab(rawValue: $0) }
        return TabVisibility(hidden: Set(tabs))
    }

    /// Serialize back to `@AppStorage` string. Sorted for stability across
    /// edits so persisted state diffs cleanly.
    func serialize() -> String {
        hidden.map(\.rawValue).sorted().joined(separator: ",")
    }
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

// MARK: - Toast Model

struct Toast: Identifiable, Sendable {
    enum Style: Sendable { case info, success, danger }
    let id: UUID = UUID()
    let message: String
    let style: Style
}
