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
        let realProfiles = ProfileService.discoverLocal()
        let realSchedules = LaunchAgentService.list()
        let isDemo = demoMode ?? realProfiles.isEmpty

        self.demoMode = isDemo
        self.org = DemoData.org
        self.profile = isDemo ? DemoData.org.profile : (realProfiles.first?.name ?? DemoData.org.profile)
        self.profiles = isDemo ? DemoData.cliProfiles : realProfiles
        self.schedules = isDemo ? DemoData.scheduledRuns : realSchedules
        self.sheetCatalog = DemoData.sheetCatalog
        self.customEAs = DemoData.customEAs
        self.columnMappings = DemoData.columnMappings
        self.selectedScoreCards = [.activeDevices, .fileVault, .compliance, .stale]
    }

    // MARK: Profile switching

    func setProfile(_ id: String) {
        guard ProfileService.isValid(id) else { return }
        profile = id
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
    func reloadFromDisk() {
        let real = ProfileService.discoverLocal()
        if real.isEmpty {
            demoMode = true
            profiles = DemoData.cliProfiles
            schedules = DemoData.scheduledRuns
        } else {
            demoMode = false
            profiles = real
            schedules = LaunchAgentService.list()
            if !real.contains(where: { $0.name == profile }) {
                profile = real.first!.name
            }
        }
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
}

// MARK: - Tab routing

/// Routes the active screen. `Tab` is the source of truth for which detail view
/// the `NavigationSplitView` renders, and the title shown in the toolbar.
enum Tab: String, CaseIterable, Identifiable, Hashable {
    case overview, devices, trends, reports, schedules, runs
    case config, customize, sources, settings, onboarding

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:   "Overview"
        case .devices:    "Devices"
        case .trends:     "Trends"
        case .reports:    "Generated"
        case .schedules:  "Schedules"
        case .runs:       "Run History"
        case .config:     "Config"
        case .customize:  "Customize"
        case .sources:    "Data Sources"
        case .settings:   "Settings"
        case .onboarding: "Onboarding"
        }
    }

    var sfSymbol: String {
        switch self {
        case .overview:   "house"
        case .devices:    "laptopcomputer"
        case .trends:     "chart.line.uptrend.xyaxis"
        case .reports:    "doc.text"
        case .schedules:  "clock"
        case .runs:       "terminal"
        case .config:     "wrench.and.screwdriver"
        case .customize:  "sparkles"
        case .sources:    "externaldrive"
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
