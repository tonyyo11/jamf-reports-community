import SwiftUI
import AppKit

/// Offline Outreach Report dashboard. Lifts the v3.5 outreach workflow into a live GUI.
/// Buckets devices by days-since-checkin (31-90 / 91-180 / 180+) and surfaces manager/email/
/// department for outreach. One-click "Copy email list" mail-merge for the selected tier.
struct OutreachView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: StaleDeviceService.Snapshot = .empty
    @State private var hasLoaded = false
    @State private var selectedTier: StaleDeviceService.Tier = .offline
    @State private var copyConfirmation: String?

    /// `stale-checkin` template from jamf-cli `pro sg`, loaded once on appear.
    /// `nil` means either the templates haven't loaded yet or jamf-cli is older
    /// than v1.17 (feature-detect failed) — either way, the Create button hides.
    @State private var staleCheckinTemplate: SmartGroupTemplate?
    @State private var showSmartGroupSheet = false
    @State private var bridge = CLIBridge()

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Posture",
                title: "Offline Outreach",
                subtitle: subtitle,
                lastModified: snapshot.snapshotDate
            )
            if snapshot.totalDevices == 0 {
                emptyState
            } else {
                tierKPIGrid
                tierSelector
                actionBar
                devicesTable
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .task(id: workspace.profile) { await loadSmartGroupTemplate() }
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
        .sheet(isPresented: $showSmartGroupSheet) {
            if let template = staleCheckinTemplate {
                SmartGroupApplySheet(
                    viewModel: SmartGroupApplySheetViewModel(
                        template: template,
                        profile: workspace.profile,
                        templateService: SmartGroupTemplateService(
                            executor: DefaultCLIExecutor(bridge: bridge)
                        ),
                        applyService: SmartGroupApplyService(
                            executor: DefaultCLIExecutor(bridge: bridge)
                        ),
                        suggestedName: "Stale Macs 90+ days (Jamf Reports)"
                    )
                )
                .environment(workspace)
            }
        }
    }

    /// Loads the `stale-checkin` template once per profile. Silently no-ops when
    /// jamf-cli is missing or missing PR #205; the Create button just stays hidden.
    private func loadSmartGroupTemplate() async {
        let service = SmartGroupTemplateService(executor: DefaultCLIExecutor(bridge: bridge))
        do {
            let templates = try await service.listTemplates(profile: workspace.profile)
            staleCheckinTemplate = templates.first(where: { $0.slug == "mdm/stale-checkin" })
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            // Expected when jamf-cli is missing or doesn't include PR #205 yet —
            // silent hide is the documented behavior.
            staleCheckinTemplate = nil
        } catch {
            // Network, auth, decode, or other real failure — log so the operator
            // can diagnose why the create-smart-group button is missing from the UI.
            AppLogger.cli.error(
                "OutreachView smart-group templates load failed: \(String(describing: error), privacy: .private)"
            )
            staleCheckinTemplate = nil
        }
    }

    private var subtitle: String? {
        guard snapshot.totalDevices > 0 else { return nil }
        return "\(snapshot.totalDevices) device\(snapshot.totalDevices == 1 ? "" : "s") bucketed by days since check-in."
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
            : StaleDeviceService.snapshot(profile: workspace.profile, demoMode: false)
    }

    private static var demoSnapshot: StaleDeviceService.Snapshot {
        let records = (1...30).map { i -> DeviceInventoryRecord in
            var record = DeviceInventoryRecord.empty(id: "demo-\(i)", source: "demo")
            record.name = "MacBook-\(String(format: "%03d", i))"
            record.serial = "C02X\(String(format: "%08d", i))"
            record.user = ["John Doe", "Jane Smith", "Bob Wilson", "Alice Johnson"].randomElement() ?? ""
            record.email = ["jdoe@example.com", "jsmith@example.com", "", "ajohnson@example.com"].randomElement() ?? ""
            record.department = ["IT", "Marketing", "Sales", "HR"].randomElement() ?? ""
            record.building = ["Main Office", "East Campus", "West Wing"].randomElement() ?? ""

            // Distribute across tiers
            let daysSince: Int
            switch i {
            case 1...15: daysSince = Int.random(in: 31...90)    // offline
            case 16...25: daysSince = Int.random(in: 91...180)  // inactive
            case 26...30: daysSince = Int.random(in: 181...365) // dormant
            default: daysSince = Int.random(in: 0...30)         // recent
            }

            record.daysSinceContact = daysSince
            record.lastContact = Calendar.current.date(byAdding: .day, value: -daysSince, to: Date()).map {
                ISO8601DateFormatter().string(from: $0)
            } ?? ""

            return record
        }
        return StaleDeviceService.snapshot(from: records)
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "envelope",
                title: "No device inventory yet",
                message: "Run device collection (Sources tab → Refresh) and this screen will populate."
            )
        }
    }

    private var tierKPIGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(StaleDeviceService.Tier.allCases, id: \.rawValue) { tier in
                StatTile(
                    label: tier.label,
                    value: "\(snapshot.tierCounts[tier] ?? 0)",
                    sub: tierSubtitle(for: tier)
                )
                .overlay(
                    // Color accent on left edge for each tier
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .strokeBorder(.clear)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: tier.colorHex))
                                .frame(width: 4)
                                .padding(.leading, 2)
                        }
                        .clipped()
                )
            }
        }
    }

    private func tierSubtitle(for tier: StaleDeviceService.Tier) -> String {
        switch tier {
        case .recent:  return "0-30 days"
        case .offline: return "31-90 days"
        case .inactive: return "91-180 days"
        case .dormant:  return "180+ days"
        }
    }

    private var tierSelector: some View {
        SegmentedControl(
            selection: $selectedTier,
            options: [
                (.offline, "Offline", nil),
                (.inactive, "Inactive", nil),
                (.dormant, "Dormant", nil)
            ]
        )
    }

    private var actionBar: some View {
        Card(padding: 16) {
            HStack(spacing: 12) {
                PNPButton(
                    title: "Copy email list",
                    icon: "envelope",
                    style: .gold,
                    action: copyEmailList
                )
                .accessibilityLabel("Copy email list for \(selectedTier.label)")

                PNPButton(
                    title: "Copy table (CSV)",
                    icon: "doc.text",
                    style: .neutral,
                    action: copyTableCSV
                )

                // Smart-group creation appears only when jamf-cli's `pro sg`
                // namespace is available AND the active tier carries 90+-day
                // devices (the stale-checkin template's hardcoded threshold).
                // Showing it on the 31-90d "offline" tier would mislead
                // operators into thinking they're targeting that bucket.
                if staleCheckinTemplate != nil, selectedTier != .offline {
                    PNPButton(
                        title: "Create smart group",
                        icon: "rectangle.stack.badge.plus",
                        style: .neutral,
                        action: { showSmartGroupSheet = true }
                    )
                    .help("Create a smart group of Macs that haven't checked in for 90+ days")
                    .accessibilityLabel("Create smart group for 90 plus day stale devices")
                }

                if let copyConfirmation {
                    Pill(text: copyConfirmation, tone: .teal)
                        .opacity(reduceMotion ? 1.0 : 0.8)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: copyConfirmation)
                }

                Spacer()
            }
        }
    }

    private var devicesTable: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Devices", trailing: "\(selectedTier.label) tier")
                if let devices = snapshot.devicesByTier[selectedTier], !devices.isEmpty {
                    Table(devices) {
                        TableColumn("Device") { device in
                            Text(device.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.fg)
                                .accessibilityLabel("\(device.displayName), device name")
                        }
                        .width(min: 140, ideal: 180)

                        TableColumn("Serial") { device in
                            Text(device.displaySerial)
                                .font(Theme.Fonts.mono(11))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        .width(min: 110, ideal: 130)

                        TableColumn("User/Manager") { device in
                            let displayUser = device.user.isEmpty ? "—" : device.user
                            Text(displayUser)
                                .font(.footnote)
                                .foregroundStyle(displayUser == "—" ? Theme.Text.tertiary(contrast) : Theme.Colors.fg2)
                        }
                        .width(min: 120, ideal: 150)

                        TableColumn("Email") { device in
                            let displayEmail = device.email.isEmpty ? "—" : device.email
                            Text(displayEmail)
                                .font(Theme.Fonts.mono(11))
                                .foregroundStyle(displayEmail == "—" ? Theme.Text.tertiary(contrast) : Theme.Colors.fg2)
                                .accessibilityLabel(displayEmail == "—" ? "No email" : "Email \(displayEmail)")
                        }
                        .width(min: 140, ideal: 180)

                        TableColumn("Department") { device in
                            let displayDept = device.department.isEmpty ? "—" : device.department
                            Text(displayDept)
                                .font(.footnote)
                                .foregroundStyle(displayDept == "—" ? Theme.Text.tertiary(contrast) : Theme.Colors.fg2)
                        }
                        .width(min: 100, ideal: 120)

                        TableColumn("Days Since") { device in
                            let days = device.daysSinceContact ?? 0
                            Text("\(days)")
                                .font(Theme.Fonts.mono(11, weight: .semibold))
                                .foregroundStyle(daysSinceColor(for: days))
                                .monospacedDigit()
                                .accessibilityLabel("\(days) days since check-in")
                        }
                        .width(min: 80, ideal: 90)

                        TableColumn("Last Contact") { device in
                            let relative = relativeDate(from: device.lastContact)
                            Text(relative)
                                .font(Theme.Fonts.mono(10.5))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .accessibilityLabel("Last contact \(relative)")
                        }
                        .width(min: 100, ideal: 120)
                    }
                    .frame(minHeight: 200)
                } else {
                    Text("No devices in the \(selectedTier.label.lowercased()) tier.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.vertical, 20)
                }
            }
        }
    }

    // MARK: - Actions

    private func copyEmailList() {
        guard let devices = snapshot.devicesByTier[selectedTier] else { return }
        let emails = devices.compactMap { device -> String? in
            let trimmed = device.email.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let emailString = emails.joined(separator: "; ")
        copy(text: emailString, then: "Copied \(emails.count) emails")
    }

    private func copyTableCSV() {
        guard let devices = snapshot.devicesByTier[selectedTier] else { return }
        var csv = "Name,Serial,Email,Department,Days Since Check-in\n"
        for device in devices {
            let name = escapeCSV(device.displayName)
            let serial = escapeCSV(device.displaySerial)
            let email = escapeCSV(device.email.isEmpty ? "" : device.email)
            let dept = escapeCSV(device.department.isEmpty ? "" : device.department)
            let days = device.daysSinceContact ?? 0
            csv += "\(name),\(serial),\(email),\(dept),\(days)\n"
        }
        copy(text: csv, then: "Copied table data")
    }

    private func copy(text: String, then confirmation: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        copyConfirmation = confirmation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copyConfirmation = nil
        }
    }

    // MARK: - Helpers

    private func daysSinceColor(for days: Int) -> Color {
        switch days {
        case ..<30:  return Theme.Colors.ok
        case 30..<91: return Theme.Colors.goldBright
        case 91..<181: return Theme.Colors.warn
        default:     return Theme.Colors.danger
        }
    }

    private func relativeDate(from dateString: String) -> String {
        guard let date = parseDate(dateString) else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy HH:mm", "MM/dd/yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private func escapeCSV(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") || trimmed.contains("\"") || trimmed.contains("\n") {
            return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return trimmed
    }
}