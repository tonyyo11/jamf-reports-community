import SwiftUI
import Charts

struct DevicesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot = DeviceInventorySnapshot.empty
    @State private var query = ""
    @State private var filter: DeviceFilter = .all
    @State private var selectedID: DeviceInventoryRecord.ID?
    @State private var staleDays = 30
    @State private var osFilter: String?
    @State private var isLoading = false
    @State private var deviceDetail: DeviceDetail?
    @State private var deviceDetailState: DeviceDetailState = .idle
    @State private var deviceDetailRequestKey = ""
    @State private var sortOrder = [KeyPathComparator(\DeviceInventoryRecord.displayName)]
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
        case all, stale, patch, security
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:      "All"
            case .stale:    "Stale"
            case .patch:    "Patch"
            case .security: "Security"
            }
        }

        var icon: String {
            switch self {
            case .all:      "list.bullet"
            case .stale:    "clock.badge.exclamationmark"
            case .patch:    "square.and.arrow.down.badge.clock"
            case .security: "lock.shield"
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
            }
        }.sorted(using: sortOrder)
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
                if !workspace.demoMode && activeSnapshot.devices.isEmpty && !isLoading {
                    emptyState
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
                    Stepper("Stale \(staleDays)d", value: $staleDays, in: 7...180, step: 1)
                        .font(Theme.Fonts.mono(11.5))
                        .foregroundStyle(Theme.Colors.fg2)
                        .frame(width: 118)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                        )
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await reload() }
                    }
                }
            )
        }
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
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.fg)
                    .focused($isSearchFocused)
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
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fg)
                                .lineLimit(1)
                                .textSelection(.enabled)
                                .help(device.model.isEmpty ? device.source : device.model)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.fg)
                                    .textSelection(.enabled)
                                Text(device.model.isEmpty ? device.source : device.model)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.fgMuted)
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
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Last Contact") { device in
                        HStack(spacing: 4) {
                            if isStale(device) {
                                Image(systemName: "clock.badge.exclamationmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.warn)
                            }
                            Mono(text: lastContactLabel(device),
                                 color: isStale(device) ? Theme.Colors.warn : Theme.Colors.fgMuted)
                        }
                    }
                    TableColumn("Patch") { device in patchPill(device) }
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
                        if let jamfID = device.numericJamfID, !workspace.org.jamfURL.isEmpty {
                            Button("Open in Jamf Pro") {
                                let jamfURL = workspace.org.jamfURL.trimmingCharacters(in: .init(charactersIn: "/"))
                                let urlString = "\(jamfURL)/computers.html?id=\(jamfID)&o=r"
                                if let url = URL(string: urlString) {
                                    SystemActions.open(url)
                                }
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

                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Patch")
                        if device.patchFailures.isEmpty {
                            PatchClearPill()
                                .id("patch-clear-\(device.id)")
                        } else {
                            ForEach(device.patchFailures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.title)
                                        .font(.system(size: 12.5, weight: .semibold))
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
                    }
                }
                .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "No Device Selected")
                    Text("No inventory rows match the current filters.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
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
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
            } else {
                switch deviceDetailState {
                case .idle:
                    Text("Select a device to load jamf-cli detail.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading device detail...")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                case .loaded:
                    if let deviceDetail {
                        jamfDetailSections(deviceDetail)
                    }
                case .unavailable(let message):
                    Text(message)
                        .font(.system(size: 12.5))
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
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .frame(width: 112, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.value)
                                    .font(.system(size: 12.2))
                                    .foregroundStyle(Theme.Colors.fg2)
                                    .lineLimit(3)
                                if !item.note.isEmpty {
                                    Mono(text: item.note, size: 10.5, color: Theme.Colors.fgMuted)
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
                    .font(.system(size: 11.5))
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
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
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
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                    }
                    .frame(height: 150)

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
                                        .foregroundStyle(Theme.Colors.fgMuted)
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
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    ForEach(activeSnapshot.sourceFiles, id: \.self) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.hasSuffix(".csv") ? "tablecells" : "curlybraces")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fgMuted)
                            Mono(text: file)
                                .lineLimit(1)
                        }
                    }
                }

                if !activeSnapshot.warnings.isEmpty {
                    Divider().background(Theme.Colors.hairline)
                    ForEach(activeSnapshot.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.warn)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Card(padding: 32) {
            VStack(spacing: 12) {
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Colors.hairlineStrong)
                Text("No device inventory yet")
                    .font(Theme.Fonts.serif(18, weight: .bold))
                Text("run Generate Report to populate")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
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
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .frame(width: 92, alignment: .leading)
                        Text(row.1)
                            .font(row.0 == "Serial" ? Theme.Fonts.mono(11.5) : .system(size: 12.5))
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
            SectionHeader(title: "Security")
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
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .frame(width: 92, alignment: .leading)
                    Text(device.failedRules == 0 ? "0" : "\(device.failedRules)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(device.failedRules == 0 ? Theme.Colors.fg2 : Theme.Colors.warn)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func securityRow(_ label: String, value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(Theme.Fonts.mono(10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .frame(width: 92, alignment: .leading)
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
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.fgMuted)
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
        if selectedID == nil || !loaded.devices.contains(where: { $0.id == selectedID }) {
            selectedID = loaded.devices.first?.id
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

        guard let data = await CLIBridge().deviceDetail(profile: profile, deviceID: lookup) else {
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
