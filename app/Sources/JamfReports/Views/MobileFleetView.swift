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

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Mobile",
                title: "Mobile Fleet",
                subtitle: subtitle,
                lastModified: snapshot.snapshotDate
            )

            // Shared StaleDataBanner surfaces snapshot freshness above the main content.
            // Suppressed in demo mode (the demo dataset is intentionally static and
            // not user-perceivably "stale"). Renders nothing when source is .fresh.
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
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
                if !snapshot.profiles.isEmpty {
                    profilesTable
                }
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
    }

    private static let demoSnapshot: MobileFleetService.Snapshot = makeDemoSnapshot()

    // nonisolated: evaluated from the static-let initializer, which Swift 6.0
    // treats as a nonisolated context (6.1+ tolerates the isolated call).
    private nonisolated static func makeDemoSnapshot() -> MobileFleetService.Snapshot {
        let devices: [MobileDeviceInventoryItem] = (1...25).map(makeDemoDevice)
        let profiles: [MobileConfigProfileRow] = makeDemoProfiles()
        return MobileFleetService.Snapshot(
            isDetected: true,
            lightDevices: [],
            richDevices: devices,
            profiles: profiles,
            sourceFile: nil,
            snapshotDate: Date()
        )
    }

    private nonisolated(unsafe) static let demoOwnershipTypes: [String] = [
        "Institutional", "UserEnrollment",
        "AccountDrivenUserEnrollment", "AccountDrivenDeviceEnrollment",
    ]

    private nonisolated(unsafe) static let demoOSVersions: [String] = ["18.2.1", "18.1.1", "17.6.1"]
    private nonisolated(unsafe) static let demoDepartments: [String] = ["IT", "Sales", "Marketing"]

    private nonisolated static func makeDemoDevice(index i: Int) -> MobileDeviceInventoryItem {
        let isIPad = i <= 15
        let kind = isIPad ? "iPad" : "iPhone"
        let displayName = "\(kind)-Demo-\(String(format: "%03d", i))"
        let serial = "DEMO\(String(format: "%08d", 10000000 + i))"
        let lastUpdate = "2025-01-\(String(format: "%02d", (i % 28) + 1))T12:00:00Z"
        let ownership = demoOwnershipTypes[i % demoOwnershipTypes.count]
        let prestage: MobileDevicePrestage? = i % 4 == 0
            ? MobileDevicePrestage(mobileDevicePrestageId: "\(i)", profileName: "Demo Prestage")
            : nil
        let general = MobileDeviceGeneral(
            displayName: displayName,
            serialNumber: serial,
            osVersion: demoOSVersions[i % 3],
            managed: i % 10 != 0,
            supervised: i % 5 != 0,
            lastInventoryUpdateDate: lastUpdate,
            deviceOwnershipType: ownership,
            activationLockEnabled: i % 6 != 0,
            passcodeCompliant: i % 8 != 0,
            dataProtectionEnabled: true,
            jailbreakDetected: "None",
            enrollmentMethodPrestage: prestage
        )
        let userLoc = MobileDeviceUserLocation(
            username: i % 5 == 0 ? nil : "user\(i)",
            emailAddress: i % 5 == 0 ? nil : "user\(i)@example.com",
            department: demoDepartments[i % 3],
            building: "Building \((i % 3) + 1)"
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

    private var kpiGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Total Mobile Devices",
                value: "\(snapshot.totalDevices)",
                sub: "iOS and iPadOS devices"
            )
            StatTile(
                label: "iPads",
                value: "\(snapshot.iPadCount)",
                sub: pctString(count: snapshot.iPadCount, total: snapshot.totalDevices)
            )
            StatTile(
                label: "iPhones",
                value: "\(snapshot.iPhoneCount)",
                sub: pctString(count: snapshot.iPhoneCount, total: snapshot.totalDevices)
            )
        }
    }

    @ViewBuilder
    private var complianceKpiGrid: some View {
        if !snapshot.richDevices.isEmpty {
            let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    label: "Passcode Compliant",
                    value: String(format: "%.1f%%", pct(count: snapshot.passcodeCompliantCount, total: snapshot.totalDevices)),
                    sub: "\(snapshot.passcodeCompliantCount) of \(snapshot.totalDevices)"
                )
                StatTile(
                    label: "Activation Lock",
                    value: String(format: "%.1f%%", pct(count: snapshot.activationLockEnabledCount, total: snapshot.totalDevices)),
                    sub: "\(snapshot.activationLockEnabledCount) of \(snapshot.totalDevices)"
                )
                StatTile(
                    label: snapshot.jailbreakDetectedCount > 0 ? "Jailbreak Detected" : "Jailbreak Status",
                    value: snapshot.jailbreakDetectedCount > 0 ? "\(snapshot.jailbreakDetectedCount)" : "Clean",
                    sub: snapshot.jailbreakDetectedCount > 0 ? "Devices requiring attention" : "No compromised devices"
                )
            }
            .padding(.top, 8)
        }
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

    private var supervisionDonut: some View {
        let breakdown = snapshot.supervisionBreakdown
        return Chart(breakdown.filter { $0.count > 0 }, id: \.label) { slice in
            SectorMark(
                angle: .value("Count", slice.count),
                innerRadius: .ratio(0.62),
                angularInset: 1.6
            )
            .foregroundStyle(supervisionColor(for: slice.role))
            .accessibilityLabel(slice.label)
            .accessibilityValue("\(slice.count) devices")
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Mobile fleet supervision breakdown")
    }

    private var supervisionLegend: some View {
        let total = snapshot.totalDevices
        let breakdown = snapshot.supervisionBreakdown
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(breakdown, id: \.label) { slice in
                let percentage = total > 0 ? Double(slice.count) / Double(total) * 100 : 0
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(supervisionColor(for: slice.role))
                        .frame(width: 12, height: 12)
                    Text(slice.label)
                        .font(.footnote.weight(.medium))
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
            }
        }
    }

    private func supervisionColor(for role: MobileFleetService.SupervisionRole) -> Color {
        switch role {
        case .supervised: return Theme.Colors.goldBright
        case .unsupervised: return Theme.Colors.warn
        case .unmanaged: return Theme.Colors.hairlineStrong
        }
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
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Mobile Devices",
                    trailing: totalMobileDevices > devicesForTable.count
                        ? "\(devicesForTable.count) of \(totalMobileDevices) shown"
                        : nil
                )
                Table(devicesForTable, selection: $selectedDeviceID) {
                    TableColumn("Name") { device in
                        Text(deviceDisplayName(device))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Type") { device in
                        let deviceType = getDeviceType(device)
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
                if totalMobileDevices > devicesForTable.count {
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
                    ("Managed Apps", "\(snapshot.managedAppCount(for: device))"),
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
                Table(Array(snapshot.profiles.prefix(30).enumerated()).map { ProfileWithIndex(profile: $0.element, index: $0.offset) }) {
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
            }
        }
    }

    // MARK: - Helpers

    private var devicesForTable: [Either<MobileDeviceListRow, MobileDeviceInventoryItem>] {
        if !snapshot.richDevices.isEmpty {
            return Array(snapshot.richDevices.prefix(50)).map { .right($0) }
        } else {
            return Array(snapshot.lightDevices.prefix(50)).map { .left($0) }
        }
    }

    private func deviceDisplayName(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String {
        switch device {
        case .left(let light):
            return light.name ?? "Untitled Device"
        case .right(let rich):
            return rich.general?.displayName ?? "Untitled Device"
        }
    }

    private func getDeviceType(_ device: Either<MobileDeviceListRow, MobileDeviceInventoryItem>) -> String {
        let type = switch device {
        case .left(let light): light.type ?? ""
        case .right(let rich): rich.deviceType ?? ""
        }
        if type.localizedCaseInsensitiveContains("iPad") { return "iPad" }
        if type.localizedCaseInsensitiveContains("iPhone") { return "iPhone" }
        if type.localizedCaseInsensitiveContains("TV") || type.localizedCaseInsensitiveContains("AppleTV") { return "Apple TV" }
        return type.isEmpty ? "Unknown" : type
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
            return formatter.localizedString(for: date, relativeTo: Date())
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
