import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

struct DevicesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot = DeviceInventorySnapshot.empty
    @State private var query = ""
    @State private var filter: DeviceFilter = .all
    @State private var selectedID: DeviceInventoryRecord.ID?
    @State private var staleDays = 30
    /// One-shot guard so the picker seeds from `thresholds.stale_device_days`
    /// on first appear, then stays user-adjustable for the session.
    @State private var didSeedStaleDays = false
    @State private var osFilter: String?
    @State private var isLoading = false
    @State private var deviceDetail: DeviceDetail?
    @State private var deviceDetailState: DeviceDetailState = .idle
    @State private var deviceDetailRequestKey = ""
    @State private var sortOrder = [KeyPathComparator(\DeviceInventoryRecord.displayName)]
    @State private var isExportingCSV = false
    @State private var exportError: String?
    /// Per-device EA values for the configured security agent's column, keyed
    /// by lowercased device identifiers. Feeds the security-agent risk factor
    /// (v3.5's hardcoded "Nessus" check, now driven by security_agents config).
    @State private var agentStatusLookup: [String: String] = [:]
    /// Per-kind newest-file dates for the freshness chip row (Devices merges
    /// several kinds; the snapshot's single generatedDate can't express that).
    @State private var sourceDates: [String: Date] = [:]
    // Tracks the Devices page width so the inventory table can hide low-priority
    // columns under 1200pt — avoids truncation on 13" displays.
    @State private var pageWidth: CGFloat = 1400
    @FocusState private var isSearchFocused: Bool

    private enum DeviceDetailState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable(String)
    }

    private var activeSnapshot: DeviceInventorySnapshot {
        workspace.demoMode ? DemoData.deviceSnapshot : snapshot
    }

    private enum DeviceFilter: String, CaseIterable, Identifiable {
        case all, stale, patch, security, priorityAction
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:            "All"
            case .stale:          "Stale"
            case .patch:          "Patch"
            case .security:       "Security"
            case .priorityAction: "Priority"
            }
        }

        var icon: String {
            switch self {
            case .all:            "list.bullet"
            case .stale:          "clock.badge.exclamationmark"
            case .patch:          "square.and.arrow.down.badge.clock"
            case .security:       "lock.shield"
            case .priorityAction: "exclamationmark.triangle.fill"
            }
        }
    }

    /// True when the page width is too narrow to show every inventory column at
    /// full fidelity. Drives the responsive Device + User column behavior.
    private var isCompact: Bool { pageWidth < 1200 }

    private var filteredDevices: [DeviceInventoryRecord] {
        activeSnapshot.devices.filter { device in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !device.searchableText.contains(query.lowercased()) {
                return false
            }
            if let osFilter, device.osVersion != osFilter { return false }
            switch filter {
            case .all:
                return true
            case .stale:
                if let days = device.daysSinceContact { return days >= staleDays }
                return device.stale
            case .patch:
                return device.patchFailureCount > 0
            case .security:
                return device.securityGapCount > 0 || device.failedRules > 0
            case .priorityAction:
                // Devices that score in the v3.5 Critical or High band
                // via the configurable RiskScoringService. Note: the inline
                // `device.risk` enum is a legacy heuristic; this is the
                // authoritative scorer used by the new Priority Action List.
                let risk = priorityRisk(for: device)
                return risk.level >= .high
            }
        }.sorted(using: sortOrder)
    }

    /// Authoritative per-device risk via `RiskScoringService`. Memoizing
    /// would help if the filter cost showed up in profiling, but the live
    /// table re-renders on selection change rather than per filter pass.
    private func priorityRisk(for device: DeviceInventoryRecord) -> DeviceRisk {
        RiskScoringService.score(input: .from(record: device, agentCheck: agentCheck(for: device)))
    }

    /// The device's status against the tenant's configured security agent, or
    /// nil when no agent is configured / no EA value exists for this device.
    private func agentCheck(for device: DeviceInventoryRecord) -> RiskScoringService.SecurityAgentCheck? {
        guard !agentStatusLookup.isEmpty,
              let agent = workspace.configState.securityAgents.first(where: {
                  !$0.column.trimmingCharacters(in: .whitespaces).isEmpty
              }) else {
            return nil
        }
        let keys = [device.serial, device.jamfID ?? "", device.name]
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard let value = keys.compactMap({ agentStatusLookup[$0] }).first else { return nil }
        return .init(value: value, connectedValue: agent.connectedValue)
    }

    private var selectedDevice: DeviceInventoryRecord? {
        if let selectedID, let device = filteredDevices.first(where: { $0.id == selectedID }) {
            return device
        }
        return filteredDevices.first
    }

    private var deviceDetailTaskID: String {
        guard !workspace.demoMode,
              let selectedDevice,
              let lookup = detailLookupID(for: selectedDevice) else {
            return "\(workspace.profile)|\(workspace.demoMode)|none"
        }
        return "\(workspace.profile)|\(lookup)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // Devices had no freshness surface before 2.6; add the shared
                // Collect banner + per-kind chips. Per-kind file dates are the
                // honest signal here — digest collectionSources is summary-only.
                if !workspace.demoMode {
                    CollectNowBanner(
                        source: CacheSource.from(
                            snapshotDate: activeSnapshot.generatedDate, withinHours: 36
                        ),
                        tiers: [.inventory]
                    )
                    FreshnessChipRow(
                        sourceDates: sourceDates,
                        expectedKinds: [
                            "computers", "device-compliance",
                            "patch-device-failures", "patch-status",
                        ]
                    )
                }
                if let err = exportError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.danger)
                        .padding(.horizontal, 4)
                        .onTapGesture { exportError = nil }
                }
                if !workspace.demoMode && activeSnapshot.devices.isEmpty && !isLoading {
                    if activeSnapshot.warnings.isEmpty {
                        emptyState
                    } else {
                        deviceErrorState
                    }
                } else {
                    controls
                    summary
                    HStack(alignment: .top, spacing: 14) {
                        inventoryTable
                        VStack(spacing: 14) {
                            detailPanel(selectedDevice)
                            osDistributionCard
                            sourceCard
                        }
                        .frame(width: 360)
                    }
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: DevicesPageWidthKey.self, value: geo.size.width)
                }
            )
        }
        .onPreferenceChange(DevicesPageWidthKey.self) { width in
            pageWidth = width
        }
        .onAppear {
            guard !didSeedStaleDays else { return }
            didSeedStaleDays = true
            let configured = Int(workspace.configState.staleDeviceDays) ?? 30
            staleDays = min(max(configured, AppConstants.staleDaysMin), AppConstants.staleDaysMax)
        }
        .task(id: "\(workspace.profile)-\(workspace.demoMode)") {
            await reload()
        }
        .task(id: deviceDetailTaskID) {
            await loadSelectedDeviceDetail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            isSearchFocused = true
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search devices")
    }

    private var header: some View {
        PageHeader(
            kicker: isLoading ? "Loading inventory" : "Detailed Inventory · \(activeSnapshot.generatedAt)",
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
            title: "Devices",
            subtitle: "\(activeSnapshot.totalDevices) records · \(workspace.profile)",
            lastModified: activeSnapshot.generatedDate
        ) {
            AnyView(
                HStack(spacing: 8) {
                    staleDaysPicker
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await reload() }
                    }
                    .help("Reload device inventory from the cached jamf-cli snapshots.")
                    PNPButton(
                        title: isExportingCSV ? "Exporting…" : "Export CSV",
                        icon: "square.and.arrow.up",
                        style: .neutral
                    ) {
                        Task { await exportFilteredCSV() }
                    }
                    .disabled(workspace.demoMode || isExportingCSV || filteredDevices.isEmpty)
                    .help(workspace.demoMode
                          ? "Available in live mode only"
                          : "Export the currently filtered device list to a CSV file")
                }
            )
        }
    }

    /// Stale-days picker — see `EditableNumberStepper` for the input shape.
    private var staleDaysPicker: some View {
        EditableNumberStepper(
            value: $staleDays,
            range: AppConstants.staleDaysMin...AppConstants.staleDaysMax,
            prefix: "Stale",
            suffix: "d",
            help: "Devices with no jamf-cli check-in for at least this many days are flagged stale."
        )
    }

    private func navigateToOverview() {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": Tab.overview.rawValue]
        )
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fgMuted)
                TextField("Search devices", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.fg)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search devices")
            }
            .padding(.horizontal, 10)
            .frame(width: 260, height: 30)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                    .strokeBorder(
                        isSearchFocused ? Theme.Colors.gold.opacity(0.6) : Theme.Colors.hairlineStrong,
                        lineWidth: isSearchFocused ? 1 : 0.5
                    )
                    .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
            )

            SegmentedControl(
                selection: $filter,
                options: DeviceFilter.allCases.map { ($0, $0.label, $0.icon) }
            )

            if let osFilter {
                Button {
                    self.osFilter = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        Mono(text: osFilter, color: Theme.Colors.goldBright)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            let isFiltered = filteredDevices.count < activeSnapshot.devices.count
            HStack(spacing: 6) {
                if isFiltered {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Colors.goldBright)
                }
                Pill(
                    text: "\(filteredDevices.count) shown",
                    tone: isFiltered ? .gold : .muted
                )
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(label: "Devices", value: "\(activeSnapshot.totalDevices)",
                     sub: activeSnapshot.isDemo ? "Demo inventory" : "Current workspace")
            StatTile(label: "Stale", value: "\(activeSnapshot.staleCount(thresholdDays: staleDays))",
                     sub: "\(staleDays)+ days since contact")
            StatTile(label: "Patch Issues", value: "\(activeSnapshot.patchIssueCount)",
                     sub: "\(activeSnapshot.patchTitles.count) patch titles")
            StatTile(label: "FileVault", value: "\(Int(activeSnapshot.fileVaultPercent.rounded()))%",
                     sub: "\(activeSnapshot.securityGapCount) security gaps")
        }
    }

    private var inventoryTable: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "Device Inventory")
                    Spacer()
                    riskLegend
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                Divider().background(Theme.Colors.hairlineStrong)

                Table(filteredDevices, selection: $selectedID, sortOrder: $sortOrder) {
                    // Device collapses to single line under 1200pt; full name + model
                    // line is preserved on roomier windows where it earns the height.
                    // The model string remains accessible via the detail panel and the
                    // row's textSelection — no popover added to keep table scroll perf.
                    TableColumn("Device", value: \.displayName) { device in
                        if isCompact {
                            Text(device.displayName)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                                .lineLimit(1)
                                .textSelection(.enabled)
                                .help(device.model.isEmpty ? device.source : device.model)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.fg)
                                    .textSelection(.enabled)
                                Text(device.model.isEmpty ? device.source : device.model)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                                    .lineLimit(1)
                            }
                        }
                    }
                    TableColumn("Serial", value: \.serial) { device in
                        Mono(text: device.displaySerial)
                            .textSelection(.enabled)
                    }
                    TableColumn("macOS", value: \.osVersion) { device in
                        Mono(text: device.osVersion.isEmpty ? "Unknown" : device.osVersion)
                    }
                    TableColumn("User", value: \.user) { device in
                        if !isCompact {
                            Text(device.user.isEmpty ? "Unassigned" : device.user)
                                .font(.footnote)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Last Contact") { device in
                        HStack(spacing: 4) {
                            if isStale(device) {
                                Image(systemName: "clock.badge.exclamationmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.warn)
                                    .accessibilityLabel("Stale")
                            }
                            Mono(text: lastContactLabel(device),
                                 color: isStale(device) ? Theme.Colors.warn : Theme.Text.tertiary(contrast))
                        }
                    }
                    TableColumn("Patch") { device in patchPill(device) }
                    TableColumn("Security") { device in securityIndicators(for: device) }
                        .width(min: 70, ideal: 78, max: 90)
                    TableColumn("Risk") { device in riskPill(device.risk) }
                }
                .frame(minHeight: 430)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: DeviceInventoryRecord.ID.self) { selection in
                    if let id = selection.first, let device = activeSnapshot.devices.first(where: { $0.id == id }) {
                        Button("Copy Serial Number") {
                            SystemActions.copyToClipboard(device.serial)
                        }
                        Button("Copy User Email") {
                            SystemActions.copyToClipboard(device.email.isEmpty ? device.user : device.email)
                        }
                        if let jamfID = device.numericJamfID,
                           let url = workspace.consoleURL(forComputerID: jamfID) {
                            Button("Open in Jamf Pro") {
                                SystemActions.open(url)
                            }
                        }
                    }
                }
            }
        }
    }

    private var riskLegend: some View {
        HStack(spacing: 8) {
            legendDot(color: Theme.Colors.danger, label: "Critical")
            legendDot(color: Theme.Colors.warn, label: "Attention")
            legendDot(color: Theme.Colors.ok, label: "OK")
        }
    }

    private func detailPanel(_ device: DeviceInventoryRecord?) -> some View {
        Card(padding: 18) {
            if let device {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionHeader(title: device.displayName)
                            Mono(text: device.displaySerial, color: Theme.Colors.goldBright)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        riskPill(device.risk)
                    }

                    detailSection("Inventory", rows: [
                        ("Model", device.model),
                        ("macOS", device.osVersion),
                        ("Managed", device.managedState),
                        ("Last contact", device.lastContact),
                        ("Last inventory", device.lastInventory),
                        ("User", userLabel(device)),
                        ("Department", device.department),
                        ("Site", device.site),
                    ])

                    securitySection(for: device)

                    priorityRiskSection(for: device)

                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Patch")
                        if device.patchFailures.isEmpty {
                            PatchClearPill()
                                .id("patch-clear-\(device.id)")
                        } else {
                            ForEach(device.patchFailures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.title)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.Colors.fg)
                                    HStack(spacing: 6) {
                                        Pill(text: failure.status, tone: .warn)
                                        if !failure.latestVersion.isEmpty {
                                            Mono(text: failure.latestVersion)
                                        }
                                        if !failure.date.isEmpty {
                                            Mono(text: failure.date)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    liveDeviceDetailSection(for: device)

                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Mono(text: device.source)
                            .lineLimit(1)
                        Spacer()
                        PNPButton(title: "Copy Serial", icon: "doc.on.doc", size: .sm) {
                            SystemActions.copyToClipboard(device.serial)
                        }
                        .help("Copy this device's serial number to the clipboard.")
                    }
                }
                .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "No Device Selected")
                    Text("No inventory rows match the current filters.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    @ViewBuilder
    private func liveDeviceDetailSection(for device: DeviceInventoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "jamf-cli Detail")
                Spacer()
                if workspace.demoMode {
                    Pill(text: "Live mode only", tone: .muted)
                } else if case .loading = deviceDetailState {
                    Pill(text: "Loading", tone: .gold)
                } else if case .loaded = deviceDetailState {
                    Pill(text: "Loaded", tone: .teal, icon: "checkmark")
                } else if case .unavailable = deviceDetailState {
                    Pill(text: "Unavailable", tone: .warn)
                }
            }

            if workspace.demoMode {
                Text("Available in live mode only.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            } else {
                switch deviceDetailState {
                case .idle:
                    Text("Select a device to load jamf-cli detail.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading device detail...")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                case .loaded:
                    if let deviceDetail {
                        jamfDetailSections(deviceDetail)
                    }
                case .unavailable(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.warn)
                }
            }
        }
    }

    private func jamfDetailSections(_ detail: DeviceDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(detail.sections.prefix(5)) { section in
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: section.title)
                    ForEach(section.items.prefix(8)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.label)
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .frame(width: 112, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.value)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.Colors.fg2)
                                    .lineLimit(3)
                                if !item.note.isEmpty {
                                    Mono(text: item.note, size: 10.5, color: Theme.Text.tertiary(contrast))
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                    if section.items.count > 8 {
                        Mono(text: "+ \(section.items.count - 8) more", size: 10.5)
                    }
                }
            }
            if detail.sections.count > 5 {
                Mono(text: "+ \(detail.sections.count - 5) more sections", size: 10.5)
            }
            ForEach(detail.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warn)
            }
        }
    }

    private var osDistributionCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "macOS Versions")
                    Spacer()
                    Pill(text: "\(activeSnapshot.osDistribution.count)", tone: .muted)
                }

                if activeSnapshot.osDistribution.isEmpty {
                    Text("No OS data available.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    Chart(activeSnapshot.osDistribution.prefix(6)) { item in
                        BarMark(
                            x: .value("Devices", item.count),
                            y: .value("Version", item.version)
                        )
                        .foregroundStyle(Color(hex: item.colorHex))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisValueLabel()
                                .font(Theme.Fonts.mono(10))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                    }
                    .frame(height: 150)
                    .accessibilityChartDescriptor(BarDistributionChartDescriptor(
                        title: "macOS Version Distribution",
                        unit: " devices",
                        bars: activeSnapshot.osDistribution.prefix(6).map {
                            .init(label: $0.version, value: Double($0.count))
                        }
                    ))

                    VStack(spacing: 0) {
                        ForEach(activeSnapshot.osDistribution.prefix(5)) { item in
                            Button {
                                osFilter = osFilter == item.version ? nil : item.version
                            } label: {
                                HStack {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: item.colorHex))
                                        .frame(width: 9, height: 9)
                                    Text(item.version)
                                        .font(Theme.Fonts.mono(11.5))
                                        .foregroundStyle(osFilter == item.version ? Theme.Colors.goldBright : Theme.Colors.fg2)
                                    Spacer()
                                    Mono(text: "\(item.count)")
                                    Text("\(String(format: "%.1f", item.pct))%")
                                        .font(Theme.Fonts.mono(10.5))
                                        .foregroundStyle(Theme.Text.tertiary(contrast))
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var sourceCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "Sources")
                    Spacer()
                    Pill(text: activeSnapshot.isDemo ? "Demo" : "Workspace",
                         tone: activeSnapshot.isDemo ? .gold : .teal)
                }

                if activeSnapshot.sourceFiles.isEmpty {
                    Text("No current inventory, compliance, or patch snapshots were found.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    ForEach(activeSnapshot.sourceFiles, id: \.self) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.hasSuffix(".csv") ? "tablecells" : "curlybraces")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                            Mono(text: file)
                                .lineLimit(1)
                        }
                    }
                }

                if !activeSnapshot.warnings.isEmpty {
                    Divider().background(Theme.Colors.hairline)
                    ForEach(activeSnapshot.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.warn)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Card(padding: 32) {
            EmptyStateView(
                systemImage: "desktopcomputer.and.arrow.down",
                title: "No device inventory yet",
                message: "run Generate Report to populate"
            )
            .frame(maxWidth: .infinity)
        }
    }

    /// Shown when the inventory came back empty *and* the loader recorded warnings —
    /// a true read failure (broken workspace path, unreadable/undecodable source file),
    /// distinct from the not-collected-yet `emptyState`.
    private var deviceErrorState: some View {
        Card(padding: 32) {
            ErrorStateView(
                title: "Couldn't read device inventory",
                message: activeSnapshot.warnings.joined(separator: "\n"),
                commands: ["Re-run collection from Data Sources, then Refresh."],
                retry: { Task { await reload() } }
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func detailSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            VStack(spacing: 0) {
                ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0.uppercased())
                            .font(Theme.Fonts.mono(10.5, weight: .semibold))
                            .tracking(1.0)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .frame(minWidth: 92, alignment: .leading)
                        Text(row.1)
                            .font(row.0 == "Serial" ? Theme.Fonts.mono(11.5) : .footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func securitySection(for device: DeviceInventoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Security State")
            VStack(spacing: 0) {
                securityRow("FileVault", value: device.fileVault)
                securityRow("SIP", value: device.sip)
                securityRow("Firewall", value: device.firewall)
                securityRow("Gatekeeper", value: device.gatekeeper)
                if !device.bootstrapToken.isEmpty {
                    securityRow("Bootstrap", value: device.bootstrapToken)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("FAILED RULES")
                        .font(Theme.Fonts.mono(10.5, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(minWidth: 92, alignment: .leading)
                    Text(device.failedRules == 0 ? "0" : "\(device.failedRules)")
                        .font(.footnote)
                        .foregroundStyle(device.failedRules == 0 ? Theme.Colors.fg2 : Theme.Colors.warn)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Computed Priority Action List section — only visible when the
    /// `RiskScoringService` has triggered factors. Clean devices skip this
    /// block entirely so the detail panel stays uncluttered for healthy
    /// inventory. Lifts v3.5's "Priority Action List" remediation hints
    /// directly into the per-device drill.
    @ViewBuilder
    private func priorityRiskSection(for device: DeviceInventoryRecord) -> some View {
        let risk = priorityRisk(for: device)
        // Configured security-agent name labels the agent factor
        // (e.g. "Nessus Agent Disconnected" instead of the generic label).
        let agentName = workspace.edrAgentName
        if !risk.triggered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(title: "Priority Risk")
                    Spacer()
                    Pill(
                        text: "\(risk.level.displayLabel) · \(risk.score)",
                        tone: priorityRiskTone(for: risk.level)
                    )
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(risk.triggered, id: \.factor) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.factor.displayLabel(agentName: agentName))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.fg)
                                if let detail = entry.detail {
                                    Mono(text: detail)
                                }
                                Spacer()
                                Pill(text: "+\(entry.points)", tone: .warn)
                            }
                            Text(entry.factor.remediation(agentName: agentName))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(entry.factor.displayLabel(agentName: agentName)), \(entry.points) points. " +
                            "Remediation: \(entry.factor.remediation(agentName: agentName))"
                        )
                    }
                }
            }
        }
    }

    private func priorityRiskTone(for level: DeviceRisk.Level) -> Pill.Tone {
        switch level {
        case .clean, .low: return .muted
        case .medium:      return .gold
        case .high:        return .warn
        case .critical:    return .danger
        }
    }

    @ViewBuilder
    private func securityRow(_ label: String, value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(Theme.Fonts.mono(10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .frame(minWidth: 92, alignment: .leading)
                Pill(text: value, tone: securityTone(for: value))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private func securityTone(for value: String) -> Pill.Tone {
        let v = value.lowercased()
        let positives = ["enabled", "on", "active", "encrypted", "yes", "true", "escrowed", "installed"]
        let negatives = ["disabled", "off", "inactive", "decrypted", "no", "false", "missing", "not installed"]
        if positives.contains(where: { v.contains($0) }) { return .teal }
        if negatives.contains(where: { v.contains($0) }) { return .danger }
        return .muted
    }

    // Per-control glyph row for the inventory table. Five tight icons:
    // FV / SIP / FW / GK / BT. Reuses `securityTone` so the table and the
    // detail panel agree on what counts as good/bad/unknown.
    @ViewBuilder
    private func securityIndicators(for device: DeviceInventoryRecord) -> some View {
        let controls: [(String, String)] = [
            ("FV", device.fileVault),
            ("SIP", device.sip),
            ("FW", device.firewall),
            ("GK", device.gatekeeper),
            ("BT", device.bootstrapToken),
        ]
        HStack(spacing: 3) {
            ForEach(controls, id: \.0) { (label, value) in
                securityGlyph(label: label, value: value)
            }
        }
    }

    private func securityGlyph(label: String, value: String) -> some View {
        let tone = securityTone(for: value)
        let symbol: String
        let color: Color
        switch tone {
        case .teal:
            symbol = "checkmark.circle.fill"
            color = Theme.Colors.ok
        case .danger:
            symbol = "xmark.circle.fill"
            color = Theme.Colors.danger
        default:
            symbol = "minus.circle"
            color = Theme.Colors.fgMuted
        }
        let display = value.isEmpty ? "Not collected" : value
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .help("\(label): \(display)")
            .accessibilityLabel("\(label) \(display)")
    }

    private func riskPill(_ risk: DeviceInventoryRecord.Risk) -> Pill {
        switch risk {
        case .critical:  Pill(text: "Critical", tone: .danger)
        case .attention: Pill(text: "Attention", tone: .warn)
        case .ok:        Pill(text: "OK", tone: .teal)
        case .unknown:   Pill(text: "Unknown", tone: .muted)
        }
    }

    private func patchPill(_ device: DeviceInventoryRecord) -> Pill {
        if device.patchFailureCount == 0 {
            return Pill(text: "Clear", tone: .teal)
        }
        return Pill(text: "\(device.patchFailureCount)", tone: device.patchFailureCount > 2 ? .danger : .warn)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    private func isStale(_ device: DeviceInventoryRecord) -> Bool {
        if let days = device.daysSinceContact { return days >= staleDays }
        return device.stale
    }

    private func lastContactLabel(_ device: DeviceInventoryRecord) -> String {
        if let days = device.daysSinceContact {
            if days == 0 { return "Today" }
            if days == 1 { return "1 day" }
            return "\(days) days"
        }
        return device.lastContact.isEmpty ? "Unknown" : device.lastContact
    }

    private func userLabel(_ device: DeviceInventoryRecord) -> String {
        if !device.email.isEmpty { return device.email }
        return device.user
    }

    private func reload() async {
        let profile = workspace.profile
        let demoMode = workspace.demoMode
        isLoading = true
        let loaded = await Task.detached(priority: .userInitiated) {
            DeviceInventoryService.load(profile: profile, demoMode: demoMode)
        }.value
        snapshot = loaded
        sourceDates = await Task.detached(priority: .userInitiated) {
            DeviceInventoryService.sourceDates(profile: profile, demoMode: demoMode)
        }.value
        if selectedID == nil || !loaded.devices.contains(where: { $0.id == selectedID }) {
            selectedID = loaded.devices.first?.id
        }

        // Security-agent risk factor: build the per-device EA lookup for the
        // first configured agent. Empty when none configured or no ea-results
        // snapshot exists — the factor then never triggers.
        let agentColumn = workspace.configState.securityAgents
            .first { !$0.column.trimmingCharacters(in: .whitespaces).isEmpty }?
            .column ?? ""
        if !demoMode, !agentColumn.isEmpty {
            agentStatusLookup = await Task.detached(priority: .userInitiated) {
                RiskScoringService.agentStatusLookup(profile: profile, eaColumn: agentColumn)
            }.value
        } else {
            agentStatusLookup = [:]
        }
        isLoading = false
    }

    private func loadSelectedDeviceDetail() async {
        guard !workspace.demoMode else {
            deviceDetail = nil
            deviceDetailState = .idle
            return
        }
        guard let device = selectedDevice else {
            deviceDetail = nil
            deviceDetailState = .idle
            return
        }
        guard let lookup = detailLookupID(for: device) else {
            deviceDetail = nil
            deviceDetailState = .unavailable("Device detail needs a serial number or device name.")
            return
        }

        let profile = workspace.profile
        let requestKey = "\(profile)|\(lookup)"
        deviceDetailRequestKey = requestKey
        deviceDetail = nil
        deviceDetailState = .loading

        guard let data = await CLIBridge().deviceDetailWithProvenance(profile: profile, deviceID: lookup)?.data else {
            if deviceDetailRequestKey == requestKey {
                deviceDetailState = .unavailable("Device detail unavailable for \(lookup).")
            }
            return
        }

        do {
            let decoded = try DeviceDetail.decode(from: data, lookupID: lookup)
            if deviceDetailRequestKey == requestKey {
                deviceDetail = decoded
                deviceDetailState = .loaded
            }
        } catch {
            if deviceDetailRequestKey == requestKey {
                deviceDetailState = .unavailable("Could not decode device detail for \(lookup).")
            }
        }
    }

    private func detailLookupID(for device: DeviceInventoryRecord) -> String? {
        let serial = device.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serial.isEmpty { return serial }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    @MainActor
    private func exportFilteredCSV() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportNaming.filename(
            kind: "devices", profile: workspace.profile, ext: "csv"
        )
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        // The save panel is the user's explicit, per-action consent for this
        // exact path — no additional allow-list gate (matches every other
        // export flow: Patch, Runs, Reports, chart PNGs).
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingCSV = true
        defer { isExportingCSV = false }
        let rows = filteredDevices
        let header = "Name,Serial,OS Version,User,Email,Department,FileVault,Last Check-in,Risk\n"
        let body = rows.map { d in
            [d.name, d.serial, d.osVersion, d.user, d.email, d.department,
             d.fileVault, d.lastContact, d.risk.rawValue]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: ",")
        }.joined(separator: "\n")
        do {
            try (header + body).write(to: url, atomically: true, encoding: .utf8)
            // Path is user-confirmed via NSSavePanel — safe to reveal directly.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// PreferenceKey carrying the Devices page width up to the parent view so the
/// inventory table can collapse low-priority columns on narrow windows.
private struct DevicesPageWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Patch-clear pill with a brief scale + opacity pulse on first appearance.
/// `@State` justified: animation flag is purely view-local presentation state.
private struct PatchClearPill: View {
    @State private var pulsed = false

    var body: some View {
        Pill(text: "No patch failures", tone: .teal, icon: "checkmark")
            .scaleEffect(pulsed ? 1.0 : 1.05)
            .opacity(pulsed ? 1.0 : 0.6)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) { pulsed = true }
            }
            .transition(.scale.combined(with: .opacity))
    }
}
