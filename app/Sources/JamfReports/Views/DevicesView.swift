import SwiftUI
import Charts

struct DevicesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var snapshot = DemoData.deviceSnapshot
    @State private var query = ""
    @State private var filter: DeviceFilter = .all
    @State private var selectedID: DeviceInventoryRecord.ID?
    @State private var staleDays = 30
    @State private var osFilter: String?
    @State private var isLoading = false

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

    private var filteredDevices: [DeviceInventoryRecord] {
        snapshot.devices.filter { device in
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
        }
    }

    private var selectedDevice: DeviceInventoryRecord? {
        if let selectedID, let device = filteredDevices.first(where: { $0.id == selectedID }) {
            return device
        }
        return filteredDevices.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
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
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .task(id: "\(workspace.profile)-\(workspace.demoMode)") {
            await reload()
        }
    }

    private var header: some View {
        PageHeader(
            kicker: isLoading ? "Loading inventory" : "Current Inventory · \(snapshot.generatedAt)",
            title: "Devices",
            subtitle: "\(snapshot.totalDevices) records · \(workspace.profile)"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    Stepper("Stale \(staleDays)d", value: $staleDays, in: 7...180, step: 1)
                        .font(Theme.Fonts.mono(11.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .frame(width: 118)
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await reload() }
                    }
                }
            )
        }
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
            }
            .padding(.horizontal, 10)
            .frame(width: 260, height: 30)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
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
            Pill(text: "\(filteredDevices.count) shown", tone: .muted)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(label: "Devices", value: "\(snapshot.totalDevices)",
                     sub: snapshot.isDemo ? "Demo inventory" : "Current workspace")
            StatTile(label: "Stale", value: "\(snapshot.staleCount(thresholdDays: staleDays))",
                     sub: "\(staleDays)+ days since contact")
            StatTile(label: "Patch Issues", value: "\(snapshot.patchIssueCount)",
                     sub: "\(snapshot.patchTitles.count) patch titles")
            StatTile(label: "FileVault", value: "\(Int(snapshot.fileVaultPercent.rounded()))%",
                     sub: "\(snapshot.securityGapCount) security gaps")
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

                Table(filteredDevices, selection: $selectedID) {
                    TableColumn("Device") { device in
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
                    TableColumn("Serial") { device in
                        Mono(text: device.displaySerial)
                            .textSelection(.enabled)
                    }
                    TableColumn("macOS") { device in
                        Mono(text: device.osVersion.isEmpty ? "Unknown" : device.osVersion)
                    }
                    TableColumn("User") { device in
                        Text(device.user.isEmpty ? "Unassigned" : device.user)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .lineLimit(1)
                    }
                    TableColumn("Last Contact") { device in
                        Mono(text: lastContactLabel(device),
                             color: isStale(device) ? Theme.Colors.warn : Theme.Colors.fgMuted)
                    }
                    TableColumn("Patch") { device in patchPill(device) }
                    TableColumn("Risk") { device in riskPill(device.risk) }
                }
                .frame(minHeight: 430)
                .scrollContentBackground(.hidden)
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

                    detailSection("Security", rows: [
                        ("FileVault", device.fileVault),
                        ("SIP", device.sip),
                        ("Firewall", device.firewall),
                        ("Gatekeeper", device.gatekeeper),
                        ("Bootstrap", device.bootstrapToken),
                        ("Failed rules", device.failedRules == 0 ? "0" : "\(device.failedRules)"),
                    ])

                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Patch")
                        if device.patchFailures.isEmpty {
                            Pill(text: "No patch failures", tone: .teal, icon: "checkmark")
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

    private var osDistributionCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "macOS Versions")
                    Spacer()
                    Pill(text: "\(snapshot.osDistribution.count)", tone: .muted)
                }

                if snapshot.osDistribution.isEmpty {
                    Text("No OS data available.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    Chart(snapshot.osDistribution.prefix(6)) { item in
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
                        ForEach(snapshot.osDistribution.prefix(5)) { item in
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
                    Pill(text: snapshot.isDemo ? "Demo" : "Workspace", tone: snapshot.isDemo ? .gold : .teal)
                }

                if snapshot.sourceFiles.isEmpty {
                    Text("No current inventory, compliance, or patch snapshots were found.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                } else {
                    ForEach(snapshot.sourceFiles, id: \.self) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.hasSuffix(".csv") ? "tablecells" : "curlybraces")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.fgMuted)
                            Mono(text: file)
                                .lineLimit(1)
                        }
                    }
                }

                if !snapshot.warnings.isEmpty {
                    Divider().background(Theme.Colors.hairline)
                    ForEach(snapshot.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.warn)
                    }
                }
            }
        }
    }

    private func detailSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            VStack(spacing: 0) {
                ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0)
                            .font(.system(size: 11.5))
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
}
