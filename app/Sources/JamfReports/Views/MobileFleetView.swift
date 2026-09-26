import SwiftUI
import Charts

/// Mobile fleet dashboard for iOS/iPadOS devices managed via Jamf Pro mobile-device
/// endpoints. Surfaces device counts, compliance KPIs, OS distribution, and device/profile
/// inventories from `pro mobile-devices list`, `mobile-device-inventory-details`, and
/// `classic-mobile-config-profiles` snapshots.
struct MobileFleetView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: MobileFleetService.Snapshot = .empty
    @State private var hasLoaded = false
    @State private var selectedDeviceID: String?
    /// Supervision bucket the devices table is filtered to. Set from a donut
    /// slice or legend row, cleared by the same control or the filter chip.
    @State private var supervisionFilter: MobileFleetService.SupervisionRole?

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Mobile",
                title: "Mobile Fleet",
                subtitle: subtitle,
                // The demo dataset is frozen on purpose; an age warning on it is noise.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )

            // Shared StaleDataBanner surfaces snapshot freshness above the main content.
            // Suppressed in demo mode (the demo dataset is intentionally static and
            // not user-perceivably "stale"). Renders nothing when source is .fresh.
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
                // A Mac-only tenant has no mobile devices at all, so no
                // expected kinds — every one of them would render a
                // false-alarm "never" chip. Only assert expectations once
                // mobile data is detected; present-kind chips still show
                // either way.
                FreshnessChipRow(
                    sourceDates: snapshot.sourceDates,
                    expectedKinds: snapshot.isDetected ? [
                        "mobile-devices-list", "mobile-device-inventory-details",
                        "classic-ios-profiles",
                    ] : []
                )
            }

            if !snapshot.isDetected {
                emptyState
            } else {
                kpiGrid
                supervisionCard
                enrollmentMethodCard
                complianceKpiGrid
                osDistributionCard
                devicesTable
                if let device = selectedRichDevice {
                    deviceDetailCard(device)
                }
                profilesTable
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    private var subtitle: String? {
        guard snapshot.totalDevices > 0 else { return nil }
        return "\(snapshot.totalDevices) mobile device\(snapshot.totalDevices == 1 ? "" : "s") across iOS and iPadOS."
    }

    // MARK: - Data loading

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    private func reload() {
        snapshot = workspace.demoMode
            ? Self.demoSnapshot
            : MobileFleetService.load(profile: workspace.profile)
        supervisionFilter = nil
    }

    private static let demoSnapshot: MobileFleetService.Snapshot = makeDemoSnapshot()

    // nonisolated: evaluated from the static-let initializer, which Swift 6.0
    // treats as a nonisolated context (6.1+ tolerates the isolated call).
    // Internal so the demo tests can check the fleet it builds.
    nonisolated static func makeDemoSnapshot() -> MobileFleetService.Snapshot {
        let devices: [MobileDeviceInventoryItem] =
            (1...DemoData.mobileDeviceCount).map(makeDemoDevice)
        let profiles: [MobileConfigProfileRow] = makeDemoProfiles()
        return MobileFleetService.Snapshot(
            isDetected: true,
            lightDevices: [],
            richDevices: devices,
            profiles: profiles,
            sourceFile: nil,
            snapshotDate: DemoData.referenceDate
        )
    }

    private nonisolated static let demoOSVersions: [String] = ["18.2.1", "18.1.1", "17.6.1"]

    /// Each demo device's owner: username, first name and department. The
    /// iPhones belong to the Devices screen's Mac users, in their departments.
    private nonisolated static let demoOwners: [(user: String, first: String, dept: String)] = [
        ("a.thompson", "Amara", "Clinical"), ("k.okafor", "Kofi", "Clinical"),
        ("s.nguyen", "Sofia", "Clinical"), ("t.walsh", "Tomas", "Clinical"),
        ("e.moreau", "Elena", "Research"), ("h.bauer", "Hanna", "Clinical"),
        ("n.patel", "Nikhil", "Operations"), ("c.alvarez", "Carmen", "Clinical"),
        ("g.lindqvist", "Greta", "Research"), ("o.haddad", "Omar", "Engineering"),
        ("w.zhang", "Wei", "Clinical"), ("y.sato", "Yuki", "Clinical"),
        ("f.rossi", "Francesca", "Operations"), ("i.kovac", "Ivan", "IT"),
        ("v.mehta", "Vikram", "Finance"), ("j.silva", "Joana", "Engineering"),
        ("r.chen", "Rui", "Design"), ("d.kim", "Daniel", "Finance"),
        ("m.rodriguez", "Marco", "IT"), ("l.vasquez", "Lucia", "Operations"),
        ("p.tanaka", "Peter", "Research"), ("b.singh", "Bina", "Engineering"),
        ("u.dimitrov", "Uma", "IT"), ("z.cohen", "Zara", "Finance"),
        ("q.ibrahim", "Qadir", "Operations"),
    ]

    /// Supervised devices came through Automated Device Enrollment with the
    /// iPad or iPhone prestage. The rest are personal devices their owners
    /// enrolled (i = 5, 15, 25 User Enrollment; 10 and 20 account-driven, and
    /// since unenrolled), so none of them reads as supervised.
    private nonisolated static func makeDemoDevice(index i: Int) -> MobileDeviceInventoryItem {
        let isIPad = i <= 15
        let kind = isIPad ? "iPad" : "iPhone"
        let supervised = i % 5 != 0
        let owner = demoOwners[(i - 1) % demoOwners.count]
        let number = String(format: "%02d", isIPad ? i : i - 15)
        let displayName = supervised
            ? "MERIDIAN-\(kind.uppercased())-\(number)"
            : "\(owner.first)'s \(kind)"
        let serial = isIPad
            ? "DMPW" + String(0x3A10 + i * 0x2F, radix: 16, uppercase: true) + "Q1GH"
            : "F2LX" + String(0x51C0 + i * 0x3B, radix: 16, uppercase: true) + "N0DV"
        // Inventoried in the week before the demo's "now", never after it.
        let age = TimeInterval((i % 7) * 86_400 + (i * 37 % 300 + 20) * 60)
        let lastUpdate = ISO8601DateFormatter().string(
            from: DemoData.referenceDate.addingTimeInterval(-age))
        let ownership = supervised
            ? "Institutional"
            : (i % 10 == 0 ? "AccountDrivenUserEnrollment" : "UserEnrollment")
        let prestage: MobileDevicePrestage? = supervised
            ? MobileDevicePrestage(
                mobileDevicePrestageId: isIPad ? "1" : "2",
                profileName: isIPad ? "Meridian iPad ADE" : "Meridian iPhone ADE")
            : nil
        let general = MobileDeviceGeneral(
            displayName: displayName,
            serialNumber: serial,
            osVersion: demoOSVersions[i % 3],
            managed: i % 10 != 0,
            supervised: supervised,
            lastInventoryUpdateDate: lastUpdate,
            deviceOwnershipType: ownership,
            activationLockEnabled: i % 6 != 0,
            passcodeCompliant: i % 8 != 0,
            dataProtectionEnabled: true,
            jailbreakDetected: "None",
            enrollmentMethodPrestage: prestage
        )
        let userLoc = MobileDeviceUserLocation(
            username: owner.user,
            emailAddress: "\(owner.user)@meridian.health",
            department: owner.dept,
            building: i % 2 == 0 ? "Meridian East" : "HQ"
        )
        let apps: [MobileDeviceApplication] = (0..<((i * 3) % 12)).map { idx in
            MobileDeviceApplication(identifier: "com.demo.app\(idx)", name: "Demo App \(idx)")
        }
        return MobileDeviceInventoryItem(
            mobileDeviceId: "\(1000 + i)",
            deviceType: kind,
            general: general,
            userAndLocation: userLoc,
            applications: apps
        )
    }

    private nonisolated static func makeDemoProfiles() -> [MobileConfigProfileRow] {
        let raw: [(String, String, String)] = [
            ("1", "Corporate WiFi", "Network"), ("2", "MDM Enrollment", "Device"),
            ("3", "Email Configuration", "Exchange"), ("4", "Security Baseline", "Security"),
            ("5", "App Restrictions", "Restrictions"), ("6", "VPN Access", "Network"),
            ("7", "Compliance Policy", "Security"), ("8", "Certificate Authority", "Certificate"),
        ]
        return raw.map { tuple in
            MobileConfigProfileRow(
                id: AnyCodable(tuple.0),
                name: tuple.1,
                category: tuple.2,
                site: "Default",
                description: nil
            )
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "ipad.and.iphone",
                title: "No mobile device data detected",
                message: "Run `jamf-cli pro mobile-devices list` (and optionally inventory-details and ios-profiles) to populate this dashboard."
            )
        }
    }

    // Both tile rows use the Overview's grid: the adaptive LazyVGrid capped
    // tiles at 320 pt, leaving an empty band beside them on a wide window.
    private var kpiGrid: some View {
        EqualHeightTileGrid(minTileWidth: 220) {
            StatTile(
                label: "Total Mobile Devices",
                value: "\(snapshot.totalDevices)",
                sub: "iOS and iPadOS devices",
                fillsHeight: true
            )
            StatTile(
                label: "iPads",
                value: "\(snapshot.iPadCount)",
                sub: pctString(count: snapshot.iPadCount, total: snapshot.totalDevices),
                fillsHeight: true
            )
            StatTile(
                label: "iPhones",
                value: "\(snapshot.iPhoneCount)",
                sub: pctString(count: snapshot.iPhoneCount, total: snapshot.totalDevices),
                fillsHeight: true
            )
        }
    }

    @ViewBuilder
    private var complianceKpiGrid: some View {
        if !snapshot.richDevices.isEmpty {
            EqualHeightTileGrid(minTileWidth: 220) {
                StatTile(
                    label: "Passcode Compliant",
                    value: fleetPercentText(snapshot.passcodeCompliantCount),
                    sub: fleetCountCaption(snapshot.passcodeCompliantCount),
                    fillsHeight: true
                )
                StatTile(
                    label: "Activation Lock",
                    value: fleetPercentText(snapshot.activationLockEnabledCount),
                    sub: fleetCountCaption(snapshot.activationLockEnabledCount),
                    fillsHeight: true
                )
                jailbreakTile
            }
            .padding(.top, 8)
        }
    }

    /// Caption for a tile whose field no device in the snapshot carries.
    private static let notCollectedCaption = "Not in the collected inventory"

    /// A count as a share of the fleet, or a dash when the count is unknown.
    private func fleetPercentText(_ count: Int?) -> String {
        guard let count else { return "—" }
        return String(format: "%.1f%%", pct(count: count, total: snapshot.totalDevices))
    }

    /// "N of M", or why there is no N.
    private func fleetCountCaption(_ count: Int?) -> String {
        guard let count else { return Self.notCollectedCaption }
        return "\(count) of \(snapshot.totalDevices)"
    }

    /// "Clean" only when some device actually reported a jailbreak status.
    private var jailbreakTile: StatTile {
        guard let detected = snapshot.jailbreakDetectedCount else {
            return StatTile(label: "Jailbreak Status", value: "—", sub: Self.notCollectedCaption,
                            fillsHeight: true)
        }
        if detected > 0 {
            return StatTile(
                label: "Jailbreak Detected",
                value: "\(detected)",
                sub: "Devices requiring attention",
                fillsHeight: true
            )
        }
        return StatTile(label: "Jailbreak Status", value: "Clean", sub: "No compromised devices",
                        fillsHeight: true)
    }

    @ViewBuilder
    private var supervisionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Supervision", trailing: "Managed posture")
                if snapshot.richDevices.isEmpty {
                    EmptyStateView(
                        systemImage: "questionmark.circle",
                        title: "Run inventory-details for KPIs",
                        message: "Supervision and ownership signals come from `pro mobile-device-inventory-details list`."
                    )
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        supervisionDonut
                            .frame(width: 180, height: 180)
                        supervisionLegend
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Shared by the drawing and the click hit test so the two cannot drift.
    private static let donutHoleRatio = 0.62

    /// Clicking a slice filters the devices table to it, clicking it again
    /// clears the filter. While a filter is active the other slices dim and
    /// shrink toward the hole, so the selected one reads as selected even when
    /// its colour is darker than theirs.
    private var supervisionDonut: some View {
        let slices = snapshot.supervisionSlices
        return Chart(slices, id: \.role) { slice in
            SectorMark(
                angle: .value("Count", Double(slice.count)),
                innerRadius: .ratio(Self.donutHoleRatio),
                outerRadius: .ratio(sliceOuterRatio(for: slice.role)),
                angularInset: 1.6
            )
            .foregroundStyle(supervisionColor(for: slice.role))
            .opacity(sliceOpacity(for: slice.role))
            .accessibilityLabel(slice.role.label)
            .accessibilityValue("\(slice.count) devices")
        }
        .chartLegend(.hidden)
        // A tap, not chartAngleSelection: on macOS that selection follows the
        // pointer, so hovering toggled the filter and a click did nothing.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let anchor = proxy.plotFrame else { return }
                        let plot = geometry[anchor]
                        let point = CGPoint(x: location.x - plot.minX, y: location.y - plot.minY)
                        guard let role = MobileFleetService.role(
                            at: point, plotSize: plot.size,
                            innerRadiusRatio: Self.donutHoleRatio, in: slices
                        ) else { return }
                        toggleSupervisionFilter(role)
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Mobile fleet supervision breakdown")
    }

    /// Each row is also the keyboard and VoiceOver route to the filter, which
    /// a click on the chart does not offer.
    private var supervisionLegend: some View {
        let total = snapshot.totalDevices
        let breakdown = snapshot.supervisionBreakdown
        // Rows carry 3 pt of padding for the selected row's highlight, so
        // spacing 2 keeps the 8 pt rhythm between their text.
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(breakdown, id: \.label) { slice in
                let percentage = total > 0 ? Double(slice.count) / Double(total) * 100 : 0
                let isActive = supervisionFilter == slice.role
                let action: String = isActive
                    ? "Show every device in the table"
                    : "Show only \(Self.filterNoun(for: slice.role)) in the table"
                Button {
                    toggleSupervisionFilter(slice.role)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(supervisionColor(for: slice.role))
                            .opacity(sliceOpacity(for: slice.role))
                            .frame(width: 12, height: 12)
                        Text(slice.label)
                            .font(.footnote.weight(isActive ? .semibold : .medium))
                            .foregroundStyle(Theme.Colors.fg)
                        Spacer()
                        Text("\(slice.count)")
                            .font(Theme.Fonts.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.fg2)
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", percentage))
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .frame(minWidth: 48, alignment: .trailing)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isActive ? Theme.Colors.goldBright.opacity(0.14) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(slice.count == 0)
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .accessibilityHint(action)
                .help(action)
            }
        }
    }

    /// Full strength while no filter is set, and for the filtered slice.
    private func sliceOpacity(for role: MobileFleetService.SupervisionRole) -> Double {
        supervisionFilter == nil || supervisionFilter == role ? 1 : 0.25
    }

    /// The ring's full width while no filter is set, and for the filtered
    /// slice. The click hit test still spans the full ring, so a click where
    /// a narrowed slice used to reach still selects it.
    private func sliceOuterRatio(for role: MobileFleetService.SupervisionRole) -> Double {
        supervisionFilter == nil || supervisionFilter == role ? 1 : 0.9
    }

    /// Filters the devices table to `role`, or clears the filter when it is
    /// already `role`. The row selection is dropped either way: the detail card
    /// looks devices up in the unfiltered list, so a selected row the filter
    /// hid would keep showing a device that is not in the table.
    private func toggleSupervisionFilter(_ role: MobileFleetService.SupervisionRole) {
        supervisionFilter = supervisionFilter == role ? nil : role
        selectedDeviceID = nil
    }

    private func supervisionColor(for role: MobileFleetService.SupervisionRole) -> Color {
        switch role {
        case .supervised: return Theme.Colors.goldBright
        case .unsupervised: return Theme.Colors.warn
        // A mid grey rather than a hairline tone: at 12% white the slice
        // almost vanished, and selected it read dimmer than the dimmed ones.
        case .unmanaged: return Theme.Colors.fgMuted
        case .unknown: return Theme.Colors.fgMuted.opacity(0.45)
        }
    }

    /// The devices a legend row's filter shows, for its hint.
    private static func filterNoun(for role: MobileFleetService.SupervisionRole) -> String {
        role == .unknown
            ? "devices with no supervision state"
            : "\(role.label.lowercased()) devices"
    }

    @ViewBuilder
    private var enrollmentMethodCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Enrollment Method")
                if snapshot.richDevices.isEmpty {
                    EmptyStateView(
                        systemImage: "questionmark.circle",
                        title: "Run inventory-details for KPIs",
                        message: "Enrollment method comes from `general.deviceOwnershipType`."
                    )
                } else if snapshot.enrollmentMethodDistribution.isEmpty {
                    Text("No enrollment method values reported by Jamf Pro for this fleet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    ForEach(snapshot.enrollmentMethodDistribution, id: \.method) { entry in
                        enrollmentMethodRow(method: entry.method, count: entry.count)
                    }
                }
            }
        }
    }

    private func enrollmentMethodRow(method: String, count: Int) -> some View {
        let total = snapshot.totalDevices
        let percentage = total > 0 ? Double(count) / Double(total) * 100 : 0
        return VStack(spacing: 4) {
            HStack {
                Text(method)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Text("\(count) device\(count == 1 ? "" : "s")")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(String(format: "%.1f%%", percentage))
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fg)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Colors.hairlineStrong)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.Colors.goldBright)
                            .frame(width: geo.size.width * (percentage / 100), height: 4)
                    }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(method): \(count) devices, \(String(format: "%.0f", percentage)) percent")
    }

    @ViewBuilder
    private var osDistributionCard: some View {
        if !snapshot.osDistribution.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionHeader(title: "iOS/iPadOS Version Distribution")
                        PNPButton(
                            title: "Export PNG",
                            icon: "square.and.arrow.down",
                            style: .neutral,
                            size: .sm,
                            action: exportOSDistribution
                        )
                        .accessibilityLabel("Export iOS/iPadOS version distribution chart as PNG")
                        .help("Save the iOS/iPadOS version distribution bar chart as a PNG image")
                    }
                    ForEach(snapshot.osDistribution, id: \.osVersion) { item in
                        osVersionBar(osVersion: item.osVersion, count: item.count)
                    }
                }
            }
        }
    }

    private func exportOSDistribution() {
        let rows = snapshot.osDistribution
        let total = snapshot.totalDevices
        let result = DashboardChartExport.run(
            title: "iOS / iPadOS Version Distribution",
            subtitle: "Mobile Fleet",
            footnote: "Source: pro mobile-devices · \(total) mobile devices",
            suggestedFilename: DashboardChartExport.filename(for: "mobile-os-distribution", profile: workspace.profile)
        ) {
            MobileFleetOSDistributionExport(rows: rows, totalDevices: total)
        }
        if case .failure(let error) = result {
            workspace.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    private func osVersionBar(osVersion: String, count: Int) -> some View {
        let total = snapshot.totalDevices
        let percentage = total > 0 ? (Double(count) / Double(total)) * 100 : 0

        return VStack(spacing: 4) {
            HStack {
                Text(osVersion)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Text("\(count) device\(count == 1 ? "" : "s")")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(String(format: "%.1f%%", percentage))
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fg)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Colors.hairlineStrong)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.Colors.goldBright)
                            .frame(width: geo.size.width * (percentage / 100), height: 4)
                    }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(osVersion): \(count) devices, \(String(format: "%.0f", percentage)) percent of fleet")
    }

    private var totalMobileDevices: Int {
        snapshot.richDevices.isEmpty
            ? snapshot.lightDevices.count
            : snapshot.richDevices.count
    }

    private var devicesTable: some View {
        let listRowsByID = snapshot.lightDevicesByID
        let matching = tableRows
        let rows = Array(matching.prefix(50))
        let total = totalMobileDevices
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    SectionHeader(
                        title: "Mobile Devices",
                        trailing: supervisionFilter != nil || total > rows.count
                            ? "\(rows.count) of \(total) shown"
                            : nil
                    )
                    if let supervisionFilter {
                        FilterChip(label: supervisionFilter.label) {
                            toggleSupervisionFilter(supervisionFilter)
                        }
                    }
                }
                Table(rows, selection: $selectedDeviceID) {
                    TableColumn("Name") { device in
                        Text(deviceDisplayName(device))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Type") { device in
                        let deviceType = getDeviceType(device, listRowsByID: listRowsByID)
                        Pill(text: deviceType, tone: pillTone(for: deviceType))
                            .accessibilityLabel("\(deviceType) device type")
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Serial") { device in
                        Text(getSerial(device) ?? "—")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("User") { device in
                        Text(getUsername(device) ?? "—")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("OS") { device in
                        Text(getOSVersion(device) ?? "—")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 80, ideal: 100)

                    // Always include the Last Inventory column to avoid the
                    // conditional-TableColumn conformance (requires macOS
                    // 14.4+). `getLastInventoryRelative` returns a dash for
                    // light-only rows.
                    TableColumn("Last Inventory") { device in
                        Text(getLastInventoryRelative(device))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 100, ideal: 120)
                }
                .font(.callout)
                // A Table has no height of its own inside the page's ScrollView; without this
                // it collapses under the header and shows no rows. Sized to its rows, so a
                // filtered list does not trail blank striped rows, up to Devices' 430 pt.
                .frame(height: Self.tableHeight(
                    rows: rows.count, rowHeight: Self.deviceRowHeight, cap: 430))
                if matching.count > rows.count {
                    Text("Generated reports include every mobile device.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var selectedRichDevice: MobileDeviceInventoryItem? {
        guard let id = selectedDeviceID, !snapshot.richDevices.isEmpty else { return nil }
        return snapshot.richDevices.first { device in
            let canonical: String
            if let mobileID = device.mobileDeviceId {
                canonical = mobileID
            } else {
                let serial = device.general?.serialNumber ?? "nil"
                let name = device.general?.displayName ?? "nil"
                canonical = "rich-\(serial)-\(name)"
            }
            return canonical == id
        }
    }

    private func deviceDetailCard(_ device: MobileDeviceInventoryItem) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: device.general?.displayName ?? "Untitled Device")
                        Mono(
                            text: device.general?.serialNumber ?? "—",
                            color: Theme.Colors.goldBright
                        )
                        .textSelection(.enabled)
                    }
                    Spacer()
                    Pill(
                        text: device.general?.supervised == true ? "Supervised" : "Unsupervised",
                        tone: device.general?.supervised == true ? .teal : .warn
                    )
                }
                deviceDetailSection("Management", rows: [
                    ("Managed", boolLabel(device.general?.managed)),
                    ("Supervised", boolLabel(device.general?.supervised)),
                    ("Enrollment", enrollmentLabel(for: device)),
                    ("Ownership", device.general?.deviceOwnershipType ?? ""),
                ])
                deviceDetailSection("Inventory", rows: [
                    ("Type", device.deviceType ?? ""),
                    ("OS", device.general?.osVersion ?? ""),
                    ("Managed Apps", managedAppsText(for: device)),
                    ("User", device.userAndLocation?.username ?? ""),
                    ("Department", device.userAndLocation?.department ?? ""),
                ])
            }
            .textSelection(.enabled)
        }
    }

    private func deviceDetailSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            VStack(spacing: 0) {
                ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0.uppercased())
                            .font(Theme.Fonts.mono(10.5, weight: .semibold))
                            .tracking(1.0)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                            .frame(minWidth: 110, alignment: .leading)
                        Text(row.1)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fg2)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// The detail card's app count. The snapshot says nothing about apps unless
    /// the APPLICATIONS section was collected, which the collect never asks for.
    private func managedAppsText(for device: MobileDeviceInventoryItem) -> String {
        guard let count = snapshot.managedAppCount(for: device) else {
            return "— (not in the collected inventory)"
        }
        return "\(count)"
    }

    private func enrollmentLabel(for device: MobileDeviceInventoryItem) -> String {
        let raw = device.general?.deviceOwnershipType ?? ""
        guard !raw.isEmpty else { return "" }
        let base = MobileFleetService.Snapshot.enrollmentMethodLabel(for: raw)
        if let prestage = device.general?.enrollmentMethodPrestage?.profileName, !prestage.isEmpty {
            return "\(base) (Prestage: \(prestage))"
        }
        return base
    }

    private func boolLabel(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "Yes"
        case .some(false): return "No"
        case .none: return ""
        }
    }

    private var profilesTable: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Config Profiles", trailingTag: snapshot.profiles.count <= 30 ? nil : "\(min(30, snapshot.profiles.count)) of \(snapshot.profiles.count)")
                if snapshot.profiles.isEmpty {
                    Text(profilesEmptyMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    profilesTableRows
                }
            }
        }
    }

    /// Tells a profiles snapshot that was never collected from one that listed none.
    /// `sourceDates` records only that the file exists, and an undecodable file also
    /// loads as no profiles, so the second message must not claim zero.
    private var profilesEmptyMessage: String {
        snapshot.sourceDates["classic-ios-profiles"] == nil
            ? "Configuration profiles have not been collected yet."
            : "The collected profiles snapshot lists none, or could not be read."
    }

    private var profilesTableRows: some View {
        let rows = snapshot.profiles.prefix(30).enumerated().map {
            ProfileWithIndex(profile: $0.element, index: $0.offset)
        }
        return Table(rows) {
            TableColumn("Name") { item in
                Text(item.profile.name ?? "Untitled Profile")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
            }
            .width(min: 180, ideal: 220)

            TableColumn("Category") { item in
                Text(item.profile.category ?? "—")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .width(min: 100, ideal: 120)

            TableColumn("Site") { item in
                Text(item.profile.site ?? "—")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .width(min: 80, ideal: 100)
        }
        .font(.callout)
        // A Table has no height of its own inside the page's ScrollView; without this
        // it collapses under the header. Sized to its rows up to 280 pt; rows past
        // that scroll in place.
        .frame(height: Self.tableHeight(
            rows: rows.count, rowHeight: Self.profileRowHeight, cap: 280))
    }

    // MARK: - Helpers

    /// Header, its separator and the inset above the first row, measured from
    /// a screenshot at the default text size.
    private nonisolated static let tableChromeHeight: CGFloat = 33
    /// The devices table's rows hold a Type pill, which makes them 26 pt.
    nonisolated static let deviceRowHeight: CGFloat = 26
    /// Text-only rows; 24 pt is the table's own row height.
    nonisolated static let profileRowHeight: CGFloat = 24

    /// A table's height for `rows` rows, at most `cap`. Past the last row the
    /// table draws empty striped rows that read as blank devices, so it stops
    /// at the rows it has; an empty list keeps one row's height under its
    /// header. Larger text makes rows taller than this, and they scroll.
    nonisolated static func tableHeight(rows: Int, rowHeight: CGFloat, cap: CGFloat) -> CGFloat {
        min(cap, tableChromeHeight + CGFloat(max(rows, 1)) * rowHeight)
    }

    /// The rows the devices table can list before its 50-row cap: inventory rows
    /// in the active supervision bucket when inventory details exist, list rows
    /// otherwise. Filtering before the cap lets a bucket's devices beyond the
    /// fleet's first 50 reach the table.
    private var tableRows: [Either<MobileDeviceListRow, MobileDeviceInventoryItem>] {
        if !snapshot.richDevices.isEmpty {
            return MobileFleetService.devices(snapshot.richDevices, in: supervisionFilter)
                .map { .right($0) }
        }
        return snapshot.lightDevices.map { .left($0) }
    }

    private func deviceDisplayName(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String {
        switch device {
        case .left(let light):
            return light.name ?? "Untitled Device"
        case .right(let rich):
            return rich.general?.displayName ?? "Untitled Device"
        }
    }

    /// Type pill text. An inventory row's `deviceType` is the OS family ("iOS")
    /// for every device, so the form factor comes from the hardware model,
    /// which the collected snapshots carry only on the list row.
    private func getDeviceType(
        _ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>,
        listRowsByID: [String: MobileDeviceListRow]
    ) -> String {
        switch device {
        case .left(let light):
            return MobileFleetService.typeLabel(
                for: MobileFleetService.formFactor(of: light),
                deviceType: light.deviceType ?? light.type
            )
        case .right(let rich):
            let listRow = rich.mobileDeviceId.flatMap { listRowsByID[$0] }
            return MobileFleetService.typeLabel(
                for: MobileFleetService.formFactor(of: rich, listRow: listRow),
                deviceType: rich.deviceType
            )
        }
    }

    private func getSerial(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String? {
        switch device {
        case .left(let light): light.serialNumber
        case .right(let rich): rich.general?.serialNumber
        }
    }

    private func getUsername(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String? {
        switch device {
        case .left(let light): light.username
        case .right(let rich): rich.userAndLocation?.username
        }
    }

    private func getOSVersion(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String? {
        switch device {
        case .left: nil
        case .right(let rich): rich.general?.osVersion
        }
    }

    private func getLastInventoryRelative(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String {
        switch device {
        case .left:
            return "—"
        case .right(let rich):
            guard let dateString = rich.general?.lastInventoryUpdateDate,
                  let date = ISO8601DateFormatter().date(from: dateString) else {
                return "—"
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            // Demo dates were written against the demo's "now"; measured from
            // today, every one read "1 yr. ago".
            let now = workspace.demoMode ? DemoData.referenceDate : Date()
            return formatter.localizedString(for: date, relativeTo: now)
        }
    }

    private func pillTone(for deviceType: String) -> Pill.Tone {
        switch deviceType.lowercased() {
        case let t where t.contains("ipad"): return .teal
        case let t where t.contains("iphone"): return .gold
        case let t where t.contains("tv"): return .warn
        default: return .muted
        }
    }

    private func pct(count: Int, total: Int) -> Double {
        total > 0 ? (Double(count) / Double(total)) * 100 : 0
    }

    private func pctString(count: Int, total: Int) -> String {
        total > 0 ? String(format: "%.1f%% of fleet", pct(count: count, total: total)) : "—"
    }
}

// MARK: - Helper types

/// Simple either type for handling both light and rich device data in tables.
///
/// `id` falls back to a deterministic hash of identifying fields (rather than
/// a fresh `UUID().uuidString`) so SwiftUI Table selection and scroll position
/// remain stable across renders for rows missing a server-side id.
private enum Either<L, R>: Identifiable {
    case left(L)
    case right(R)

    var id: String {
        switch self {
        case .left(let device as MobileDeviceListRow):
            if let id = device.id { return id }
            return "light-\(device.serialNumber ?? "nil")-\(device.name ?? "nil")"
        case .right(let device as MobileDeviceInventoryItem):
            if let id = device.mobileDeviceId { return id }
            let serial = device.general?.serialNumber ?? "nil"
            let name = device.general?.displayName ?? "nil"
            return "rich-\(serial)-\(name)"
        default:
            return "unknown"
        }
    }
}

/// Wrapper to make MobileConfigProfileRow identifiable for Table
private struct ProfileWithIndex: Identifiable {
    let profile: MobileConfigProfileRow
    let index: Int

    var id: String {
        if let profileId = profile.id?.value as? String {
            return profileId
        } else if let profileId = profile.id?.value as? Int {
            return String(profileId)
        } else {
            return "profile_\(index)"
        }
    }
}

// MARK: - Export-only chart

/// Light-mode export rendering of the mobile OS version distribution. Uses a
/// horizontal bar layout (one bar per OS version) so the export reads at a
/// glance even with 10+ versions stacked.
private struct MobileFleetOSDistributionExport: View {
    let rows: [(osVersion: String, count: Int)]
    let totalDevices: Int

    private static let displayCap = 12

    private var displayRows: [(osVersion: String, count: Int)] {
        Array(rows.prefix(Self.displayCap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(displayRows.enumerated()), id: \.offset) { _, row in
                let pct = totalDevices > 0 ? Double(row.count) / Double(totalDevices) * 100 : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(row.osVersion)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color(hex: 0x111827))
                        Spacer(minLength: 6)
                        Text("\(row.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", pct))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475569))
                            .frame(width: 52, alignment: .trailing)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: 0xE2E8F0))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.ChartPalette.osVersionExport[0]) // Use muted gold export color
                                .frame(width: max(0, geo.size.width * pct / 100))
                        }
                    }
                    .frame(height: 6)
                }
            }
            if rows.count > Self.displayCap {
                Text("+ \(rows.count - Self.displayCap) more versions not shown")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x64748B))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
