import SwiftUI

/// The devices a Jamf School workspace manages, from the newest `school-devices` snapshot, and
/// the devices waiting in Automated Device Enrollment (`school-dep-devices`). Shown only on a
/// School workspace (`Tab.schoolDevices`).
struct SchoolDevicesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: SchoolFleetService.Snapshot = .empty
    @State private var filter: Filter = .all
    @State private var search = ""
    /// The `dataSource` `snapshot` was read for; the content waits for it to match.
    @State private var loadedSource: String?
    @State private var reloads = 0

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", managed = "Managed", unmanaged = "Unmanaged", stale = "Stale"
        var id: String { rawValue }
    }

    private var staleDays: Int { Int(workspace.configState.staleDeviceDays) ?? 30 }

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Jamf School",
                title: "Devices",
                subtitle: subtitle,
                lastModified: snapshot.collectedAt
            )
            if loadedSource != dataSource {
                ScreenLoadingCard(what: "devices")
            } else {
                if snapshot.devicesDate == nil {
                    emptyState
                } else {
                    SchoolDeviceTiles(snapshot: snapshot, staleDays: staleDays)
                    devicesCard
                }
                if !snapshot.depDevices.isEmpty { depCard }
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    private var subtitle: String? {
        guard snapshot.devicesDate != nil else { return nil }
        let count = snapshot.devices.count
        return "\(count) device\(count == 1 ? "" : "s") in Jamf School."
    }

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { loadedSource = nil; snapshot = .empty }
        guard !workspace.demoMode else { loadedSource = source; return }
        let profile = workspace.profile
        guard let loaded = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: { SchoolFleetService.load(profile: profile) }
        ) else { return }
        snapshot = loaded
        loadedSource = source
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "ipad.and.iphone",
                title: "No devices collected yet",
                message: "Collect from Jamf School (Data Sources › Collect now) to list its "
                    + "devices."
            )
        }
    }

    private var rows: [SchoolFleetService.Device] {
        let now = Date()
        let query = search.trimmingCharacters(in: .whitespaces)
        return snapshot.devices.filter { device in
            switch filter {
            case .all: break
            case .managed: guard device.isManaged == true else { return false }
            case .unmanaged: guard device.isManaged == false else { return false }
            case .stale: guard device.isStale(atDays: staleDays, now: now) else { return false }
            }
            guard !query.isEmpty else { return true }
            return [device.name, device.serial, device.model, device.os]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var devicesCard: some View {
        let shown = rows
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Devices",
                    trailing: shown.count == snapshot.devices.count
                        ? nil : "\(shown.count) of \(snapshot.devices.count) shown")
                HStack(spacing: 12) {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField("Search name, serial, model or OS", text: $search)
                        .textFieldStyle(.roundedBorder)
                }
                SchoolDevicesTable(rows: shown, staleDays: staleDays)
                    .pageTableHeight(rows: shown.count)
            }
        }
    }

    private var depCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Automated Device Enrollment",
                              trailing: "\(snapshot.depDevices.count)")
                Table(snapshot.depDevices) {
                    TableColumn("Serial") { Text($0.serial).font(Theme.Fonts.mono(11)) }
                        .width(min: 110, ideal: 140)
                    TableColumn("Name") { Text($0.name.isEmpty ? "—" : $0.name) }
                        .width(min: 120, ideal: 180)
                    TableColumn("Model") { Text($0.model.isEmpty ? "—" : $0.model) }
                        .width(min: 90, ideal: 140)
                    TableColumn("Status") { Text($0.status.isEmpty ? "—" : $0.status) }
                        .width(min: 80, ideal: 110)
                    TableColumn("Profile") { Text($0.profile.isEmpty ? "—" : $0.profile) }
                        .width(min: 100, ideal: 160)
                }
                .font(.callout)
                .pageTableHeight(rows: snapshot.depDevices.count)
            }
        }
    }
}

/// The School device counts, shared by the Devices screen and the School Overview.
struct SchoolDeviceTiles: View {
    let snapshot: SchoolFleetService.Snapshot
    let staleDays: Int

    var body: some View {
        let total = snapshot.devices.count
        EqualHeightTileGrid(minTileWidth: 200) {
            StatTile(label: "Devices", value: "\(total)", sub: platformLine, fillsHeight: true)
            StatTile(label: "Managed", value: "\(snapshot.managedCount)",
                     sub: share(snapshot.managedCount, of: total), fillsHeight: true)
            StatTile(label: "Supervised", value: "\(snapshot.supervisedCount)",
                     sub: share(snapshot.supervisedCount, of: total), fillsHeight: true)
            StatTile(label: "Stale", value: "\(snapshot.staleCount(atDays: staleDays))",
                     sub: "No check-in for more than \(staleDays) days", fillsHeight: true)
        }
    }

    private var platformLine: String {
        let parts = snapshot.platformCounts.map { "\($0.count) \($0.platform)" }
        return parts.isEmpty ? "None collected" : parts.joined(separator: " · ")
    }

    private func share(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.0f%% of devices", Double(count) / Double(total) * 100)
    }
}

struct SchoolDevicesTable: View {
    let rows: [SchoolFleetService.Device]
    let staleDays: Int
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let now = Date()
        Table(rows) {
            TableColumn("Name") {
                Text($0.name.isEmpty ? "—" : $0.name).font(.callout.weight(.medium))
            }
                .width(min: 140, ideal: 200)
            TableColumn("Serial") {
                Text($0.serial.isEmpty ? "—" : $0.serial)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .width(min: 110, ideal: 140)
            TableColumn("Model") { Text($0.model.isEmpty ? "—" : $0.model) }
                .width(min: 90, ideal: 150)
            TableColumn("OS") { Text($0.os.isEmpty ? "—" : $0.os).font(Theme.Fonts.mono(11)) }
                .width(min: 90, ideal: 120)
            TableColumn("Managed") { Text(Self.yesNo($0.isManaged)) }
                .width(min: 60, ideal: 80)
            TableColumn("Supervised") { Text(Self.yesNo($0.isSupervised)) }
                .width(min: 70, ideal: 90)
            TableColumn("Last Check-in") { device in
                let stale = device.isStale(atDays: staleDays, now: now)
                // Same icon as the Computers table's stale state.
                HStack(spacing: 4) {
                    if stale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Colors.warn)
                            .accessibilityHidden(true)
                    }
                    Text(Self.checkinText(device, now: now))
                        .foregroundStyle(stale ? Theme.Colors.warn : Theme.Text.tertiary(contrast))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Last Check-in")
                .accessibilityValue(Self.checkinAccessibilityValue(device, stale: stale, now: now))
            }
            .width(min: 100, ideal: 130)
        }
        .font(.callout)
    }

    static func yesNo(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "—"
    }

    /// The check-in text, led by "Stale" so the state is not carried by color alone.
    static func checkinAccessibilityValue(
        _ device: SchoolFleetService.Device, stale: Bool, now: Date
    ) -> String {
        let text = checkinText(device, now: now)
        return stale ? "Stale, \(text)" : text
    }

    static func checkinText(_ device: SchoolFleetService.Device, now: Date) -> String {
        guard let days = device.daysSinceCheckin(now: now) else { return "Unknown" }
        return days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
