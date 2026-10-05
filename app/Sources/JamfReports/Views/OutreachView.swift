import SwiftUI
import AppKit

/// Offline Outreach Report dashboard. Lifts the v3.5 outreach workflow into a live GUI.
/// Buckets devices by days-since-checkin (31-90 / 91-180 / 181+) and surfaces manager/email/
/// department for outreach. One-click "Copy email list" mail-merge for the selected tier.
struct OutreachView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: StaleDeviceService.Snapshot = .empty
    @State private var hasLoaded = false
    @State private var selectedTier: StaleDeviceService.Tier = .offline
    @State private var copyConfirmation: String?

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Posture",
                title: "Offline Outreach",
                subtitle: subtitle,
                // The demo dataset is fixed; an age measured from today would grow
                // for as long as the demo stays open.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )
            if !workspace.demoMode {
                CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
            }
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
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    private var subtitle: String? {
        guard snapshot.totalDevices > 0 else { return nil }
        let count = snapshot.totalDevices
        return "\(count) device\(count == 1 ? "" : "s") bucketed by "
            + "days since \(staleRule.basisPhrase)."
    }

    /// The stale rule the tiers follow: the configured window over the dates `stale_basis` lists.
    private var staleRule: StaleRule {
        StaleRule(days: configuredStaleDays, basis: snapshot.staleBasis)
    }

    /// A Mac's stale age as the table shows it: days, or "never" for a Mac without a date the
    /// rule counts.
    private func ageText(_ device: DeviceInventoryRecord) -> String {
        guard let age = device.staleAge(staleRule) else { return "\(device.daysSinceContact ?? 0)" }
        return age.days.map(String.init) ?? "never"
    }

    /// Configured `thresholds.stale_device_days` (default 30). Tier boundaries
    /// scale from it so this screen agrees with the Overview/Fleet tiles.
    private var configuredStaleDays: Int {
        Int(workspace.configState.staleDeviceDays) ?? 30
    }

    // MARK: - Data loading

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    private func reload() {
        // The demo buckets the whole 524-Mac demo fleet by the demo config's own
        // threshold, so the tier counts and their captions always agree.
        snapshot = workspace.demoMode
            ? StaleDeviceService.snapshot(
                from: DemoData.outreachRecords,
                staleDays: configuredStaleDays,
                dataCollectedDate: DemoData.referenceDate
            )
            : StaleDeviceService.snapshot(
                profile: workspace.profile,
                demoMode: false,
                staleDays: configuredStaleDays
            )
    }

    // MARK: - Sections

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "envelope",
                title: "No device inventory yet",
                message: "Collect data for this screen — use the Collect now banner when shown, or run a scheduled collect — and it will populate."
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
        let s = configuredStaleDays
        switch tier {
        case .recent:   return "0-\(s) days"
        case .offline:  return "\(s + 1)-\(3 * s) days"
        case .inactive: return "\(3 * s + 1)-\(6 * s) days"
        // Dormant starts the day after Inactive ends (181+ at 30), not on its last day.
        case .dormant:  return "\(6 * s + 1)+ days"
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

                PNPButton(
                    title: "Export CSV",
                    icon: "square.and.arrow.up",
                    style: .neutral,
                    action: exportOutreachCSV
                )
                // Exporting writes into the workspaces root and reveals the file;
                // the demo profile has no workspace of its own.
                .disabled(workspace.demoMode)
                .help(workspace.demoMode
                      ? "Demo data is fixed. Exporting a CSV needs a live profile."
                      : "Export all stale devices across every tier to a CSV in the workspace")

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
                            let age = ageText(device)
                            Text(age)
                                .font(Theme.Fonts.mono(11, weight: .semibold))
                                .foregroundStyle(daysSinceColor(for: Int(age) ?? .max))
                                .monospacedDigit()
                                .accessibilityLabel(
                                    "\(age) days since \(staleRule.basisPhrase)")
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
                    .pageTableHeight(rows: devices.count)
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
        var csv = "Name,Serial,Email,Department,Days Since \(staleRule.basisHeading)\n"
        for device in devices {
            let name = StaleDeviceService.csvField(device.displayName)
            let serial = StaleDeviceService.csvField(device.displaySerial)
            let email = StaleDeviceService.csvField(device.email)
            let dept = StaleDeviceService.csvField(device.department)
            csv += "\(name),\(serial),\(email),\(dept),\(ageText(device))\n"
        }
        copy(text: csv, then: "Copied table data")
    }

    /// Export all stale-device records (every tier) as a CSV into the workspace's
    /// output directory, then reveal the file in Finder. Gated on the allow-list
    /// via `SystemActions.reveal`, which allows the workspace and this profile's reports folder.
    private func exportOutreachCSV() {
        guard !workspace.demoMode else { return }
        guard let outputDir = try? WorkspacePaths.outputDir(for: workspace.profile) else {
            workspace.toast = Toast(
                message: "Could not resolve output directory for profile \(workspace.profile).",
                style: .danger
            )
            return
        }
        let filename = ExportNaming.filename(
            kind: "outreach-stale-devices", profile: workspace.profile, ext: "csv"
        )
        let fileURL = outputDir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: outputDir, withIntermediateDirectories: true
            )
            let csv = StaleDeviceService.outreachCSV(snapshot)
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            workspace.toast = Toast(
                message: "Exported \(snapshot.totalDevices) devices to \(filename)",
                style: .success
            )
            SystemActions.reveal(fileURL, profile: workspace.profile)
        } catch {
            workspace.toast = Toast(
                message: "Could not export CSV: \(error.localizedDescription)",
                style: .danger
            )
        }
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
        // Demo ages are measured from the demo's own "now", not today's date.
        let now = workspace.demoMode ? DemoData.referenceDate : Date()
        return Self.relativeDate(from: dateString, now: now)
    }

    /// Jamf timestamps carry millisecond fractions of varying length; the one
    /// inventory parser reads them, so Last Contact never says "Unknown" for a
    /// Mac whose Days Since has a value.
    static func relativeDate(from dateString: String, now: Date) -> String {
        guard let date = DeviceInventoryService.parseDate(dateString) else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

}
